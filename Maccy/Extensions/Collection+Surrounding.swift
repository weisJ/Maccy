extension Collection where Element: Equatable {
  func item(after: Element, where predicate: (Element) -> Bool) -> Element? {
    guard let currentIndex = firstIndex(of: after) else {
      return nil
    }

    var nextIndex = index(currentIndex, offsetBy: 1)
    while nextIndex < endIndex {
      let item = self[nextIndex]
      if predicate(item) {
        return item
      }
      nextIndex = index(nextIndex, offsetBy: 1)
    }
    return nil
  }

  func item(before: Element, where predicate: (Element) -> Bool) -> Element? {
    guard let currentIndex = firstIndex(of: before) else {
      return nil
    }

    var prevIndex = index(currentIndex, offsetBy: -1)
    while prevIndex >= startIndex {
      let item = self[prevIndex]
      if predicate(item) {
        return item
      }
      prevIndex = index(prevIndex, offsetBy: -1)
    }
    return nil
  }

  func between(from fromElement: Element, to toElement: Element, inOrder: Bool = false) -> [Element]? {
    guard let fromIndex = firstIndex(of: fromElement) else {
      return nil
    }
    guard let toIndex = firstIndex(of: toElement) else {
      return nil
    }
    let startIndex = Swift.min(fromIndex, toIndex)
    let endIndex = Swift.max(fromIndex, toIndex)
    let items = self[startIndex...endIndex]
    if !inOrder && fromIndex > toIndex {
      return items.reversed()
    } else {
      return Array(items)
    }
  }
}
