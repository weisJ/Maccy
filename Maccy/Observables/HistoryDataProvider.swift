import Defaults
import Foundation
import SwiftData

/// Builds the pinned snapshot and packed unpinned-page query from storage.
///
/// The provider owns query-wide work such as search and row-height metadata.
/// `PagedHistoryItems` remains responsible only for retaining page slices.
@MainActor
final class HistoryDataProvider {
  struct PinnedSnapshot {
    let allItems: [HistoryItemDecorator]
    let visibleItems: [HistoryItemDecorator]
  }

  private enum UnpinnedQuery {
    case storage(
      count: Int,
      layoutSummaries: [HistoryPageLayoutSummary]
    )
    case search(
      results: [Search.SearchResult],
      layoutSummaries: [HistoryPageLayoutSummary]
    )

    var count: Int {
      switch self {
      case let .storage(count, _):
        count
      case let .search(results, _):
        results.count
      }
    }

    var layoutSummaries: [HistoryPageLayoutSummary] {
      switch self {
      case let .storage(_, layoutSummaries),
           let .search(_, layoutSummaries):
        layoutSummaries
      }
    }
  }

  private final class WeakDecorator {
    weak var value: HistoryItemDecorator?

    init(_ value: HistoryItemDecorator) {
      self.value = value
    }
  }

  private let search = Search()
  private let sorter = Sorter()

  private var searchQuery = ""
  private var pageSize: Int?
  private var unpinnedQuery: UnpinnedQuery?
  private var decorators: [
    PersistentIdentifier: WeakDecorator
  ] = [:]

  nonisolated init() {}

  func prepare(searchQuery: String, pageSize: Int?) {
    self.searchQuery = searchQuery
    self.pageSize = pageSize
    unpinnedQuery = nil
  }

  func adopt(_ items: some Sequence<HistoryItemDecorator>) {
    for item in items {
      decorators[item.item.persistentModelID] = WeakDecorator(item)
    }
    pruneDecoratorCache()
  }

  func remove(_ item: HistoryItemDecorator) {
    remove(modelID: item.item.persistentModelID)
  }

  func remove(modelID: PersistentIdentifier) {
    decorators[modelID] = nil
  }

  func removeAll() {
    decorators.removeAll()
    unpinnedQuery = nil
  }

  func decorator(for item: HistoryItem) -> HistoryItemDecorator {
    let modelID = item.persistentModelID
    if let decorator = decorators[modelID]?.value {
      return decorator
    }
    let decorator = HistoryItemDecorator(item)
    decorators[modelID] = WeakDecorator(decorator)
    pruneDecoratorCache()
    return decorator
  }

  func pinnedSnapshot() throws -> PinnedSnapshot {
    let descriptor = FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.pin != nil },
      sortBy: sorter.sortDescriptors()
    )
    let allItems = try Storage.shared.context.fetch(descriptor).map {
      let item = decorator(for: $0)
      item.highlight("", [])
      return item
    }
    guard !searchQuery.isEmpty else {
      return PinnedSnapshot(allItems: allItems, visibleItems: allItems)
    }

    let results = search.search(string: searchQuery, within: allItems)
    for result in results {
      result.object.highlight(searchQuery, result.ranges)
    }
    return PinnedSnapshot(
      allItems: allItems,
      visibleItems: results.map(\.object)
    )
  }

  func load(
    _ request: PagedHistoryItems.QueryRequest
  ) throws -> PagedHistoryItems.QuerySnapshot {
    precondition(
      request.pageSize == pageSize,
      "The page source and its query provider must use the same page size"
    )
    let query = try unpinnedQuery ?? buildUnpinnedQuery()
    unpinnedQuery = query

    let slices = try request.ranges.map { requestedRange in
      let range = Self.clamp(requestedRange, toCount: query.count)
      let items = try items(in: range, from: query)
      return PagedHistoryItems.QuerySlice(range: range, items: items)
    }
    return PagedHistoryItems.QuerySnapshot(
      filteredCount: query.count,
      slices: slices,
      layoutSummaries: request.includesLayoutSummaries
        ? query.layoutSummaries
        : nil
    )
  }

  func findSimilarItem(
    to item: HistoryItem,
    among loadedItems: some Sequence<HistoryItemDecorator>
  ) throws -> HistoryItem? {
    if let loadedItem = loadedItems.first(where: {
      $0.item !== item && $0.item.supersedes(item)
    }) {
      return loadedItem.item
    }

    let batchSize = 250
    var offset = 0
    while true {
      var descriptor = FetchDescriptor<HistoryItem>(
        sortBy: sorter.sortDescriptors()
      )
      descriptor.fetchLimit = batchSize
      descriptor.fetchOffset = offset
      let candidates = try Storage.shared.context.fetch(descriptor)
      if let duplicate = candidates.first(where: {
        $0 !== item && $0.supersedes(item)
      }) {
        return duplicate
      }
      guard candidates.count == batchSize else { return nil }
      offset += candidates.count
    }
  }

  func overflowingUnpinnedItems(
    limit: Int,
    keeping protectedItems: Set<PersistentIdentifier> = []
  ) throws -> [HistoryItem] {
    let descriptor = FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.pin == nil },
      sortBy: sorter.sortDescriptors()
    )
    let items = try Storage.shared.context.fetch(descriptor)
    let overflowCount = max(0, items.count - max(0, limit))
    guard overflowCount > 0 else { return [] }

    return Array(
      items.reversed().lazy
        .filter { !protectedItems.contains($0.persistentModelID) }
        .prefix(overflowCount)
    )
  }

  func index(of item: HistoryItemDecorator) throws -> Int? {
    let query = try unpinnedQuery ?? buildUnpinnedQuery()
    unpinnedQuery = query
    let modelID = item.item.persistentModelID

    switch query {
    case .storage:
      let descriptor = FetchDescriptor<HistoryItem>(
        predicate: #Predicate { $0.pin == nil },
        sortBy: sorter.sortDescriptors()
      )
      return try Storage.shared.context.fetch(descriptor)
        .firstIndex { $0.persistentModelID == modelID }
    case let .search(results, _):
      return results.firstIndex {
        $0.object.item.persistentModelID == modelID
      }
    }
  }
}

private extension HistoryDataProvider {
  private func buildUnpinnedQuery() throws -> UnpinnedQuery {
    if searchQuery.isEmpty {
      return try buildStorageQuery()
    }

    let descriptor = FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.pin == nil },
      sortBy: sorter.sortDescriptors()
    )
    let candidates = try Storage.shared.context.fetch(descriptor).map {
      let item = decorator(for: $0)
      item.highlight("", [])
      return item
    }
    let results = search.search(string: searchQuery, within: candidates)
    for result in results {
      result.object.highlight(searchQuery, result.ranges)
    }
    return .search(
      results: results,
      layoutSummaries: layoutSummaries(
        for: results.lazy.map(\.object.item)
      )
    )
  }

  private func buildStorageQuery() throws -> UnpinnedQuery {
    let batchSize = max(500, (pageSize ?? 1) * 10)
    var offset = 0
    var itemCount = 0
    var alternateItemCount = 0
    var summaries: [HistoryPageLayoutSummary] = []

    while true {
      var descriptor = FetchDescriptor<HistoryItem>(
        predicate: #Predicate { $0.pin == nil },
        sortBy: sorter.sortDescriptors()
      )
      descriptor.fetchLimit = batchSize
      descriptor.fetchOffset = offset
      let items = try Storage.shared.context.fetch(descriptor)
      for item in items {
        appendLayout(
          for: item,
          itemCount: &itemCount,
          alternateItemCount: &alternateItemCount,
          summaries: &summaries
        )
      }
      offset += items.count
      guard items.count == batchSize else { break }
    }

    appendPartialLayout(
      itemCount: &itemCount,
      alternateItemCount: &alternateItemCount,
      summaries: &summaries
    )
    return .storage(
      count: offset,
      layoutSummaries: summaries
    )
  }

  private func items(
    in range: Range<Int>,
    from query: UnpinnedQuery
  ) throws -> [HistoryItemDecorator] {
    guard !range.isEmpty else { return [] }

    switch query {
    case .storage:
      var descriptor = FetchDescriptor<HistoryItem>(
        predicate: #Predicate { $0.pin == nil },
        sortBy: sorter.sortDescriptors()
      )
      descriptor.fetchLimit = range.count
      descriptor.fetchOffset = range.lowerBound
      return try Storage.shared.context.fetch(descriptor)
        .enumerated()
        .map { offset, item in
          configure(
            decorator(for: item),
            at: range.lowerBound + offset
          )
        }
    case let .search(results, _):
      return results[range].enumerated().map { offset, result in
        result.object.highlight(searchQuery, result.ranges)
        return configure(
          result.object,
          at: range.lowerBound + offset
        )
      }
    }
  }

  private func configure(
    _ item: HistoryItemDecorator,
    at index: Int
  ) -> HistoryItemDecorator {
    item.shortcuts = index < 9
      ? KeyShortcut.create(character: String(index + 1))
      : []
    return item
  }

  private func layoutSummaries(
    for items: some Sequence<HistoryItem>
  ) -> [HistoryPageLayoutSummary] {
    var itemCount = 0
    var alternateItemCount = 0
    var summaries: [HistoryPageLayoutSummary] = []
    for item in items {
      appendLayout(
        for: item,
        itemCount: &itemCount,
        alternateItemCount: &alternateItemCount,
        summaries: &summaries
      )
    }
    appendPartialLayout(
      itemCount: &itemCount,
      alternateItemCount: &alternateItemCount,
      summaries: &summaries
    )
    return summaries
  }

  private func appendLayout(
    for item: HistoryItem,
    itemCount: inout Int,
    alternateItemCount: inout Int,
    summaries: inout [HistoryPageLayoutSummary]
  ) {
    itemCount += 1
    if item.hasImageContent {
      alternateItemCount += 1
    }
    guard let pageSize, itemCount == pageSize else { return }
    appendPartialLayout(
      itemCount: &itemCount,
      alternateItemCount: &alternateItemCount,
      summaries: &summaries
    )
  }

  private func appendPartialLayout(
    itemCount: inout Int,
    alternateItemCount: inout Int,
    summaries: inout [HistoryPageLayoutSummary]
  ) {
    guard itemCount > 0 else { return }
    summaries.append(HistoryPageLayoutSummary(
      itemCount: itemCount,
      alternateItemCount: alternateItemCount
    ))
    itemCount = 0
    alternateItemCount = 0
  }

  private func pruneDecoratorCache() {
    guard decorators.count > 256 else { return }
    decorators = decorators.filter { $0.value.value != nil }
  }

  private static func clamp(
    _ range: Range<Int>,
    toCount count: Int
  ) -> Range<Int> {
    let lowerBound = min(max(0, range.lowerBound), count)
    let upperBound = min(max(lowerBound, range.upperBound), count)
    return lowerBound..<upperBound
  }
}
