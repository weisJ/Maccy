// swiftlint:disable file_length
import Defaults
import Foundation
import SwiftData

/// Builds the pinned snapshot and packed unpinned-page query from storage.
///
/// The provider owns query-wide work such as search and row-height metadata.
/// `PagedHistoryItems` remains responsible only for retaining page slices.
@MainActor
final class HistoryDataProvider { // swiftlint:disable:this type_body_length
  struct PinnedSnapshot {
    let allItems: [HistoryItemDecorator]
    let visibleItems: [HistoryItemDecorator]
  }

  // swiftlint:disable nesting
  /// Compact row-height metadata for a storage-backed paged query.
  ///
  /// Each page uses one bit per row to preserve enough information to move
  /// rows across page boundaries without fetching every history item again.
  struct StorageLayoutIndex: Equatable {
    struct Removal {
      let index: Int
      let isImage: Bool
    }

    struct Insertion {
      let index: Int
      let isImage: Bool
    }

    private struct Page: Equatable {
      private(set) var itemCount = 0
      private var imageRows: UInt64 = 0

      var summary: HistoryPageLayoutSummary {
        HistoryPageLayoutSummary(
          itemCount: itemCount,
          imageItemCount: imageRows.nonzeroBitCount
        )
      }

      func isImage(at index: Int) -> Bool? {
        guard index >= 0, index < itemCount else { return nil }
        return imageRows & (UInt64(1) << UInt64(index)) != 0
      }

      mutating func append(isImage: Bool) {
        insert(isImage: isImage, at: itemCount)
      }

      mutating func insert(isImage: Bool, at index: Int) {
        precondition(index >= 0 && index <= itemCount)
        precondition(itemCount < UInt64.bitWidth)

        let lowerRows = imageRows & Self.lowerBitMask(index)
        let upperRows = imageRows & ~Self.lowerBitMask(index)
        imageRows = lowerRows | (upperRows << 1)
        if isImage {
          imageRows |= UInt64(1) << UInt64(index)
        }
        itemCount += 1
      }

      mutating func remove(at index: Int) -> Bool? {
        guard let removedRow = isImage(at: index) else { return nil }

        let lowerRows = imageRows & Self.lowerBitMask(index)
        let upperRows = index + 1 < UInt64.bitWidth
          ? imageRows >> UInt64(index + 1)
          : 0
        imageRows = lowerRows | (upperRows << UInt64(index))
        itemCount -= 1
        return removedRow
      }

      private static func lowerBitMask(_ bitCount: Int) -> UInt64 {
        guard bitCount > 0 else { return 0 }
        guard bitCount < UInt64.bitWidth else { return .max }
        return (UInt64(1) << UInt64(bitCount)) - 1
      }
    }

    let pageSize: Int
    private var pages: [Page] = []
    private(set) var count = 0

    var layoutSummaries: [HistoryPageLayoutSummary] {
      pages.map(\.summary)
    }

    var imageRows: [Bool] {
      pages.flatMap { page in
        (0..<page.itemCount).map {
          page.isImage(at: $0) ?? false
        }
      }
    }

    init?(pageSize: Int) {
      guard pageSize > 0, pageSize <= UInt64.bitWidth else {
        return nil
      }
      self.pageSize = pageSize
    }

    init?(imageRows: [Bool], pageSize: Int) {
      guard let emptyIndex = Self(pageSize: pageSize) else {
        return nil
      }
      self = emptyIndex
      for isImage in imageRows {
        append(isImage: isImage)
      }
    }

    mutating func append(isImage: Bool) {
      if pages.last?.itemCount == pageSize || pages.isEmpty {
        pages.append(Page())
      }
      pages[pages.count - 1].append(isImage: isImage)
      count += 1
    }

    func applying(
      removals: [Removal],
      insertions: [Insertion]
    ) -> Self? {
      let removalIndices = Set(removals.map(\.index))
      guard removalIndices.count == removals.count,
        removals.allSatisfy({ $0.index >= 0 && $0.index < count })
      else {
        return nil
      }

      var updated = self
      for removal in removals.sorted(by: { $0.index > $1.index }) {
        guard updated.remove(at: removal.index) == removal.isImage else {
          return nil
        }
      }

      let insertionIndices = Set(insertions.map(\.index))
      guard insertionIndices.count == insertions.count else { return nil }
      for insertion in insertions.sorted(by: { $0.index < $1.index }) {
        guard updated.insert(
          isImage: insertion.isImage,
          at: insertion.index
        ) else {
          return nil
        }
      }
      return updated
    }

    private mutating func remove(at index: Int) -> Bool? {
      guard index >= 0, index < count else { return nil }
      let pageIndex = index / pageSize
      let localIndex = index % pageSize
      guard let removedRow = pages[pageIndex].remove(at: localIndex) else {
        return nil
      }

      for nextPageIndex in (pageIndex + 1)..<pages.count {
        guard let shiftedRow = pages[nextPageIndex].remove(at: 0) else {
          return nil
        }
        pages[nextPageIndex - 1].append(isImage: shiftedRow)
      }
      if pages.last?.itemCount == 0 {
        pages.removeLast()
      }
      count -= 1
      return removedRow
    }

    private mutating func insert(
      isImage: Bool,
      at index: Int
    ) -> Bool {
      guard index >= 0, index <= count else { return false }
      guard !pages.isEmpty else {
        append(isImage: isImage)
        return index == 0
      }

      let pageIndex = index / pageSize
      if pageIndex == pages.count {
        guard index == count else { return false }
        append(isImage: isImage)
        return true
      }

      var rowToInsert = isImage
      var localIndex = index % pageSize
      for currentPageIndex in pageIndex..<pages.count {
        var overflowRow: Bool?
        if pages[currentPageIndex].itemCount == pageSize {
          overflowRow = pages[currentPageIndex].remove(
            at: pageSize - 1
          )
        }
        pages[currentPageIndex].insert(
          isImage: rowToInsert,
          at: localIndex
        )
        guard let overflowRow else {
          count += 1
          return true
        }
        rowToInsert = overflowRow
        localIndex = 0
      }

      var page = Page()
      page.append(isImage: rowToInsert)
      pages.append(page)
      count += 1
      return true
    }
  }

  struct UnpinnedMutation {
    struct Removal {
      let index: Int
      let isImage: Bool
    }

    struct Insertion {
      let modelID: PersistentIdentifier
      let isImage: Bool
    }

    let removals: [Removal]
    let insertions: [Insertion]
  }
  // swiftlint:enable nesting

  fileprivate struct QueryConfiguration {
    let searchQuery: String
    let sortBy: Sorter.By
  }

  /// A prepared, immutable view of one history query.
  ///
  /// Query configuration is captured when the value is created. This lets a
  /// caller stage a replacement source without changing the provider used by
  /// the currently published source. Create a new query after storage changes;
  /// storage-backed slices deliberately remain lazy.
  struct Query {
    let pageSize: Int?

    fileprivate let configuration: QueryConfiguration?
    fileprivate let storageLayoutIndex: StorageLayoutIndex?
    private let pinnedSnapshotLoader: @MainActor () -> PinnedSnapshot
    private let pageLoader: @MainActor (
      PagedHistoryItems.QueryRequest
    ) throws -> PagedHistoryItems.QuerySnapshot
    private let indexLoader: @MainActor (
      PersistentIdentifier
    ) throws -> Int?

    fileprivate init(
      pageSize: Int?,
      configuration: QueryConfiguration?,
      storageLayoutIndex: StorageLayoutIndex?,
      pinnedSnapshotLoader: @escaping @MainActor () -> PinnedSnapshot,
      pageLoader: @escaping @MainActor (
        PagedHistoryItems.QueryRequest
      ) throws -> PagedHistoryItems.QuerySnapshot,
      indexLoader: @escaping @MainActor (
        PersistentIdentifier
      ) throws -> Int?
    ) {
      self.pageSize = pageSize
      self.configuration = configuration
      self.storageLayoutIndex = storageLayoutIndex
      self.pinnedSnapshotLoader = pinnedSnapshotLoader
      self.pageLoader = pageLoader
      self.indexLoader = indexLoader
    }

    static func empty(pageSize: Int?) -> Self {
      Query(
        pageSize: pageSize,
        configuration: nil,
        storageLayoutIndex: nil,
        pinnedSnapshotLoader: {
          PinnedSnapshot(allItems: [], visibleItems: [])
        },
        pageLoader: { request in
          guard request.pageSize == pageSize else {
            throw QueryError.pageSizeMismatch(
              expected: pageSize,
              actual: request.pageSize
            )
          }
          return PagedHistoryItems.QuerySnapshot(
            filteredCount: 0,
            slices: request.ranges.map { _ in
              PagedHistoryItems.QuerySlice(
                range: 0..<0,
                items: []
              )
            },
            layoutSummaries: request.includesLayoutSummaries ? [] : nil
          )
        },
        indexLoader: { _ in nil }
      )
    }

    @MainActor
    func loadPinnedSnapshot() -> PinnedSnapshot {
      pinnedSnapshotLoader()
    }

    @MainActor
    func load(
      _ request: PagedHistoryItems.QueryRequest
    ) throws -> PagedHistoryItems.QuerySnapshot {
      try pageLoader(request)
    }

    @MainActor
    func index(of modelID: PersistentIdentifier) throws -> Int? {
      try indexLoader(modelID)
    }
  }

  enum QueryError: LocalizedError {
    case pageSizeMismatch(expected: Int?, actual: Int?)

    var errorDescription: String? {
      switch self {
      case let .pageSizeMismatch(expected, actual):
        return """
        History query expected page size \(expected.map(String.init) ?? "nil"), \
        got \(actual.map(String.init) ?? "nil")
        """
      }
    }
  }

  private struct PinnedQuery {
    let allItems: [HistoryItemDecorator]
    let visibleResults: [Search.SearchResult]?
  }

  private struct PreparedQuery {
    let pinned: PinnedQuery
    let unpinned: UnpinnedQuery
  }

  private struct QueryItem {
    let item: HistoryItemDecorator
    let index: Int
    let highlightRanges: [Range<String.Index>]?
  }

  private struct StorageQuery {
    let count: Int
    let layoutSummaries: [HistoryPageLayoutSummary]
    let layoutIndex: StorageLayoutIndex?
  }

  private enum UnpinnedQuery {
    case storage(StorageQuery)
    case search(
      results: [Search.SearchResult],
      layoutSummaries: [HistoryPageLayoutSummary]
    )

    var count: Int {
      switch self {
      case let .storage(query):
        query.count
      case let .search(results, _):
        results.count
      }
    }

    var layoutSummaries: [HistoryPageLayoutSummary] {
      switch self {
      case let .storage(query):
        query.layoutSummaries
      case let .search(_, layoutSummaries):
        layoutSummaries
      }
    }

    var storageLayoutIndex: StorageLayoutIndex? {
      guard case let .storage(query) = self else { return nil }
      return query.layoutIndex
    }
  }

  private final class WeakDecorator {
    weak var value: HistoryItemDecorator?

    init(_ value: HistoryItemDecorator) {
      self.value = value
    }
  }

  private static let storageBatchSize = 500
  private let search = Search()
  private let sorter = Sorter()

  private var decorators: [
    PersistentIdentifier: WeakDecorator
  ] = [:]

  nonisolated init() {}

  func makeQuery(
    searchQuery: String,
    pageSize: Int?
  ) throws -> Query {
    let sortBy = Defaults[.sortBy]
    let sortDescriptors = sorter.sortDescriptors(by: sortBy)
    let preparedQuery = try prepareQuery(
      searchQuery: searchQuery,
      pageSize: pageSize,
      sortDescriptors: sortDescriptors
    )

    return makeQuery(
      configuration: QueryConfiguration(
        searchQuery: searchQuery,
        sortBy: sortBy
      ),
      pageSize: pageSize,
      preparedQuery: preparedQuery,
      sortDescriptors: sortDescriptors
    )
  }

  // swiftlint:disable function_body_length
  /// Reuses exact row metadata after a pin mutation when the current storage
  /// query still has the same empty-search, paging, and sort configuration.
  ///
  /// Returning `nil` means the caller must build a fresh query. No approximate
  /// metadata is ever published.
  func makeQuery(
    applying mutation: UnpinnedMutation,
    to currentQuery: Query,
    searchQuery: String,
    pageSize: Int?
  ) throws -> Query? {
    let sortBy = Defaults[.sortBy]
    guard searchQuery.isEmpty,
      let configuration = currentQuery.configuration,
      configuration.searchQuery == searchQuery,
      configuration.sortBy == sortBy,
      currentQuery.pageSize == pageSize,
      let currentLayoutIndex = currentQuery.storageLayoutIndex
    else {
      return nil
    }

    let sortDescriptors = sorter.sortDescriptors(by: sortBy)
    let removals = mutation.removals.map {
      StorageLayoutIndex.Removal(
        index: $0.index,
        isImage: $0.isImage
      )
    }
    guard let layoutAfterRemovals = currentLayoutIndex.applying(
      removals: removals,
      insertions: []
    ) else {
      return nil
    }

    let insertionModelIDs = Set(
      mutation.insertions.map(\.modelID)
    )
    guard insertionModelIDs.count == mutation.insertions.count,
      let insertionIndices = try storageIndices(
        of: insertionModelIDs,
        sortDescriptors: sortDescriptors
      )
    else {
      return nil
    }

    let insertions = mutation.insertions.compactMap { insertion in
      insertionIndices[insertion.modelID].map {
        StorageLayoutIndex.Insertion(
          index: $0,
          isImage: insertion.isImage
        )
      }
    }
    guard insertions.count == mutation.insertions.count,
      let layoutIndex = layoutAfterRemovals.applying(
        removals: [],
        insertions: insertions
      )
    else {
      return nil
    }

    let countDescriptor = FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.pin == nil }
    )
    guard try Storage.shared.context.fetchCount(countDescriptor)
      == layoutIndex.count
    else {
      return nil
    }

    let preparedQuery = PreparedQuery(
      pinned: PinnedQuery(
        allItems: try fetchPinnedItems(
          sortDescriptors: sortDescriptors
        ),
        visibleResults: nil
      ),
      unpinned: .storage(
        StorageQuery(
          count: layoutIndex.count,
          layoutSummaries: layoutIndex.layoutSummaries,
          layoutIndex: layoutIndex
        )
      )
    )
    return makeQuery(
      configuration: configuration,
      pageSize: pageSize,
      preparedQuery: preparedQuery,
      sortDescriptors: sortDescriptors,
      knownIndices: insertionIndices
    )
  }
  // swiftlint:enable function_body_length

  private func makeQuery(
    configuration: QueryConfiguration,
    pageSize: Int?,
    preparedQuery: PreparedQuery,
    sortDescriptors: [SortDescriptor<HistoryItem>],
    knownIndices: [
      PersistentIdentifier: Int
    ] = [:]
  ) -> Query {
    return Query(
      pageSize: pageSize,
      configuration: configuration,
      storageLayoutIndex: preparedQuery.unpinned.storageLayoutIndex,
      pinnedSnapshotLoader: { [self] in
        pinnedSnapshot(
          from: preparedQuery.pinned,
          searchQuery: configuration.searchQuery
        )
      },
      pageLoader: { [self] request in
        try load(
          request,
          from: preparedQuery.unpinned,
          searchQuery: configuration.searchQuery,
          pageSize: pageSize,
          sortDescriptors: sortDescriptors
        )
      },
      indexLoader: { [self] modelID in
        if let knownIndex = knownIndices[modelID] {
          return knownIndex
        }
        return try index(
          of: modelID,
          in: preparedQuery.unpinned,
          sortDescriptors: sortDescriptors
        )
      }
    )
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

  private func load(
    _ request: PagedHistoryItems.QueryRequest,
    from query: UnpinnedQuery,
    searchQuery: String,
    pageSize: Int?,
    sortDescriptors: [SortDescriptor<HistoryItem>]
  ) throws -> PagedHistoryItems.QuerySnapshot {
    guard request.pageSize == pageSize else {
      throw QueryError.pageSizeMismatch(
        expected: pageSize,
        actual: request.pageSize
      )
    }
    let stagedSlices = try request.ranges.map { requestedRange in
      let range = Self.clamp(requestedRange, toCount: query.count)
      let items = try queryItems(
        in: range,
        from: query,
        sortDescriptors: sortDescriptors
      )
      return (range, items)
    }
    let slices = stagedSlices.map { range, items in
      PagedHistoryItems.QuerySlice(
        range: range,
        items: items.map {
          present($0, searchQuery: searchQuery)
        }
      )
    }
    return PagedHistoryItems.QuerySnapshot(
      filteredCount: query.count,
      slices: slices,
      layoutSummaries: request.includesLayoutSummaries
        ? query.layoutSummaries
        : nil
    )
  }
}

extension HistoryDataProvider {
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
    let predicate = #Predicate<HistoryItem> { $0.pin == nil }
    let countDescriptor = FetchDescriptor<HistoryItem>(
      predicate: predicate
    )
    let itemCount = try Storage.shared.context.fetchCount(countDescriptor)
    let overflowCount = max(0, itemCount - max(0, limit))
    guard overflowCount > 0 else { return [] }

    // Fetch only enough of the oldest end to skip every protected item.
    // Protected items are preferred, but the retention limit remains strict
    // when there are more protected items than the configured capacity.
    let candidateCount = min(
      itemCount,
      overflowCount + protectedItems.count
    )
    var descriptor = FetchDescriptor<HistoryItem>(
      predicate: predicate,
      sortBy: sorter.sortDescriptors()
    )
    descriptor.fetchOffset = itemCount - candidateCount
    descriptor.fetchLimit = candidateCount
    let oldestItems = try Storage.shared.context.fetch(descriptor).reversed()
    let preferredCandidates = oldestItems.filter {
      !protectedItems.contains($0.persistentModelID)
    }
    let protectedCandidates = oldestItems.filter {
      protectedItems.contains($0.persistentModelID)
    }
    let deletionCandidates = preferredCandidates + protectedCandidates

    return Array(
      deletionCandidates.lazy
        .prefix(overflowCount)
    )
  }
}

private extension HistoryDataProvider {
  private func prepareQuery(
    searchQuery: String,
    pageSize: Int?,
    sortDescriptors: [SortDescriptor<HistoryItem>]
  ) throws -> PreparedQuery {
    guard !searchQuery.isEmpty else {
      return PreparedQuery(
        pinned: PinnedQuery(
          allItems: try fetchPinnedItems(
            sortDescriptors: sortDescriptors
          ),
          visibleResults: nil
        ),
        unpinned: try buildStorageQuery(
          pageSize: pageSize,
          sortDescriptors: sortDescriptors
        )
      )
    }

    let descriptor = FetchDescriptor<HistoryItem>(
      sortBy: sortDescriptors
    )
    let sortedItems = try Storage.shared.context.fetch(descriptor)
      .map { decorator(for: $0) }
    let pinnedItems = sortedItems.filter(\.isPinned)
    let unpinnedItems = sortedItems.filter(\.isUnpinned)
    let candidates = Defaults[.pinTo] == .top
      ? pinnedItems + unpinnedItems
      : unpinnedItems + pinnedItems
    let results = search.search(
      string: searchQuery,
      within: candidates
    )
    let pinnedResults = results.filter { $0.object.isPinned }
    let unpinnedResults = results.filter { $0.object.isUnpinned }

    return PreparedQuery(
      pinned: PinnedQuery(
        allItems: pinnedItems,
        visibleResults: pinnedResults
      ),
      unpinned: .search(
        results: unpinnedResults,
        layoutSummaries: layoutSummaries(
          for: unpinnedResults.lazy.map(\.object.item),
          pageSize: pageSize
        )
      )
    )
  }

  private func fetchPinnedItems(
    sortDescriptors: [SortDescriptor<HistoryItem>]
  ) throws -> [HistoryItemDecorator] {
    let descriptor = FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.pin != nil },
      sortBy: sortDescriptors
    )
    return try Storage.shared.context.fetch(descriptor).map {
      decorator(for: $0)
    }
  }

  private func pinnedSnapshot(
    from query: PinnedQuery,
    searchQuery: String
  ) -> PinnedSnapshot {
    guard let visibleResults = query.visibleResults else {
      query.allItems.forEach(clearHighlight)
      return PinnedSnapshot(
        allItems: query.allItems,
        visibleItems: query.allItems
      )
    }

    let visibleResultsByModelID = Dictionary(
      uniqueKeysWithValues: visibleResults.map {
        ($0.object.item.persistentModelID, $0)
      }
    )
    for item in query.allItems {
      if let result = visibleResultsByModelID[
        item.item.persistentModelID
      ] {
        item.highlight(searchQuery, result.ranges)
      } else {
        clearHighlight(item)
      }
    }
    return PinnedSnapshot(
      allItems: query.allItems,
      visibleItems: visibleResults.map(\.object)
    )
  }

  private func buildStorageQuery(
    pageSize: Int?,
    sortDescriptors: [SortDescriptor<HistoryItem>]
  ) throws -> UnpinnedQuery {
    var offset = 0
    var itemCount = 0
    var imageItemCount = 0
    var summaries: [HistoryPageLayoutSummary] = []
    var layoutIndex = pageSize.flatMap {
      StorageLayoutIndex(pageSize: $0)
    }

    while true {
      var descriptor = FetchDescriptor<HistoryItem>(
        predicate: #Predicate { $0.pin == nil },
        sortBy: sortDescriptors
      )
      descriptor.fetchLimit = Self.storageBatchSize
      descriptor.fetchOffset = offset
      let items = try Storage.shared.context.fetch(descriptor)
      for item in items {
        if layoutIndex != nil {
          layoutIndex?.append(isImage: item.hasImageContent)
        } else {
          appendLayout(
            for: item,
            itemCount: &itemCount,
            imageItemCount: &imageItemCount,
            summaries: &summaries,
            pageSize: pageSize
          )
        }
      }
      offset += items.count
      guard items.count == Self.storageBatchSize else { break }
    }

    if let layoutIndex {
      summaries = layoutIndex.layoutSummaries
    } else {
      appendPartialLayout(
        itemCount: &itemCount,
        imageItemCount: &imageItemCount,
        summaries: &summaries
      )
    }
    return .storage(
      StorageQuery(
        count: offset,
        layoutSummaries: summaries,
        layoutIndex: layoutIndex
      )
    )
  }

  private func queryItems(
    in range: Range<Int>,
    from query: UnpinnedQuery,
    sortDescriptors: [SortDescriptor<HistoryItem>]
  ) throws -> [QueryItem] {
    guard !range.isEmpty else { return [] }

    switch query {
    case .storage:
      var descriptor = FetchDescriptor<HistoryItem>(
        predicate: #Predicate { $0.pin == nil },
        sortBy: sortDescriptors
      )
      descriptor.fetchLimit = range.count
      descriptor.fetchOffset = range.lowerBound
      return try Storage.shared.context.fetch(descriptor)
        .enumerated()
        .map { offset, item in
          QueryItem(
            item: decorator(for: item),
            index: range.lowerBound + offset,
            highlightRanges: nil
          )
        }
    case let .search(results, _):
      return results[range].enumerated().map { offset, result in
        QueryItem(
          item: result.object,
          index: range.lowerBound + offset,
          highlightRanges: result.ranges
        )
      }
    }
  }

  private func present(
    _ queryItem: QueryItem,
    searchQuery: String
  ) -> HistoryItemDecorator {
    if let ranges = queryItem.highlightRanges {
      queryItem.item.highlight(searchQuery, ranges)
    } else {
      clearHighlight(queryItem.item)
    }
    return configure(queryItem.item, at: queryItem.index)
  }

  private func index(
    of modelID: PersistentIdentifier,
    in query: UnpinnedQuery,
    sortDescriptors: [SortDescriptor<HistoryItem>]
  ) throws -> Int? {
    switch query {
    case .storage:
      return try storageIndex(
        of: modelID,
        sortDescriptors: sortDescriptors
      )
    case let .search(results, _):
      return results.firstIndex {
        $0.object.item.persistentModelID == modelID
      }
    }
  }

  private func storageIndex(
    of modelID: PersistentIdentifier,
    sortDescriptors: [SortDescriptor<HistoryItem>]
  ) throws -> Int? {
    var offset = 0
    while true {
      var descriptor = FetchDescriptor<HistoryItem>(
        predicate: #Predicate { $0.pin == nil },
        sortBy: sortDescriptors
      )
      descriptor.fetchLimit = Self.storageBatchSize
      descriptor.fetchOffset = offset
      let items = try Storage.shared.context.fetch(descriptor)
      if let localIndex = items.firstIndex(where: {
        $0.persistentModelID == modelID
      }) {
        return offset + localIndex
      }
      guard items.count == Self.storageBatchSize else { return nil }
      offset += items.count
    }
  }

  private func storageIndices(
    of modelIDs: Set<PersistentIdentifier>,
    sortDescriptors: [SortDescriptor<HistoryItem>]
  ) throws -> [PersistentIdentifier: Int]? {
    guard !modelIDs.isEmpty else { return [:] }

    var remainingModelIDs = modelIDs
    var indices: [PersistentIdentifier: Int] = [:]
    var offset = 0
    while true {
      var descriptor = FetchDescriptor<HistoryItem>(
        predicate: #Predicate { $0.pin == nil },
        sortBy: sortDescriptors
      )
      descriptor.fetchLimit = Self.storageBatchSize
      descriptor.fetchOffset = offset
      let items = try Storage.shared.context.fetch(descriptor)
      for (localIndex, item) in items.enumerated()
      where remainingModelIDs.remove(item.persistentModelID) != nil {
        indices[item.persistentModelID] = offset + localIndex
      }
      guard !remainingModelIDs.isEmpty else { return indices }
      guard items.count == Self.storageBatchSize else { return nil }
      offset += items.count
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
    for items: some Sequence<HistoryItem>,
    pageSize: Int?
  ) -> [HistoryPageLayoutSummary] {
    var itemCount = 0
    var imageItemCount = 0
    var summaries: [HistoryPageLayoutSummary] = []
    for item in items {
      appendLayout(
        for: item,
        itemCount: &itemCount,
        imageItemCount: &imageItemCount,
        summaries: &summaries,
        pageSize: pageSize
      )
    }
    appendPartialLayout(
      itemCount: &itemCount,
      imageItemCount: &imageItemCount,
      summaries: &summaries
    )
    return summaries
  }

  private func appendLayout(
    for item: HistoryItem,
    itemCount: inout Int,
    imageItemCount: inout Int,
    summaries: inout [HistoryPageLayoutSummary],
    pageSize: Int?
  ) {
    itemCount += 1
    if item.hasImageContent {
      imageItemCount += 1
    }
    guard let pageSize, itemCount == pageSize else { return }
    appendPartialLayout(
      itemCount: &itemCount,
      imageItemCount: &imageItemCount,
      summaries: &summaries
    )
  }

  private func appendPartialLayout(
    itemCount: inout Int,
    imageItemCount: inout Int,
    summaries: inout [HistoryPageLayoutSummary]
  ) {
    guard itemCount > 0 else { return }
    summaries.append(HistoryPageLayoutSummary(
      itemCount: itemCount,
      imageItemCount: imageItemCount
    ))
    itemCount = 0
    imageItemCount = 0
  }

  private func clearHighlight(_ item: HistoryItemDecorator) {
    guard item.attributedTitle != nil else { return }
    item.highlight("", [])
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
