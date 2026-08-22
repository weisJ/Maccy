import Defaults
import KeyboardShortcuts
import SwiftUI

private struct KeyboardShortcutHelpModifier: ViewModifier {
  // A nil name produces help text without a keyboard shortcut substitution.
  let name: KeyboardShortcuts.Name?
  let key: String
  let tableName: String
  let comment: String = ""
  let replacementKey: String

  // Use the same localized description for visual help and the accessibility label.
  private var resolvedText: Text? {
    let localized = NSLocalizedString(key, tableName: tableName, comment: comment)
    guard let name else {
      return Text(localized)
    }
    guard let shortcut = KeyboardShortcuts.Shortcut(name: name) else {
      return nil
    }
    return Text(localized.replacingOccurrences(of: "{\(replacementKey)}", with: shortcut.description))
  }

  func body(content: Content) -> some View {
    if let resolvedText {
      content
        .help(resolvedText)
        .accessibilityLabel(resolvedText)
    } else {
      content
    }
  }
}

struct ToolbarButton<Label: View>: View {
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false

  var sharesGlassBackground = false
  let action: @MainActor () -> Void
  let label: () -> Label

  var body: some View {
    Button(action: action) {
      label()
    }
    .frame(width: 28, height: 28)
    .modifier(
      ToolbarButtonModifier(
        sharesGlassBackground: sharesGlassBackground,
        isHovering: isHovering && isEnabled
      )
    )
    .onHover(perform: { inside in
      isHovering = inside
    })
    .excludeFromWindowMovableByBackground()
  }

  func shortcutKeyHelp(
    name: KeyboardShortcuts.Name? = nil,
    key: String,
    tableName: String,
    replacementKey: String = ""
  ) -> some View {
    self.modifier(
      KeyboardShortcutHelpModifier(
        name: name,
        key: key,
        tableName: tableName,
        replacementKey: replacementKey
      )
    )
  }

}

private struct ToolbarButtonModifier: ViewModifier {
  let sharesGlassBackground: Bool
  let isHovering: Bool

  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      if sharesGlassBackground {
        content
          .buttonStyle(.plain)
          .background {
            Circle()
              .fill(Color.primary.opacity(isHovering ? 0.1 : 0))
          }
          .animation(.easeOut(duration: 0.12), value: isHovering)
      } else {
        content
          .buttonStyle(.glass)
          .buttonBorderShape(.circle)
      }
    } else {
      content
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
    }
  }

}

private struct SharedToolbarButtonBackgroundModifier: ViewModifier {

  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content
        .glassEffect(.regular.interactive(), in: .capsule)
    } else {
      content
    }
  }

}

struct ToolbarButtonGroup<Content: View>: View {
  @ViewBuilder var content: () -> Content

  private var spacing: CGFloat {
    if #available(macOS 26.0, *) {
      return 0
    } else {
      return 8
    }
  }

  var body: some View {
    HStack(spacing: spacing) {
      content()
    }
    .modifier(SharedToolbarButtonBackgroundModifier())
  }
}

private struct ToolbarContainerModifier: ViewModifier {

  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      GlassEffectContainer {
        content
      }
    } else {
      content
    }
  }

}

struct ToolbarView: View {
  @State private var appState = AppState.shared
  @State private var editingItem: HistoryItemDecorator?

  private var shouldUnpin: Bool {
    return appState.navigator.selection.items.allSatisfy { $0.isPinned }
  }

  private var pinActionDisabled: Bool {
    return appState.navigator.selection.items.contains { $0.isPinned }
      && appState.navigator.selection.items.contains { !$0.isPinned }
  }

  private var selectedImageItem: HistoryItemDecorator? {
    guard appState.navigator.selection.count == 1,
          let item = appState.navigator.selection.first,
          item.hasImage else {
      return nil
    }

    return item
  }

  private var selectedImageText: String? {
    guard let item = selectedImageItem else {
      return nil
    }

    let text = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : item.title
  }

  private var editItemEnabled: Bool {
    guard appState.navigator.selection.count == 1 else { return false }
    guard let item = appState.navigator.selection.first else { return false }
    return item.hasPlainText || item.hasRichText || item.hasImage
  }

  private var editableItem: HistoryItemDecorator? {
    guard editItemEnabled else { return nil }
    return appState.navigator.selection.first
  }

  var body: some View {
    HStack {
      Spacer()
      if !appState.navigator.selection.isEmpty {
        Spacer()

        if selectedImageItem != nil {
          ToolbarButton {
            guard let selectedImageText else { return }
            Clipboard.shared.copyInMaccy(selectedImageText)
          } label: {
            Image(systemName: "text.viewfinder")
          }
          .shortcutKeyHelp(key: "CopyExtractedText", tableName: "PreviewItemView")
          .disabled(selectedImageText == nil)
        }

        ToolbarButtonGroup {
          ToolbarButton(sharesGlassBackground: true) {
            withAnimation {
              appState.togglePin()
            }
          } label: {
            if (appState.navigator.selection.items.allSatisfy { $0.isPinned }) {
              Image(systemName: "pin.slash")
            } else {
              Image(systemName: "pin")
            }
          }
          .shortcutKeyHelp(
            name: .pin,
            key: shouldUnpin ? "UnpinKey" : "PinKey",
            tableName: "PreviewItemView",
            replacementKey: "pinKey"
          )
          .disabled(pinActionDisabled)

          ToolbarButton(sharesGlassBackground: true) {
            appState.isEditingItem = true
            editingItem = editableItem
          } label: {
            Image(systemName: "pencil.and.list.clipboard")
          }
          .shortcutKeyHelp(key: "EditItem", tableName: "PreviewItemView")
          .disabled(!editItemEnabled)
          .accessibilityIdentifier("edit-item")

          ToolbarButton(sharesGlassBackground: true) {
            appState.deleteSelection()
          } label: {
            Image(systemName: "trash")
          }
          .shortcutKeyHelp(
            name: .delete,
            key: "DeleteKey",
            tableName: "PreviewItemView",
            replacementKey: "deleteKey"
          )
        }
      }

      if appState.navigator.pasteStackSelected {
        ToolbarButton {
          appState.removePasteStack()
        } label: {
          Image(systemName: "stop")
        }
        .accessibilityLabel(Text("toolbar_remove_paste_stack_action"))
        .help(Text("StopPasteStack", tableName: "PreviewItemView"))
      }
    }
    .modifier(ToolbarContainerModifier())
    .sheet(item: $editingItem, onDismiss: {
      finishEditingPinnedItem()
    }) { item in
      ItemEditorView(for: item)
    }
  }

  private func finishEditingPinnedItem() {
    editingItem = nil
    appState.isEditingItem = false
  }
}
