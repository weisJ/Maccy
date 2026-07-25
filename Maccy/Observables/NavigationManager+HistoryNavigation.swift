import SwiftUI

extension NavigationManager {
  @MainActor
  private func extendSelection(
    from: LocatedHistoryItem,
    destination: LocatedHistoryItem,
    isRange: Bool,
    generation: UInt
  ) async {
    var newSelection = selection

    if isRange {
      do {
        let range = try await history.historyItems.range(
          from: from.location,
          through: destination.location
        )
        guard isNavigationCurrent(generation), !range.isEmpty else { return }
        newSelection = Selection(items: range.map(\.item))
      } catch {
        return
      }
    } else if destination.item.isSelected {
      newSelection.remove(from.item)
    } else {
      newSelection.add(destination.item)
    }

    guard isNavigationCurrent(generation) else { return }
    withTransaction(Transaction()) {
      selection = newSelection
      leadHistoryItem = destination.item
      requestScroll(to: destination)
    }
  }

  private func enqueueNavigation(
    _ operation: @escaping @MainActor (
      NavigationManager,
      UInt
    ) async -> Void
  ) {
    let previousTask = navigationTask
    let generation = navigationGeneration
    navigationTask = Task { @MainActor [weak self] in
      await previousTask?.value
      guard let self, self.isNavigationCurrent(generation) else { return }
      await operation(self, generation)
    }
  }

  func cancelPendingNavigation() {
    navigationGeneration &+= 1
    navigationTask?.cancel()
    navigationTask = nil
  }

  private func isNavigationCurrent(_ generation: UInt) -> Bool {
    generation == navigationGeneration && !Task.isCancelled
  }

  func highlightFirst() {
    enqueueNavigation { navigator, generation in
      do {
        let item = try await navigator.history.historyItems.first()
        guard navigator.isNavigationCurrent(generation) else { return }
        navigator.selectFromKeyboardNavigation(item: item)
      } catch {
        return
      }
    }
  }

  func highlightFirstUnpinned() {
    enqueueNavigation { navigator, generation in
      do {
        var item = try await navigator.history.historyItems.firstUnpinned()
        if item == nil {
          item = try await navigator.history.historyItems.first()
        }
        guard navigator.isNavigationCurrent(generation) else { return }
        navigator.selectFromKeyboardNavigation(item: item)
      } catch {
        return
      }
    }
  }

  func highlightPrevious() {
    enqueueNavigation { navigator, generation in
      await navigator.performHighlightPrevious(generation: generation)
    }
  }

  func highlightNext(allowCycle: Bool = false) {
    enqueueNavigation { navigator, generation in
      await navigator.performHighlightNext(
        allowCycle: allowCycle,
        generation: generation
      )
    }
  }

  func highlightLast() {
    enqueueNavigation { navigator, generation in
      await navigator.performHighlightLast(generation: generation)
    }
  }

  func extendHighlightToNext() {
    enqueueNavigation { navigator, generation in
      await navigator.performExtendHighlightToNext(generation: generation)
    }
  }

  func extendHighlightToPrevious() {
    enqueueNavigation { navigator, generation in
      await navigator.performExtendHighlightToPrevious(generation: generation)
    }
  }

  func extendHighlightToFirst() {
    guard history.historyItems.supportsBoundaryRangeSelection else { return }
    enqueueNavigation { navigator, generation in
      await navigator.performExtendHighlightToFirst(generation: generation)
    }
  }

  func extendHighlightToLast() {
    guard history.historyItems.supportsBoundaryRangeSelection else { return }
    enqueueNavigation { navigator, generation in
      await navigator.performExtendHighlightToLast(generation: generation)
    }
  }

  func deleteSelection() {
    let itemsToDelete = selection.items
    guard !itemsToDelete.isEmpty else { return }
    let selectedIDs = Set(itemsToDelete.map(\.id))

    enqueueNavigation { navigator, generation in
      let nextItem = await navigator.nearestUnselectedItem(
        beforeDeleting: itemsToDelete
      )
      guard navigator.isNavigationCurrent(generation),
            Set(navigator.selection.items.map(\.id)) == selectedIDs
      else {
        return
      }

      navigator.history.delete(itemsToDelete)
      let nextLoadedItem = nextItem.flatMap {
        navigator.history.historyItems.loadedItem(id: $0.item.id)
      }
      navigator.selectFromKeyboardNavigation(item: nextLoadedItem)
    }
  }

  @MainActor
  private func performHighlightPrevious(generation: UInt) async {
    guard leadSelection != nil else { return }

    if let lead = resolveLeadHistoryItem() {
      await highlightItemBefore(lead, generation: generation)
    } else if let footerItem = footer.selectedItem {
      await highlightItemBefore(footerItem, generation: generation)
    }
  }

  @MainActor
  private func highlightItemBefore(
    _ lead: LocatedHistoryItem,
    generation: UInt
  ) async {
    do {
      let previous = try await history.historyItems.item(before: lead.location)
      guard isNavigationCurrent(generation) else { return }
      if let previous {
        selectFromKeyboardNavigation(item: previous)
      } else if history.pasteStack != nil {
        selectFromKeyboardNavigation()
      } else {
        let first = try await history.historyItems.first()
        guard isNavigationCurrent(generation) else { return }
        selectFromKeyboardNavigation(item: first)
      }
    } catch {
      return
    }
  }

  @MainActor
  private func highlightItemBefore(
    _ footerItem: FooterItem,
    generation: UInt
  ) async {
    if let previous = footer.visibleItem(before: footerItem) {
      selectFromKeyboardNavigation(footerItem: previous)
      return
    }
    do {
      let lastItem = try await history.historyItems.last()
      guard isNavigationCurrent(generation), let lastItem else { return }
      selectFromKeyboardNavigation(item: lastItem)
    } catch {
      return
    }
  }

  @MainActor
  private func performHighlightNext(
    allowCycle: Bool,
    generation: UInt
  ) async {
    guard leadSelection != nil else { return }

    if pasteStackSelected {
      await highlightFirstHistoryItem(generation: generation)
    } else if let lead = resolveLeadHistoryItem() {
      await highlightItemAfter(
        lead,
        allowCycle: allowCycle,
        generation: generation
      )
    } else if let footerItem = footer.selectedItem {
      await highlightItemAfter(
        footerItem,
        allowCycle: allowCycle,
        generation: generation
      )
    }
  }

  @MainActor
  private func highlightItemAfter(
    _ lead: LocatedHistoryItem,
    allowCycle: Bool,
    generation: UInt
  ) async {
    do {
      let next = try await history.historyItems.item(after: lead.location)
      guard isNavigationCurrent(generation) else { return }
      if let next {
        selectFromKeyboardNavigation(item: next)
      } else if let footerItem = footer.firstVisibleItem {
        selectFromKeyboardNavigation(footerItem: footerItem)
      } else if allowCycle {
        await highlightFirstHistoryItem(generation: generation)
      }
    } catch {
      return
    }
  }

  @MainActor
  private func highlightItemAfter(
    _ footerItem: FooterItem,
    allowCycle: Bool,
    generation: UInt
  ) async {
    if let next = footer.visibleItem(after: footerItem) {
      selectFromKeyboardNavigation(footerItem: next)
    } else if let firstFooterItem = footer.firstVisibleItem {
      selectFromKeyboardNavigation(footerItem: firstFooterItem)
    } else if allowCycle {
      await highlightFirstHistoryItem(generation: generation)
    }
  }

  @MainActor
  private func highlightFirstHistoryItem(generation: UInt) async {
    do {
      let first = try await history.historyItems.first()
      guard isNavigationCurrent(generation) else { return }
      selectFromKeyboardNavigation(item: first)
    } catch {
      return
    }
  }

  @MainActor
  private func performHighlightLast(generation: UInt) async {
    guard leadSelection != nil else { return }

    if let lead = resolveLeadHistoryItem() {
      do {
        let lastItem = try await history.historyItems.last()
        guard isNavigationCurrent(generation) else { return }
        if lead.location == lastItem?.location,
           let footerItem = footer.firstVisibleItem {
          selectFromKeyboardNavigation(footerItem: footerItem)
        } else {
          selectFromKeyboardNavigation(item: lastItem)
        }
      } catch {
        return
      }
    } else if footer.selectedItem != nil {
      selectFromKeyboardNavigation(footerItem: footer.lastVisibleItem)
    } else {
      selectFromKeyboardNavigation(footerItem: footer.firstVisibleItem)
    }
  }

  @MainActor
  private func performExtendHighlightToNext(generation: UInt) async {
    guard let lead = resolveLeadHistoryItem() else {
      await performHighlightNext(
        allowCycle: false,
        generation: generation
      )
      return
    }
    let nextItem: LocatedHistoryItem?
    do {
      nextItem = try await history.historyItems.item(after: lead.location)
    } catch {
      return
    }
    guard isNavigationCurrent(generation), let nextItem else { return }
    await extendSelection(
      from: lead,
      destination: nextItem,
      isRange: false,
      generation: generation
    )
  }

  @MainActor
  private func performExtendHighlightToPrevious(generation: UInt) async {
    guard let lead = resolveLeadHistoryItem() else {
      await performHighlightPrevious(generation: generation)
      return
    }
    let previousItem: LocatedHistoryItem?
    do {
      previousItem = try await history.historyItems.item(
        before: lead.location
      )
    } catch {
      return
    }
    guard isNavigationCurrent(generation), let previousItem else { return }
    await extendSelection(
      from: lead,
      destination: previousItem,
      isRange: false,
      generation: generation
    )
  }

  @MainActor
  private func performExtendHighlightToFirst(generation: UInt) async {
    let firstItem: LocatedHistoryItem?
    do {
      firstItem = try await history.historyItems.first()
    } catch {
      return
    }
    guard isNavigationCurrent(generation) else { return }
    guard let lead = resolveLeadHistoryItem(), let firstItem else {
      selectFromKeyboardNavigation(item: firstItem)
      return
    }
    await extendSelection(
      from: lead,
      destination: firstItem,
      isRange: true,
      generation: generation
    )
  }

  @MainActor
  private func performExtendHighlightToLast(generation: UInt) async {
    let lastItem: LocatedHistoryItem?
    do {
      lastItem = try await history.historyItems.last()
    } catch {
      return
    }
    guard isNavigationCurrent(generation) else { return }
    guard let lead = resolveLeadHistoryItem(), let lastItem else {
      selectFromKeyboardNavigation(item: lastItem)
      return
    }
    await extendSelection(
      from: lead,
      destination: lastItem,
      isRange: true,
      generation: generation
    )
  }
}
