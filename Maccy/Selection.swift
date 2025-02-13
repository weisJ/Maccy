import AppKit

struct Selection<Item: Hashable> {
  private var items: Set<Item> = Set()

  init(items: any Collection<Item> = []) {
    self.items = Set(items)
  }

  var isEmpty: Bool {
    return items.isEmpty
  }

  func first(where condition: (Item) -> Bool) -> Item? {
    return items.first(where: condition)
  }

  func forEach(_ body: (Item) throws -> Void) rethrows {
    try items.forEach(body)
  }

  mutating func remove(_ item: Item) {
    items.remove(item)
  }

  mutating func add(_ item: Item) {
    items.insert(item)
  }
}
