import Foundation
import SwiftData
import SwiftUI

struct HistoryScrollRequest: Equatable {
  let requestID = UUID()
  let modelID: PersistentIdentifier

  init?(item: LocatedHistoryItem) {
    guard item.location.section == .unpinned else { return nil }
    modelID = item.item.item.persistentModelID
  }
}

@Observable
class NavigationManager {
  var history: History
  var footer: Footer

  @ObservationIgnored
  var navigationTask: Task<Void, Never>?

  @ObservationIgnored
  var navigationGeneration: UInt = 0

  init(history: History, footer: Footer) {
    self.history = history
    self.footer = footer
  }

  var selection: Selection<HistoryItemDecorator> = Selection() {
    willSet {
      let newItems = Set(newValue.items.map(ObjectIdentifier.init))
      selection.forEach { _, item in
        if !newItems.contains(ObjectIdentifier(item)) {
          item.selectionIndex = -1
        }
      }
      newValue.forEach { index, item in
        if item.selectionIndex != index {
          item.selectionIndex = index
        }
      }
    }
    didSet {
      updateMultiSelectState()
    }
  }

  var scrollRequest: HistoryScrollRequest?

  var leadSelection: UUID? {
    if let item = leadHistoryItem {
      return item.id
    }
    if let footerItem = footer.selectedItem {
      return footerItem.id
    }
    return history.pasteStack?.id
  }

  var leadHistoryItem: HistoryItemDecorator? {
    didSet {
      guard oldValue?.id != leadHistoryItem?.id else { return }

      let preview = AppState.shared.preview
      if leadHistoryItem != nil {
        preview.resetAutoOpenSuppression()
        preview.startAutoOpen()
      } else {
        preview.cancelAutoOpen()
      }
    }
  }

  var pasteStackSelected: Bool {
    leadSelection != nil && leadSelection == history.pasteStack?.id
  }

  var isManualMultiSelect: Bool = false {
    didSet {
      updateMultiSelectState()
    }
  }
  private(set) var isMultiSelectInProgress = false

  var hoverSelectionWhileKeyboardNavigating: UUID?
  @MainActor
  var isKeyboardNavigating: Bool = true {
    didSet {
      if !isKeyboardNavigating && !isMultiSelectInProgress,
         let hoverSelection = hoverSelectionWhileKeyboardNavigating {
        hoverSelectionWhileKeyboardNavigating = nil
        selectWithoutScrolling(id: hoverSelection)
      }
    }
  }

  var isFirstItemHighlighted: Bool {
    guard let leadHistoryItem else { return false }
    return history.historyItems.isFirst(
      history.historyItems.loadedItem(id: leadHistoryItem.id)?.location
    )
  }

  func requestScroll(to item: HistoryItemDecorator) {
    guard let locatedItem = history.historyItems.loadedItem(id: item.id) else {
      scrollRequest = nil
      return
    }
    if leadHistoryItem?.id == locatedItem.item.id {
      leadHistoryItem = locatedItem.item
    }
    requestScroll(to: locatedItem)
  }

  func select(
    item: HistoryItemDecorator? = nil,
    footerItem: FooterItem? = nil
  ) {
    cancelPendingNavigation()
    let locatedItem = item.flatMap {
      history.historyItems.loadedItem(id: $0.id)
    }
    withTransaction(Transaction()) {
      applySelection(item: locatedItem, footerItem: footerItem)
      if let locatedItem {
        requestScroll(to: locatedItem)
      } else {
        scrollRequest = nil
      }
    }
  }

  func addToSelection(item: HistoryItemDecorator) {
    cancelPendingNavigation()
    guard let locatedItem = history.historyItems.loadedItem(id: item.id) else {
      return
    }

    var newSelection = selection
    var newLead = leadHistoryItem.flatMap {
      history.historyItems.loadedItem(id: $0.id)
    } ?? locatedItem

    if item.isSelected {
      if newSelection.count <= 1 {
        isManualMultiSelect.toggle()
      } else {
        newSelection.remove(item)
        if item == leadHistoryItem,
           let item = newSelection.items.last,
           let locatedItem = history.historyItems.loadedItem(id: item.id) {
          newLead = locatedItem
        }
      }
    } else {
      newSelection.add(item)
      newLead = locatedItem
    }

    withTransaction(Transaction()) {
      selection = newSelection
      leadHistoryItem = newLead.item
      requestScroll(to: newLead)
    }
  }

  func selectWithoutScrolling(id: UUID) {
    cancelPendingNavigation()
    if let stack = history.pasteStack, stack.id == id {
      clearSelection()
    } else if let item = history.historyItems.loadedItem(id: id) {
      if !isMultiSelectInProgress {
        applySelection(item: item)
      }
    } else if let item = footer.items.first(where: { $0.id == id }) {
      applySelection(footerItem: item)
    }
  }

  @MainActor
  func nearestUnselectedItem(
    beforeDeleting items: [HistoryItemDecorator]
  ) async -> LocatedHistoryItem? {
    guard let leadHistoryItem = await resolveLeadHistoryItem() else {
      return nil
    }
    let selectedIDs = Set(items.map(\.id))
    return try? await history.historyItems.nearest(
      to: leadHistoryItem,
      where: { !selectedIDs.contains($0.id) }
    )
  }

  private func applySelection(
    item: LocatedHistoryItem? = nil,
    footerItem: FooterItem? = nil
  ) {
    if let item {
      selectInHistory(item)
    } else if let footerItem {
      selectInFooter(footerItem)
    } else {
      clearSelection()
    }
  }

  private func selectInHistory(_ item: LocatedHistoryItem) {
    leadHistoryItem = item.item
    selection = Selection(items: [item.item])
    footer.selectedItem = nil
  }

  private func selectInFooter(_ item: FooterItem) {
    leadHistoryItem = nil
    if !isMultiSelectInProgress {
      selection = Selection()
    }
    footer.selectedItem = item
  }

  private func clearSelection() {
    leadHistoryItem = nil
    selection = Selection()
    footer.selectedItem = nil
  }

  @MainActor
  func resolveLeadHistoryItem() async -> LocatedHistoryItem? {
    guard let leadHistoryItem else { return nil }
    if let resolved = history.historyItems.loadedItem(id: leadHistoryItem.id) {
      self.leadHistoryItem = resolved.item
      return resolved
    }
    if let resolved = try? await history.historyItems.resolve(leadHistoryItem) {
      self.leadHistoryItem = resolved.item
      return resolved
    }
    return nil
  }

  @MainActor
  func reconcileSelectionAfterHistoryChange() {
    let resolvedItems = selection.items.compactMap { item in
      if let loadedItem = history.historyItems.loadedItem(id: item.id) {
        return loadedItem.item
      }
      if let loadedItem = history.historyItems.loadedItem(
        modelID: item.item.persistentModelID
      ) {
        return loadedItem.item
      }
      return history.historyItems.contains(item) ? item : nil
    }
    selection = Selection(items: resolvedItems)

    guard let leadHistoryItem else { return }
    if let resolved = history.historyItems.loadedItem(
      id: leadHistoryItem.id
    ) {
      self.leadHistoryItem = resolved.item
      return
    }
    if let resolved = history.historyItems.loadedItem(
      modelID: leadHistoryItem.item.persistentModelID
    ) {
      self.leadHistoryItem = resolved.item
    } else if !history.historyItems.contains(leadHistoryItem) {
      self.leadHistoryItem = resolvedItems.last
      scrollRequest = nil
    }
  }

  func requestScroll(to item: LocatedHistoryItem) {
    scrollRequest = HistoryScrollRequest(item: item)
  }

  @MainActor
  func selectFromKeyboardNavigation(
    item: LocatedHistoryItem? = nil,
    footerItem: FooterItem? = nil
  ) {
    isKeyboardNavigating = true
    isManualMultiSelect = false
    withTransaction(Transaction()) {
      applySelection(item: item, footerItem: footerItem)
      if let item {
        requestScroll(to: item)
      } else {
        scrollRequest = nil
      }
    }
  }

  private func updateMultiSelectState() {
    let newValue = isManualMultiSelect || selection.count > 1
    if isMultiSelectInProgress != newValue {
      isMultiSelectInProgress = newValue
    }
  }
}
