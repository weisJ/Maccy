import SwiftUI

struct MultipleSelectionListView<Element, ID, Content>: View
    where ID: Hashable, Content: View, ID == Element.ID, Element: Identifiable {
  private let items: [Element]
  private let itemBeforeFirst: Element?
  private let itemAfterLast: Element?
  private let content: (Element?, Element, Element?) -> Content

  init(
    items: [Element],
    itemBeforeFirst: Element? = nil,
    itemAfterLast: Element? = nil,
    @ViewBuilder content: @escaping (Element?, Element, Element?) -> Content
  ) {
    self.items = items
    self.itemBeforeFirst = itemBeforeFirst
    self.itemAfterLast = itemAfterLast
    self.content = content
  }

  var body: some View {
    LazyVStack(spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.element.id) { (index, element) in
        let previous = index > 0 ? items[index - 1] : itemBeforeFirst
        let next = index < items.count - 1 ? items[index + 1] : itemAfterLast
        content(previous, element, next)
      }
    }
  }
}
