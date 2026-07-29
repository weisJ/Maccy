import SwiftUI

struct PinsView: View {
  @Environment(AppState.self) private var appState

  var items: [HistoryItemDecorator]

  var body: some View {
    MultipleSelectionListView(items: items) { previous, item, next in
      HistoryItemView(item: item, previous: previous, next: next)
    }
  }
}
