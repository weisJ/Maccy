import Foundation
import SwiftData

enum HistoryItemSection: Equatable {
  case pinned
  case unpinned
}

struct HistoryItemLocation: Equatable {
  let section: HistoryItemSection
  let index: Int
}

struct IndexedHistoryItem {
  let item: HistoryItemDecorator
  let index: Int
}

struct LocatedHistoryItem {
  let item: HistoryItemDecorator
  let location: HistoryItemLocation
  let revision: UInt64
}

enum HistoryItemsError: Error {
  case staleLocation
}

protocol UnpinnedHistoryItems: AnyObject {
  var count: Int { get }
  var loadedItems: [IndexedHistoryItem] { get }
  var allowsSelectionExtensionToBoundary: Bool { get }

  @MainActor
  func item(at index: Int) async throws -> IndexedHistoryItem?

  @MainActor
  func first() async throws -> IndexedHistoryItem?

  @MainActor
  func last() async throws -> IndexedHistoryItem?

  func loadedItem(id: UUID) -> IndexedHistoryItem?

  @MainActor
  func contains(modelID: PersistentIdentifier) throws -> Bool

  @MainActor
  func resolve(
    modelID: PersistentIdentifier
  ) async throws -> IndexedHistoryItem?
}

extension UnpinnedHistoryItems {
  @MainActor
  func first() async throws -> IndexedHistoryItem? {
    try await item(at: 0)
  }

  @MainActor
  func last() async throws -> IndexedHistoryItem? {
    guard count > 0 else { return nil }
    return try await item(at: count - 1)
  }

  @MainActor
  func item(after index: Int) async throws -> IndexedHistoryItem? {
    guard index < Int.max else { return nil }
    return try await item(at: index + 1)
  }

  @MainActor
  func item(before index: Int) async throws -> IndexedHistoryItem? {
    guard index > Int.min else { return nil }
    return try await item(at: index - 1)
  }
}

/// Presents pinned and unpinned items as one ordered collection without
/// requiring either section to know where it is displayed.
final class HistoryItems {
  private let pinnedItems: () -> [HistoryItemDecorator]
  private let unpinnedItems: () -> any UnpinnedHistoryItems
  private let pinsPosition: () -> PinsPosition
  /// Advances whenever an existing location could identify a different item.
  private let revision: () -> UInt64

  init(
    pinnedItems: @escaping () -> [HistoryItemDecorator],
    unpinnedItems: @escaping () -> any UnpinnedHistoryItems,
    pinsPosition: @escaping () -> PinsPosition,
    revision: @escaping () -> UInt64 = { 0 }
  ) {
    self.pinnedItems = pinnedItems
    self.unpinnedItems = unpinnedItems
    self.pinsPosition = pinsPosition
    self.revision = revision
  }

  @MainActor
  var count: Int {
    pinnedItems().count + unpinnedItems().count
  }

  var allowsSelectionExtensionToBoundary: Bool {
    unpinnedItems().allowsSelectionExtensionToBoundary
  }

  var loadedItems: [LocatedHistoryItem] {
    let pins = pinnedItems().enumerated().map {
      located($0.element, in: .pinned, at: $0.offset)
    }
    let unpinned = unpinnedItems().loadedItems
      .sorted { $0.index < $1.index }
      .map(located)
    return pinsPosition() == .top
      ? pins + unpinned
      : unpinned + pins
  }

  func loadedItem(id: UUID) -> LocatedHistoryItem? {
    let pins = pinnedItems()
    if let index = pins.firstIndex(where: { $0.id == id }) {
      return located(pins[index], in: .pinned, at: index)
    }
    guard let result = unpinnedItems().loadedItem(id: id) else {
      return nil
    }
    return located(result)
  }

  func loadedItem(
    modelID: PersistentIdentifier
  ) -> LocatedHistoryItem? {
    let pins = pinnedItems()
    if let index = pins.firstIndex(where: {
      $0.item.persistentModelID == modelID
    }) {
      return located(pins[index], in: .pinned, at: index)
    }
    guard let result = unpinnedItems().loadedItems.first(where: {
      $0.item.item.persistentModelID == modelID
    }) else {
      return nil
    }
    return located(result)
  }

  @MainActor
  func contains(_ item: HistoryItemDecorator) -> Bool {
    let modelID = item.item.persistentModelID
    if pinnedItems().contains(where: {
      $0.item.persistentModelID == modelID
    }) {
      return true
    }
    return (try? unpinnedItems().contains(modelID: modelID)) == true
  }

  @MainActor
  func resolve(
    _ item: HistoryItemDecorator
  ) async throws -> LocatedHistoryItem? {
    let pins = pinnedItems()
    if let index = pins.firstIndex(where: {
      $0.item.persistentModelID == item.item.persistentModelID
    }) {
      return located(pins[index], in: .pinned, at: index)
    }
    guard let result = try await unpinnedItems().resolve(
      modelID: item.item.persistentModelID
    ) else {
      return nil
    }
    return located(result)
  }

  @MainActor
  func first() async throws -> LocatedHistoryItem? {
    if pinsPosition() == .top, let pin = pinnedItems().first {
      return located(pin, in: .pinned, at: 0)
    }
    if let item = try await unpinnedItems().first() {
      return located(item)
    }
    guard let pin = pinnedItems().first else { return nil }
    return located(pin, in: .pinned, at: 0)
  }

  @MainActor
  func firstUnpinned() async throws -> LocatedHistoryItem? {
    try await unpinnedItems().first().map(located)
  }

  @MainActor
  func last() async throws -> LocatedHistoryItem? {
    let pins = pinnedItems()
    if pinsPosition() == .bottom, let pin = pins.last {
      return located(pin, in: .pinned, at: pins.count - 1)
    }
    if let item = try await unpinnedItems().last() {
      return located(item)
    }
    guard let pin = pins.last else { return nil }
    return located(pin, in: .pinned, at: pins.count - 1)
  }

  @MainActor
  func item(
    at location: HistoryItemLocation
  ) async throws -> LocatedHistoryItem? {
    switch location.section {
    case .pinned:
      let pins = pinnedItems()
      guard pins.indices.contains(location.index) else { return nil }
      return located(pins[location.index], in: .pinned, at: location.index)
    case .unpinned:
      guard let item = try await unpinnedItems().item(at: location.index) else {
        return nil
      }
      return located(item)
    }
  }

  @MainActor
  func item(atDisplayIndex index: Int) async throws -> LocatedHistoryItem? {
    guard index >= 0, index < count else { return nil }

    let pinCount = pinnedItems().count
    if pinsPosition() == .top {
      if index < pinCount {
        return try await item(
          at: HistoryItemLocation(section: .pinned, index: index)
        )
      }
      return try await item(
        at: HistoryItemLocation(
          section: .unpinned,
          index: index - pinCount
        )
      )
    }

    let unpinnedCount = unpinnedItems().count
    if index < unpinnedCount {
      return try await item(
        at: HistoryItemLocation(section: .unpinned, index: index)
      )
    }
    return try await item(
      at: HistoryItemLocation(
        section: .pinned,
        index: index - unpinnedCount
      )
    )
  }

  @MainActor
  func item(
    before location: HistoryItemLocation
  ) async throws -> LocatedHistoryItem? {
    guard isValid(location) else { return nil }

    switch location.section {
    case .pinned:
      if location.index > 0 {
        return try await item(
          at: HistoryItemLocation(
            section: .pinned,
            index: location.index - 1
          )
        )
      }
      if pinsPosition() == .bottom {
        return try await unpinnedItems().last().map(located)
      }
      return nil
    case .unpinned:
      if let item = try await unpinnedItems().item(before: location.index) {
        return located(item)
      }
      guard pinsPosition() == .top else { return nil }
      let pins = pinnedItems()
      guard let pin = pins.last else { return nil }
      return located(pin, in: .pinned, at: pins.count - 1)
    }
  }

  @MainActor
  func item(
    before item: LocatedHistoryItem
  ) async throws -> LocatedHistoryItem? {
    try requireCurrent(item)
    let previous = try await self.item(before: item.location)
    try requireCurrent(item)
    return previous
  }

  @MainActor
  func item(
    after location: HistoryItemLocation
  ) async throws -> LocatedHistoryItem? {
    guard isValid(location) else { return nil }

    switch location.section {
    case .pinned:
      let pins = pinnedItems()
      if location.index + 1 < pins.count {
        return located(
          pins[location.index + 1],
          in: .pinned,
          at: location.index + 1
        )
      }
      if pinsPosition() == .top {
        return try await unpinnedItems().first().map(located)
      }
      return nil
    case .unpinned:
      if let item = try await unpinnedItems().item(after: location.index) {
        return located(item)
      }
      guard pinsPosition() == .bottom, let pin = pinnedItems().first else {
        return nil
      }
      return located(pin, in: .pinned, at: 0)
    }
  }

  @MainActor
  func item(
    after item: LocatedHistoryItem
  ) async throws -> LocatedHistoryItem? {
    try requireCurrent(item)
    let next = try await self.item(after: item.location)
    try requireCurrent(item)
    return next
  }

  func isFirst(_ location: HistoryItemLocation?) -> Bool {
    guard let location else { return false }
    if pinsPosition() == .top, !pinnedItems().isEmpty {
      return location == HistoryItemLocation(section: .pinned, index: 0)
    }
    if unpinnedItems().count > 0 {
      return location == HistoryItemLocation(section: .unpinned, index: 0)
    }
    return location == HistoryItemLocation(section: .pinned, index: 0)
  }

  @MainActor
  private func displayIndex(of location: HistoryItemLocation) -> Int? {
    switch location.section {
    case .pinned:
      guard pinnedItems().indices.contains(location.index) else { return nil }
      return pinsPosition() == .top
        ? location.index
        : unpinnedItems().count + location.index
    case .unpinned:
      guard location.index >= 0, location.index < unpinnedItems().count else {
        return nil
      }
      return pinsPosition() == .top
        ? pinnedItems().count + location.index
        : location.index
    }
  }

  private func isValid(_ location: HistoryItemLocation) -> Bool {
    switch location.section {
    case .pinned:
      return pinnedItems().indices.contains(location.index)
    case .unpinned:
      return location.index >= 0 && location.index < unpinnedItems().count
    }
  }

  private func located(_ item: IndexedHistoryItem) -> LocatedHistoryItem {
    located(item.item, in: .unpinned, at: item.index)
  }

  private func located(
    _ item: HistoryItemDecorator,
    in section: HistoryItemSection,
    at index: Int
  ) -> LocatedHistoryItem {
    LocatedHistoryItem(
      item: item,
      location: HistoryItemLocation(section: section, index: index),
      revision: revision()
    )
  }

  private func requireCurrent(_ item: LocatedHistoryItem) throws {
    guard item.revision == revision() else {
      throw HistoryItemsError.staleLocation
    }
  }
}

extension HistoryItems {
  @MainActor
  func range(
    from start: LocatedHistoryItem,
    through end: LocatedHistoryItem
  ) async throws -> [LocatedHistoryItem] {
    try requireCurrent(start)
    try requireCurrent(end)
    let result = try await range(
      from: start.location,
      through: end.location
    )
    try requireCurrent(start)
    return result
  }

  @MainActor
  func range(
    from start: HistoryItemLocation,
    through end: HistoryItemLocation
  ) async throws -> [LocatedHistoryItem] {
    guard allowsSelectionExtensionToBoundary,
      let startIndex = displayIndex(of: start),
      let endIndex = displayIndex(of: end)
    else {
      return []
    }

    let indices = startIndex <= endIndex
      ? Array(startIndex...endIndex)
      : Array((endIndex...startIndex).reversed())
    var result: [LocatedHistoryItem] = []
    result.reserveCapacity(indices.count)
    for index in indices {
      if let item = try await item(atDisplayIndex: index) {
        result.append(item)
      }
    }
    return result
  }

  @MainActor
  func nearest(
    to item: LocatedHistoryItem,
    where predicate: (HistoryItemDecorator) -> Bool
  ) async throws -> LocatedHistoryItem? {
    try requireCurrent(item)
    let result = try await nearest(to: item.location, where: predicate)
    try requireCurrent(item)
    return result
  }

  @MainActor
  func nearest(
    to location: HistoryItemLocation,
    where predicate: (HistoryItemDecorator) -> Bool
  ) async throws -> LocatedHistoryItem? {
    var previousLocation = location
    var nextLocation = location

    while true {
      let previous = try await item(before: previousLocation)
      let next = try await item(after: nextLocation)

      if let previous, predicate(previous.item) {
        return previous
      }
      if let next, predicate(next.item) {
        return next
      }
      guard previous != nil || next != nil else { return nil }
      if let previous {
        previousLocation = previous.location
      }
      if let next {
        nextLocation = next.location
      }
    }
  }
}
