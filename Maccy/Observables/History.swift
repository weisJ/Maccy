// swiftlint:disable file_length
import AppKit.NSRunningApplication
import Defaults
import Foundation
import Logging
import Observation
import Sauce
import Settings
import SwiftData

@Observable
class History { // swiftlint:disable:this type_body_length
  static let shared = History()
  let logger = Logger(label: "org.p0deje.Maccy")

  var pasteStack: PasteStack?

  private(set) var pinnedItems: [HistoryItemDecorator] = []
  let unpinnedItems = ResidentHistoryItems()

  @ObservationIgnored
  private(set) var allPinnedItems: [HistoryItemDecorator] = []

  @ObservationIgnored
  private(set) var allUnpinnedItems: [HistoryItemDecorator] = []

  @ObservationIgnored
  lazy var historyItems = HistoryItems(
    pinnedItems: { [unowned self] in self.pinnedItems },
    unpinnedItems: { [unowned self] in self.unpinnedItems },
    pinsPosition: { Defaults[.pinTo] }
  )

  var searchQuery: String = "" {
    didSet {
      throttler.throttle { [weak self] in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.applySearch()

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

  private let search = Search()
  private let sorter = Sorter()
  private let throttler = Throttler(minimumDelay: 0.2)

  @ObservationIgnored
  private var sessionLog: [Int: HistoryItem] = [:]

  init() {
    Task {
      for await _ in Defaults.updates(.pasteByDefault, initial: false) {
        updateShortcuts()
      }
    }

    Task {
      for await _ in Defaults.updates(.sortBy, initial: false) {
        try? await load()
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
    let descriptor = FetchDescriptor<HistoryItem>()
    let results = try Storage.shared.context.fetch(descriptor)
    let sortedItems = sorter.sort(results).map {
      HistoryItemDecorator($0)
    }
    allPinnedItems = sortedItems.filter(\.isPinned)
    allUnpinnedItems = sortedItems.filter(\.isUnpinned)

    limitHistorySize(to: Defaults[.size])

    applySearch()
    // Ensure that panel size is proper *after* loading all items.
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  private func limitHistorySize(to maxSize: Int) {
    if allUnpinnedItems.count >= maxSize {
      delete(Array(allUnpinnedItems[maxSize...]))
    }
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
    let replacedPinIndex = replaceSimilarItem(with: item)

    // Remove exceeding items after duplicate replacement so a duplicate does
    // not unnecessarily shrink the history.
    limitHistorySize(to: Defaults[.size] - 1)
    sessionLog[Clipboard.shared.changeCount] = item

    let decorator = insertDecorator(
      for: item,
      replacingPinAt: replacedPinIndex
    )
    applySearch()
    AppState.shared.popup.needsResize = true
    return decorator
  }

  @MainActor
  private func insertIntoStorageIfNeeded(_ item: HistoryItem) {
    if #available(macOS 15.0, *) {
      try? History.shared.insertIntoStorage(item)
    } else {
      // On macOS 14 the history item needs to be inserted into storage directly after creating it.
      // It was already inserted after creation in Clipboard.swift
    }
  }

  @MainActor
  private func replaceSimilarItem(with item: HistoryItem) -> Int? {
    guard let existingItem = findSimilarItem(item) else {
      Task {
        Notifier.notify(body: item.title, sound: .write)
      }
      return nil
    }

    mergeMetadata(from: existingItem, into: item)
    logger.info("Removing duplicate item '\(item.title)'")
    let replacedPinIndex = removeDecorator(for: existingItem)
    Storage.shared.context.delete(existingItem)
    return replacedPinIndex
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
  private func removeDecorator(for item: HistoryItem) -> Int? {
    if let index = allPinnedItems.firstIndex(where: { $0.item == item }) {
      cleanup(allPinnedItems.remove(at: index))
      return index
    }
    if let index = allUnpinnedItems.firstIndex(where: { $0.item == item }) {
      cleanup(allUnpinnedItems.remove(at: index))
    }
    return nil
  }

  private func insertDecorator(
    for item: HistoryItem,
    replacingPinAt replacedPinIndex: Int?
  ) -> HistoryItemDecorator {
    if let pin = item.pin {
      let decorator = HistoryItemDecorator(
        item,
        shortcuts: KeyShortcut.create(character: pin)
      )
      if let replacedPinIndex {
        // Replacing a duplicate must not move an existing pin.
        allPinnedItems.insert(decorator, at: replacedPinIndex)
      } else {
        allPinnedItems.append(decorator)
        allPinnedItems = sorted(allPinnedItems)
      }
      return decorator
    }

    let decorator = HistoryItemDecorator(item)
    allUnpinnedItems.append(decorator)
    allUnpinnedItems = sorted(allUnpinnedItems)
    return decorator
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
      allUnpinnedItems.forEach(cleanup)
      allUnpinnedItems.removeAll()
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
    applySearch()

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func clearAll() {
    withLogging("Clearing all history") {
      allItems.forEach(cleanup)
      allPinnedItems.removeAll()
      allUnpinnedItems.removeAll()
      sessionLog.removeAll()

      try? Storage.shared.context.delete(model: HistoryItem.self)
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
    }
    applySearch()

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

    let removedItems = Set(items)
    allPinnedItems.removeAll { removedItems.contains($0) }
    allUnpinnedItems.removeAll { removedItems.contains($0) }
    sessionLog.removeValues {
      removedModelIDs.contains($0.persistentModelID)
    }

    applySearch()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  private func cleanup(_ item: HistoryItemDecorator) {
    item.cleanupImages()
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
    guard AppState.shared.multiSelectionEnabled else { return }
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

  @MainActor
  func togglePin(_ items: [HistoryItemDecorator]) {
    guard !items.isEmpty else { return }

    var itemsToScrollTo: [HistoryItemDecorator] = []
    for item in items {
      if item.isPinned {
        allPinnedItems.removeAll { $0 == item }
        item.togglePin()
        allUnpinnedItems.append(item)
        itemsToScrollTo.append(item)
      } else {
        allUnpinnedItems.removeAll { $0 == item }
        item.togglePin()
        allPinnedItems.append(item)
      }
    }

    allPinnedItems = sorted(allPinnedItems)
    allUnpinnedItems = sorted(allUnpinnedItems)

    applySearch()
    if let item = itemsToScrollTo.last {
      AppState.shared.navigator.requestScroll(to: item)
    }
  }

  @MainActor
  private func findSimilarItem(_ item: HistoryItem) -> HistoryItem? {
    if let duplicate = allItems.first(where: {
      $0.item != item && $0.item.supersedes(item)
    }) {
      return duplicate.item
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
  private func applySearch() {
    let results = search.search(string: searchQuery, within: allItems)
    var matchingPins: [HistoryItemDecorator] = []
    var matchingUnpinnedItems: [HistoryItemDecorator] = []

    for result in results {
      let item = result.object
      item.highlight(searchQuery, result.ranges)
      if item.isPinned {
        matchingPins.append(item)
      } else {
        matchingUnpinnedItems.append(item)
      }
    }

    pinnedItems = matchingPins
    unpinnedItems.replace(with: matchingUnpinnedItems)
    updateShortcuts()
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
    for item in unpinnedItems.items {
      item.shortcuts = []
    }

    var index = 1
    for item in unpinnedItems.items.prefix(9) {
      item.shortcuts = KeyShortcut.create(character: String(index))
      index += 1
    }
  }

  private var allItems: [HistoryItemDecorator] {
    ordered(pinned: allPinnedItems, unpinned: allUnpinnedItems)
  }

  private func ordered(
    pinned: [HistoryItemDecorator],
    unpinned: [HistoryItemDecorator]
  ) -> [HistoryItemDecorator] {
    Defaults[.pinTo] == .top
      ? pinned + unpinned
      : unpinned + pinned
  }

  private func sorted(
    _ items: [HistoryItemDecorator]
  ) -> [HistoryItemDecorator] {
    items.sorted {
      sorter.areInIncreasingOrder($0.item, $1.item)
    }
  }
}
