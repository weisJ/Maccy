import AppKit
import Defaults
import Foundation
import Settings
import SwiftUI

@Observable
final class AppState: Sendable {
  static let shared = AppState()

  var appDelegate: AppDelegate?
  var popup: Popup
  var history: History
  var footer: Footer

  var scrollTarget: UUID?
  var leadSelection: UUID?

  var leadHistoryItem: HistoryItemDecorator? {
    guard let leadSelection else { return nil }
    return history.selection.first { $0.id == leadSelection }
  }

  func select(_ item: UUID?) {
    withTransaction(Transaction()) {
      selectWithoutScrolling(item)
      scrollTarget = item
    }
  }

  func extendSelection(from fromItem: HistoryItemDecorator, to toItem: HistoryItemDecorator, isRange: Bool) {
    var newSelectionState = history.selection

    if isRange {
      if let itemRange = history.visibleItems.between(from: fromItem, to: toItem) {
        newSelectionState = Selection(items: itemRange)
      }
    } else {
      if toItem.isSelected {
        newSelectionState.remove(fromItem)
      }
      newSelectionState.add(toItem)
    }

    withTransaction(Transaction()) {
      history.selection = newSelectionState
      leadSelection = toItem.id
      scrollTarget = leadSelection
    }
  }

  func selectWithoutScrolling(_ item: UUID?) {
    leadSelection = item
    if let item = history.items.first(where: { $0.id == item }) {
      selectInHistory(item)
    } else if let item = footer.items.first(where: { $0.id == item }) {
      selectInFooter(item)
    } else {
      history.selection = .init()
      footer.selectedItem = nil
    }
  }

  private func selectInHistory(_ item: HistoryItemDecorator) {
    history.selection = .init(items: [item])
    footer.selectedItem = nil
  }

  private func selectInFooter(_ item: FooterItem) {
    history.selection = .init()
    footer.selectedItem = item
  }

  var hoverSelectionWhileKeyboardNavigating: UUID?
  var isKeyboardNavigating: Bool = true {
    didSet {
      if !isKeyboardNavigating,
         let hoverSelection = hoverSelectionWhileKeyboardNavigating {
        hoverSelectionWhileKeyboardNavigating = nil
        select(hoverSelection)
      }
    }
  }

  var showPreview: Bool = false
  var previewItem: HistoryItemDecorator? {
    get {
      return showPreview ? leadHistoryItem : nil
    }
    set {}
  }

  var searchVisible: Bool {
    if !Defaults[.showSearch] { return false }
    switch Defaults[.searchVisibility] {
    case .always: return true
    case .duringSearch: return !history.searchQuery.isEmpty
    }
  }

  var menuIconText: String {
    var title = history.unpinnedItems.first?.text.shortened(to: 100)
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    title.unicodeScalars.removeAll(where: CharacterSet.newlines.contains)
    return title.shortened(to: 20)
  }

  private let about = About()
  private var settingsWindowController: SettingsWindowController?

  init() {
    history = History.shared
    footer = Footer()
    popup = Popup()
  }

  @MainActor
  func select() {
    if !history.selection.isEmpty {
      let selectedItems = history.items.filter({ $0.isSelected })
      Task {
        await history.select(selectedItems)
      }
    } else if let item = footer.selectedItem {
      if item.confirmation != nil {
        item.showConfirmation = true
      } else {
        item.action()
      }
    } else {
      Task {
        await Clipboard.shared.copy(history.searchQuery)
        history.searchQuery = ""
      }
    }
  }

  private func selectFromKeyboardNavigation(_ id: UUID?) {
    isKeyboardNavigating = true
    select(id)
  }

  private func extendHistorySelectionFromKeyboardNavigation(from fromItem: HistoryItemDecorator, to toItem: HistoryItemDecorator, isRange: Bool) {
    isKeyboardNavigating = true
    extendSelection(from: fromItem, to: toItem, isRange: isRange)
  }

  func highlightFirst() {
    if let item = history.items.first(where: \.isVisible) {
      selectFromKeyboardNavigation(item.id)
    }
  }

  func highlightPrevious() {
    guard let leadSelection else { return }

    if let historyItem = history.visibleItems.first(where: { $0.id == leadSelection }) {
      if let nextItem = history.visibleItems.item(before: historyItem) {
        selectFromKeyboardNavigation(nextItem.id)
      } else {
        selectFromKeyboardNavigation(history.firstVisibleItem?.id)
      }
    } else if let footerItem = footer.visibleItems.first(where: { $0.id == leadSelection }) {
      if let nextItem = footer.visibleItems.item(before: footerItem) {
        selectFromKeyboardNavigation(nextItem.id)
      } else if let nextItem = history.lastVisibleItem {
        selectFromKeyboardNavigation(nextItem.id)
      }
    }
  }

  func highlightNext() {
    guard let leadSelection else { return }

    if let historyItem = history.visibleItems.first(where: { $0.id == leadSelection }) {
      if let nextItem = history.visibleItems.item(after: historyItem) {
        selectFromKeyboardNavigation(nextItem.id)
      } else if let nextItem = footer.firstVisibleItem {
        selectFromKeyboardNavigation(nextItem.id)
      }
    } else if let footerItem = footer.visibleItems.first(where: { $0.id == leadSelection }) {
      if let nextItem = footer.visibleItems.item(after: footerItem) {
        selectFromKeyboardNavigation(nextItem.id)
      } else if let nextItem = footer.firstVisibleItem {
        selectFromKeyboardNavigation(nextItem.id)
      }
    }
  }

  func highlightLast() {
    guard let leadSelection else { return }

    if let historyItem = history.visibleItems.first(where: { $0.id == leadSelection }) {
      if historyItem == history.lastVisibleItem,
         let nextItem = footer.firstVisibleItem {
        selectFromKeyboardNavigation(nextItem.id)
      } else {
        selectFromKeyboardNavigation(history.lastVisibleItem?.id)
      }
    } else if footer.selectedItem != nil {
      selectFromKeyboardNavigation(footer.lastVisibleItem?.id)
    } else {
      selectFromKeyboardNavigation(footer.firstVisibleItem?.id)
    }
  }

  func extendHighlightToNext() {
    if let leadSelection,
       let leadItem = history.visibleItems.first(where: {$0.id == leadSelection}) {
      guard let nextItem = history.visibleItems.item(after: leadItem) else { return }
      extendHistorySelectionFromKeyboardNavigation(from: leadItem, to: nextItem, isRange: false)
    } else {
      highlightNext()
    }
  }

  func extendHighlightToPrevious() {
    if let leadSelection,
       let leadItem = history.visibleItems.first(where: {$0.id == leadSelection}) {
      guard let nextItem = history.visibleItems.item(before: leadItem) else { return }
      extendHistorySelectionFromKeyboardNavigation(from: leadItem, to: nextItem, isRange: false)
    } else {
      highlightPrevious()
    }
  }

  func extendHighlightToFirst() {
    if let leadSelection,
       let leadItem = history.visibleItems.first(where: {$0.id == leadSelection}) {
      guard let nextItem = history.firstVisibleItem else { return }
      extendHistorySelectionFromKeyboardNavigation(from: leadItem, to: nextItem, isRange: true)
    } else {
      highlightFirst()
    }
  }

  func extendHighlightToLast() {
    if let leadSelection,
       let leadItem = history.visibleItems.first(where: {$0.id == leadSelection}) {
      guard let nextItem = history.lastVisibleItem else { return }
      extendHistorySelectionFromKeyboardNavigation(from: leadItem, to: nextItem, isRange: true)
    } else {
      highlightFirst()
    }
  }

  func openAbout() {
    about.openAbout(nil)
  }

  @MainActor
  func openPreferences() { // swiftlint:disable:this function_body_length
    if settingsWindowController == nil {
      settingsWindowController = SettingsWindowController(
        panes: [
          Settings.Pane(
            identifier: Settings.PaneIdentifier.general,
            title: NSLocalizedString("Title", tableName: "GeneralSettings", comment: ""),
            toolbarIcon: NSImage.gearshape!
          ) {
            GeneralSettingsPane()
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.storage,
            title: NSLocalizedString("Title", tableName: "StorageSettings", comment: ""),
            toolbarIcon: NSImage.externaldrive!
          ) {
            StorageSettingsPane()
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.appearance,
            title: NSLocalizedString("Title", tableName: "AppearanceSettings", comment: ""),
            toolbarIcon: NSImage.paintpalette!
          ) {
            AppearanceSettingsPane()
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.pins,
            title: NSLocalizedString("Title", tableName: "PinsSettings", comment: ""),
            toolbarIcon: NSImage.pincircle!
          ) {
            PinsSettingsPane()
              .environment(self)
              .modelContainer(Storage.shared.container)
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.ignore,
            title: NSLocalizedString("Title", tableName: "IgnoreSettings", comment: ""),
            toolbarIcon: NSImage.nosign!
          ) {
            IgnoreSettingsPane()
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.advanced,
            title: NSLocalizedString("Title", tableName: "AdvancedSettings", comment: ""),
            toolbarIcon: NSImage.gearshape2!
          ) {
            AdvancedSettingsPane()
          }
        ]
      )
    }
    settingsWindowController?.show()
    settingsWindowController?.window?.orderFrontRegardless()
  }

  func quit() {
    NSApp.terminate(self)
  }
}
