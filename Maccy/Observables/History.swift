// swiftlint:disable file_length
import AppKit.NSRunningApplication
import Defaults
import Foundation
import Logging
import Observation
import Sauce
import Settings
import SwiftData

private enum HistoryMode {
  case limited
  case unlimited

  static var configured: Self {
    Defaults[.isUnlimitedHistory] ? .unlimited : .limited
  }

  var pageSize: Int? {
    switch self {
    case .limited: nil
    case .unlimited: 20
    }
  }

  var retentionLimit: Int? {
    switch self {
    case .limited: Defaults[.size]
    case .unlimited: nil
    }
  }
}

@Observable
class History { // swiftlint:disable:this type_body_length
  static let shared = History()
  let logger = Logger(label: "org.p0deje.Maccy")

  var pasteStack: PasteStack?

  private(set) var pinnedItems: [HistoryItemDecorator] = []
  private(set) var unpinnedItems: PagedHistoryItems

  @ObservationIgnored
  private(set) var allPinnedItems: [HistoryItemDecorator] = []

  @ObservationIgnored
  private let dataProvider: HistoryDataProvider

  @ObservationIgnored
  private var mode: HistoryMode

  @ObservationIgnored
  private var currentQuery: HistoryDataProvider.Query

  @ObservationIgnored
  private var queryRevision: UInt64 = 0

  @ObservationIgnored
  lazy var historyItems = HistoryItems(
    pinnedItems: { [unowned self] in self.pinnedItems },
    unpinnedItems: { [unowned self] in self.unpinnedItems },
    pinsPosition: { Defaults[.pinTo] },
    revision: { [unowned self] in self.historyOrderRevision }
  )

  private var historyOrderRevision: UInt64 {
    queryRevision &* 2
      &+ (Defaults[.pinTo] == .top ? 0 : 1)
  }

  var searchQuery: String = "" {
    didSet {
      throttler.throttle { [weak self] in
        Task { @MainActor [weak self] in
          guard let self else { return }
          do {
            try self.reloadQuery()
          } catch {
            self.logger.error("Failed to search history: \(error)")
          }

          if self.searchQuery.isEmpty {
            AppState.shared.navigator.highlightFirstUnpinned()
          } else {
            AppState.shared.navigator.highlightFirst()
          }

          AppState.shared.popup.needsResize = true
        }
      }
    }
  }

  var pressedShortcutItem: HistoryItemDecorator? {
    guard let event = NSApp.currentEvent else {
      return nil
    }

    let modifierFlags = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting(.capsLock)

    guard HistoryItemAction(modifierFlags) != .unknown else {
      return nil
    }

    let key = Sauce.shared.key(for: Int(event.keyCode))
    return historyItems.loadedItems.first {
      $0.item.shortcuts.contains(where: { $0.key == key })
    }?.item
  }

  private let throttler = Throttler(minimumDelay: 0.2)

  @ObservationIgnored
  private var sessionLog: [Int: HistoryItem] = [:]

  init() {
    let dataProvider = HistoryDataProvider()
    let mode = HistoryMode.configured
    let query = HistoryDataProvider.Query.empty(
      pageSize: mode.pageSize
    )
    self.dataProvider = dataProvider
    self.mode = mode
    currentQuery = query
    unpinnedItems = Self.makeUnpinnedItems(
      query: query
    )

    Task {
      for await _ in Defaults.updates(.pasteByDefault, initial: false) {
        await MainActor.run {
          self.updateShortcuts()
        }
      }
    }

    Task {
      for await _ in Defaults.updates(.sortBy, initial: false) {
        await MainActor.run {
          do {
            try self.reloadQuery()
          } catch {
            self.logger.error("Failed to sort history: \(error)")
          }
        }
      }
    }

    Task {
      for await _ in Defaults.updates(.isUnlimitedHistory, initial: false) {
        await MainActor.run {
          do {
            try self.switchMode()
          } catch {
            self.logger.error("Failed to change history mode: \(error)")
          }
        }
      }
    }

    Task {
      for await _ in Defaults.updates(.size, initial: false) {
        await MainActor.run {
          guard self.mode.retentionLimit != nil else { return }
          do {
            try self.enforceRetention()
            try self.refreshAfterMutation()
          } catch {
            self.logger.error("Failed to resize history: \(error)")
          }
        }
      }
    }

    Task {
      for await _ in Defaults.updates(.showSpecialSymbols, initial: false) {
        for item in historyItems.loadedItems.map(\.item) {
          await updateTitle(item: item, title: item.item.generateTitle())
        }
      }
    }

    Task {
      for await _ in Defaults.updates(.imageMaxHeight, initial: false) {
        for item in historyItems.loadedItems.map(\.item) {
          await item.cleanupImages()
        }
      }
    }
  }

  @MainActor
  func load() async throws {
    try enforceRetention()
    try reloadQuery()
    // Ensure that panel size is proper *after* loading all items.
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  private static func makeUnpinnedItems(
    query: HistoryDataProvider.Query
  ) -> PagedHistoryItems {
    return PagedHistoryItems(
      pageSize: query.pageSize,
      indexLoader: query.index,
      loader: query.load
    )
  }

  @MainActor
  private func switchMode() throws {
    let newMode = HistoryMode.configured
    guard newMode != mode else { return }

    try enforceRetention(for: newMode)
    let query = try dataProvider.makeQuery(
      searchQuery: searchQuery,
      pageSize: newMode.pageSize
    )
    let newItems = Self.makeUnpinnedItems(
      query: query
    )
    try newItems.load()
    let pins = query.loadPinnedSnapshot()

    mode = newMode
    currentQuery = query
    unpinnedItems = newItems
    publish(pins)
    updateShortcuts()
    AppState.shared.navigator.reconcileSelectionAfterHistoryChange()
    AppState.shared.popup.needsResize = true
  }

  @MainActor
  @discardableResult
  private func enforceRetention(
    for mode: HistoryMode? = nil,
    keeping protectedItems: [HistoryItemDecorator] = []
  ) throws -> Set<PersistentIdentifier> {
    guard let retentionLimit = (mode ?? self.mode).retentionLimit else {
      return []
    }
    let protectedModelIDs = Set(
      protectedItems.map(\.item.persistentModelID)
    )
    let overflowingItems = try dataProvider.overflowingUnpinnedItems(
      limit: retentionLimit,
      keeping: protectedModelIDs
    )
    guard !overflowingItems.isEmpty else { return [] }
    let removedModelIDs = Set(
      overflowingItems.map(\.persistentModelID)
    )

    for item in overflowingItems {
      if let decorator = loadedDecorator(for: item.persistentModelID) {
        cleanup(decorator)
      }
      dataProvider.remove(modelID: item.persistentModelID)
      Storage.shared.context.delete(item)
    }
    Storage.shared.context.processPendingChanges()
    try Storage.shared.context.save()
    return removedModelIDs
  }

  @MainActor
  func insertIntoStorage(_ item: HistoryItem) throws {
    logger.info("Inserting item with id '\(item.title)'")
    Storage.shared.context.insert(item)
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()
  }

  @discardableResult
  @MainActor
  func add(_ item: HistoryItem) -> HistoryItemDecorator {
    insertIntoStorageIfNeeded(item)
    replaceSimilarItem(with: item)

    sessionLog[Clipboard.shared.changeCount] = item

    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()

    let decorator = dataProvider.decorator(for: item)
    do {
      try enforceRetention(keeping: [decorator])
      try refreshAfterMutation(adopting: [decorator])
    } catch {
      logger.error("Failed to refresh history after adding an item: \(error)")
    }
    AppState.shared.popup.needsResize = true
    return decorator
  }

  @MainActor
  private func insertIntoStorageIfNeeded(_ item: HistoryItem) {
    if #available(macOS 15.0, *) {
      try? insertIntoStorage(item)
    } else {
      // On macOS 14 the history item needs to be inserted into storage directly after creating it.
      // It was already inserted after creation in Clipboard.swift
    }
  }

  @MainActor
  private func replaceSimilarItem(with item: HistoryItem) {
    guard let existingItem = findSimilarItem(item) else {
      Task {
        Notifier.notify(body: item.title, sound: .write)
      }
      return
    }

    mergeMetadata(from: existingItem, into: item)
    logger.info("Removing duplicate item '\(item.title)'")
    let modelID = existingItem.persistentModelID
    if let decorator = loadedDecorator(for: modelID) {
      cleanup(decorator)
    }
    dataProvider.remove(modelID: modelID)
    Storage.shared.context.delete(existingItem)
  }

  private func mergeMetadata(
    from existingItem: HistoryItem,
    into item: HistoryItem
  ) {
    if isModified(item) == nil {
      item.contents = existingItem.contents
    }
    item.firstCopiedAt = existingItem.firstCopiedAt
    item.numberOfCopies += existingItem.numberOfCopies
    item.pin = existingItem.pin
    item.title = existingItem.title
    if !item.fromMaccy {
      item.application = existingItem.application
    }
  }

  @MainActor
  private func withLogging(_ msg: String, _ block: () throws -> Void) rethrows {
    func dataCounts() -> String {
      let historyItemCount = try? Storage.shared.context.fetchCount(FetchDescriptor<HistoryItem>())
      let historyContentCount = try? Storage.shared.context.fetchCount(FetchDescriptor<HistoryItemContent>())
      return "HistoryItem=\(historyItemCount ?? 0) HistoryItemContent=\(historyContentCount ?? 0)"
    }

    logger.info("\(msg) Before: \(dataCounts())")
    try? block()
    logger.info("\(msg) After: \(dataCounts())")
  }

  @MainActor
  func clear() {
    withLogging("Clearing history") {
      unpinnedItems.loadedItems.map(\.item).forEach(cleanup)
      sessionLog.removeValues { $0.pin == nil }

      try? Storage.shared.context.transaction {
        try? Storage.shared.context.delete(
          model: HistoryItem.self,
          where: #Predicate { $0.pin == nil }
        )
        try? Storage.shared.context.delete(
          model: HistoryItemContent.self,
          where: #Predicate { $0.item?.pin == nil }
        )
      }
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
    }
    do {
      try refreshAfterMutation()
    } catch {
      logger.error("Failed to refresh history after clearing it: \(error)")
    }

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func clearAll() {
    withLogging("Clearing all history") {
      historyItems.loadedItems.map(\.item).forEach(cleanup)
      allPinnedItems.removeAll()
      sessionLog.removeAll()

      try? Storage.shared.context.delete(model: HistoryItem.self)
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
    }
    dataProvider.removeAll()
    do {
      try refreshAfterMutation()
    } catch {
      logger.error("Failed to refresh history after clearing it: \(error)")
    }

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func delete(_ item: HistoryItemDecorator?) {
    guard let item else { return }
    delete([item])
  }

  @MainActor
  func delete(_ items: [HistoryItemDecorator]) {
    guard !items.isEmpty else { return }

    let removedModelIDs = Set(items.map(\.item.persistentModelID))
    items.forEach(cleanup)
    withLogging("Removing \(items.count) history item(s)") {
      for item in items {
        Storage.shared.context.delete(item.item)
      }
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
    }

    for item in items {
      dataProvider.remove(item)
    }
    sessionLog.removeValues {
      removedModelIDs.contains($0.persistentModelID)
    }

    do {
      try refreshAfterMutation()
    } catch {
      logger.error("Failed to refresh history after deleting items: \(error)")
    }
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  private func cleanup(_ item: HistoryItemDecorator) {
    item.cleanupImages()
  }

  private func loadedDecorator(
    for modelID: PersistentIdentifier
  ) -> HistoryItemDecorator? {
    historyItems.loadedItems.lazy.map(\.item).first {
      $0.item.persistentModelID == modelID
    }
  }

  private func currentModifierFlags() -> NSEvent.ModifierFlags {
    return NSApp.currentEvent?.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function]) ?? []
  }

  @MainActor
  func select(_ item: HistoryItemDecorator?) {
    guard let item else {
      return
    }

    let modifierFlags = currentModifierFlags()

    if modifierFlags.isEmpty {
      AppState.shared.popup.close()
      Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
      if Defaults[.pasteByDefault] {
        Clipboard.shared.paste()
      }
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .paste:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
        Clipboard.shared.paste()
      case .pasteWithoutFormatting:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    Task {
      searchQuery = ""
    }
  }

  @MainActor
  func startPasteStack(selection: inout Selection<HistoryItemDecorator>) {
    guard let item = selection.first else { return }
    PasteStack.initializeIfNeeded()

    let modifierFlags = currentModifierFlags()

    let stack = PasteStack(items: selection.items, modifierFlags: modifierFlags)
    pasteStack = stack

    logger.info("Initialising PasteStack with \(stack.items.count) items")
    logger.info("Copying \(item.item.title) from PasteStack")

    if modifierFlags.isEmpty {
      AppState.shared.popup.close()
      Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .paste:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .pasteWithoutFormatting:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    Task {
      searchQuery = ""
    }
  }

  func handlePasteStack() {
    guard let stack = pasteStack else {
      return
    }

    guard let pasted = stack.items.first else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    logger.info("PasteStack pasted \(pasted.item.title)")

    stack.items.removeFirst()

    guard let item = stack.items.first else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    logger.info("Copying \(item.item.title) from PasteStack. \(stack.items.count) items remaining in stack.")

    Task {
      if stack.modifierFlags.isEmpty {
        await Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
      } else {
        switch HistoryItemAction(stack.modifierFlags) {
        case .copy:
          await Clipboard.shared.copy(item.item)
        case .paste:
          await Clipboard.shared.copy(item.item)
        case .pasteWithoutFormatting:
          await Clipboard.shared.copy(item.item, removeFormatting: true)
        case .unknown:
          return
        }
      }
    }
  }

  func interruptPasteStack() {
    guard pasteStack != nil else {
      return
    }
    logger.info("Interrupting PasteStack")
    pasteStack = nil
  }

  @MainActor
  func togglePin(_ item: HistoryItemDecorator?) {
    guard let item else { return }
    togglePin([item])
  }

  // swiftlint:disable function_body_length
  @MainActor
  func togglePin(_ items: [HistoryItemDecorator]) {
    guard !items.isEmpty else { return }

    let uniqueItems = items.reduce(into: [HistoryItemDecorator]()) {
      if !$0.contains($1) {
        $0.append($1)
      }
    }
    let pinnedModelIDs = Set(
      uniqueItems.lazy
        .filter(\.isPinned)
        .map(\.item.persistentModelID)
    )
    var availablePins = HistoryItem.availablePins(
      in: allPinnedItems.lazy
        .map(\.item)
        .filter { !pinnedModelIDs.contains($0.persistentModelID) }
    )
    let layoutRemovals = unpinnedLayoutRemovals(for: uniqueItems)
    var changedItems: [HistoryItemDecorator] = []
    var newlyUnpinnedItems: [HistoryItemDecorator] = []

    for item in uniqueItems {
      if item.isPinned {
        item.item.pin = nil
        changedItems.append(item)
        newlyUnpinnedItems.append(item)
      } else {
        guard let pin = availablePins.randomElement() else { continue }
        availablePins.removeAll { $0 == pin }
        item.item.pin = pin
        changedItems.append(item)
      }
    }
    guard !changedItems.isEmpty else { return }

    Storage.shared.context.processPendingChanges()
    do {
      try Storage.shared.context.save()
      let removedModelIDs = try enforceRetention(
        keeping: newlyUnpinnedItems
      )
      let retainedUnpinnedItems = newlyUnpinnedItems.filter {
        !removedModelIDs.contains($0.item.persistentModelID)
      }
      let retainedChangedItems = changedItems.filter {
        !removedModelIDs.contains($0.item.persistentModelID)
      }
      let mutation = layoutRemovals.map {
        HistoryDataProvider.UnpinnedMutation(
          removals: $0,
          insertions: retainedUnpinnedItems.map {
            HistoryDataProvider.UnpinnedMutation.Insertion(
              modelID: $0.item.persistentModelID,
              isImage: $0.item.hasImageContent
            )
          }
        )
      }
      let query = try refreshAfterMutation(
        adopting: retainedChangedItems,
        applying: mutation
      )

      var scrollTarget: HistoryItemDecorator?
      for item in retainedUnpinnedItems {
        if let index = try query.index(
          of: item.item.persistentModelID
        ) {
          self.unpinnedItems.remember(item, at: index)
          scrollTarget = item
        }
      }

      if let scrollTarget {
        AppState.shared.navigator.requestScroll(to: scrollTarget)
      }
    } catch {
      logger.error("Failed to refresh history after changing pins: \(error)")
      return
    }

    AppState.shared.popup.needsResize = true
  }
  // swiftlint:enable function_body_length

  private func unpinnedLayoutRemovals(
    for items: [HistoryItemDecorator]
  ) -> [HistoryDataProvider.UnpinnedMutation.Removal]? {
    var removals: [
      HistoryDataProvider.UnpinnedMutation.Removal
    ] = []
    for item in items where item.isUnpinned {
      guard let indexedItem = unpinnedItems.loadedItem(id: item.id),
        indexedItem.item === item
      else {
        return nil
      }
      removals.append(
        HistoryDataProvider.UnpinnedMutation.Removal(
          index: indexedItem.index,
          isImage: item.item.hasImageContent
        )
      )
    }
    return removals
  }

  @MainActor
  private func findSimilarItem(_ item: HistoryItem) -> HistoryItem? {
    do {
      if let duplicate = try dataProvider.findSimilarItem(
        to: item,
        among: historyItems.loadedItems.lazy.map(\.item)
      ) {
        return duplicate
      }
    } catch {
      logger.error("Failed to find a duplicate history item: \(error)")
    }

    return isModified(item)
  }

  private func isModified(_ item: HistoryItem) -> HistoryItem? {
    if let modified = item.modified, sessionLog.keys.contains(modified) {
      return sessionLog[modified]
    }

    return nil
  }

  @MainActor
  private func reloadQuery() throws {
    let query = try dataProvider.makeQuery(
      searchQuery: searchQuery,
      pageSize: mode.pageSize
    )
    try unpinnedItems.reload(
      indexLoader: query.index,
      loader: query.load
    )
    currentQuery = query
    publish(query.loadPinnedSnapshot())
    updateShortcuts()
  }

  @discardableResult
  @MainActor
  private func refreshAfterMutation(
    adopting items: [HistoryItemDecorator] = [],
    applying mutation: HistoryDataProvider.UnpinnedMutation? = nil
  ) throws -> HistoryDataProvider.Query {
    dataProvider.adopt(items)
    let patchedQuery = try mutation.flatMap {
      try dataProvider.makeQuery(
        applying: $0,
        to: currentQuery,
        searchQuery: searchQuery,
        pageSize: mode.pageSize
      )
    }
    let query = try patchedQuery ?? dataProvider.makeQuery(
      searchQuery: searchQuery,
      pageSize: mode.pageSize
    )
    try unpinnedItems.refreshAfterMutation(
      indexLoader: query.index,
      loader: query.load
    )
    currentQuery = query
    publish(query.loadPinnedSnapshot())
    updateShortcuts()
    AppState.shared.navigator.reconcileSelectionAfterHistoryChange()
    return query
  }

  private func publish(
    _ snapshot: HistoryDataProvider.PinnedSnapshot
  ) {
    allPinnedItems = snapshot.allItems
    if searchQuery.isEmpty {
      pinnedItems = snapshot.allItems
    } else {
      pinnedItems = snapshot.visibleItems
    }
    queryRevision &+= 1
  }

  private func updateShortcuts() {
    for item in allPinnedItems {
      if let pin = item.item.pin {
        item.shortcuts = KeyShortcut.create(character: pin)
      }
    }

    updateUnpinnedShortcuts()
  }

  @MainActor
  private func updateTitle(item: HistoryItemDecorator, title: String) {
    item.title = title
    item.item.title = title
  }

  private func updateUnpinnedShortcuts() {
    for indexedItem in unpinnedItems.loadedItems {
      indexedItem.item.shortcuts = indexedItem.index < 9
        ? KeyShortcut.create(
          character: String(indexedItem.index + 1)
        )
        : []
    }
  }

}
