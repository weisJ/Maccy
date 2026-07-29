import SwiftUI

private struct HoverSelectionModifier: ViewModifier {
  @Environment(AppState.self) private var appState
  var selectionId: UUID

  func body(content: Content) -> some View {
    content.onHover { hovering in
      if hovering {
        if !appState.navigator.isKeyboardNavigating && !appState.navigator.isMultiSelectInProgress {
          appState.navigator.selectWithoutScrolling(id: selectionId)
        } else {
          appState.navigator.hoverSelectionWhileKeyboardNavigating =
            selectionId
        }
      }
    }
  }
}

extension View {
  func hoverSelectionId(_ selectionId: UUID) -> some View {
    modifier(HoverSelectionModifier(selectionId: selectionId))
  }
}
