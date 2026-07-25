// swiftlint:disable file_length
import Foundation
import Observation
import SwiftData

struct HistoryPageLayoutSummary: Equatable {
  let itemCount: Int
  let alternateItemCount: Int

  init(itemCount: Int, alternateItemCount: Int = 0) {
    precondition(itemCount >= 0)
    precondition(
      alternateItemCount >= 0 && alternateItemCount <= itemCount
    )
    self.itemCount = itemCount
    self.alternateItemCount = alternateItemCount
  }

  func height(
    itemHeight: CGFloat,
    alternateItemHeight: CGFloat
  ) -> CGFloat {
    let regularItemCount = itemCount - alternateItemCount
    return CGFloat(regularItemCount) * itemHeight
      + CGFloat(alternateItemCount) * alternateItemHeight
  }
}

/// A fixed-size slice of unpinned history.
///
/// Page identity is its global page index. The object survives content
/// refreshes so a recycler does not recreate an unchanged hosted chunk.
@Observable
final class PagedHistoryPage: Identifiable {
  struct Content {
    let items: [HistoryItemDecorator]
    let previousItem: HistoryItemDecorator?
    let nextItem: HistoryItemDecorator?
    let layoutSummary: HistoryPageLayoutSummary
    let contentRevision: UInt64
    let layoutRevision: UInt64
  }

  let id: Int
  let startIndex: Int
  private(set) var content: Content

  var items: [HistoryItemDecorator] { content.items }
  var previousItem: HistoryItemDecorator? { content.previousItem }
  var nextItem: HistoryItemDecorator? { content.nextItem }
  var layoutSummary: HistoryPageLayoutSummary {
    content.layoutSummary
  }
  var contentRevision: UInt64 { content.contentRevision }
  var layoutRevision: UInt64 { content.layoutRevision }
  var range: Range<Int> { startIndex..<(startIndex + items.count) }

  init(
    pageIndex: Int,
    startIndex: Int,
    items: [HistoryItemDecorator],
    previousItem: HistoryItemDecorator?,
    nextItem: HistoryItemDecorator?,
    layoutSummary: HistoryPageLayoutSummary
  ) {
    id = pageIndex
    self.startIndex = startIndex
    content = Content(
      items: items,
      previousItem: previousItem,
      nextItem: nextItem,
      layoutSummary: layoutSummary,
      contentRevision: 1,
      layoutRevision: 1
    )
  }

  fileprivate func replace(
    with stagedPage: PagedHistoryItems.StagedPage,
    forceContentRevision: Bool
  ) -> (contentChanged: Bool, layoutChanged: Bool) {
    let layoutChanged = content.layoutSummary != stagedPage.layoutSummary
    let contentChanged = forceContentRevision
      || !Self.haveSameObjects(content.items, stagedPage.items)
      || content.previousItem !== stagedPage.previousItem
      || content.nextItem !== stagedPage.nextItem
    guard contentChanged || layoutChanged else {
      return (false, false)
    }

    content = Content(
      items: stagedPage.items,
      previousItem: stagedPage.previousItem,
      nextItem: stagedPage.nextItem,
      layoutSummary: stagedPage.layoutSummary,
      contentRevision: contentChanged
        ? content.contentRevision &+ 1
        : content.contentRevision,
      layoutRevision: layoutChanged
        ? content.layoutRevision &+ 1
        : content.layoutRevision
    )
    return (contentChanged, layoutChanged)
  }

  private static func haveSameObjects(
    _ lhs: [HistoryItemDecorator],
    _ rhs: [HistoryItemDecorator]
  ) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { $0 === $1 }
  }
}

/// A packed view of the active unpinned-history query.
///
/// Passing `pageSize: nil` creates one resident page. Selection capabilities
/// are configured independently, because they describe product policy rather
/// than the current storage representation.
@Observable
final class PagedHistoryItems: UnpinnedHistoryItems {
  struct QueryRequest {
    let ranges: [Range<Int>]
    let includesLayoutSummaries: Bool
    let pageSize: Int?
  }

  struct QuerySlice {
    let range: Range<Int>
    let items: [HistoryItemDecorator]
  }

  /// One atomic result from the active sorted and filtered query.
  ///
  /// The loader must filter before slicing. `slices` correspond one-for-one
  /// with the request ranges and use those ranges clamped to
  /// `0..<filteredCount`. Full loads and mutation refreshes also request exact
  /// layout summaries for every page, including pages whose items are not
  /// retained.
  struct QuerySnapshot {
    let filteredCount: Int
    let slices: [QuerySlice]
    let layoutSummaries: [HistoryPageLayoutSummary]?

    init(
      filteredCount: Int,
      slices: [QuerySlice],
      layoutSummaries: [HistoryPageLayoutSummary]? = nil
    ) {
      self.filteredCount = filteredCount
      self.slices = slices
      self.layoutSummaries = layoutSummaries
    }
  }

  typealias QueryLoader = @MainActor (
    _ request: QueryRequest
  ) throws -> QuerySnapshot

  enum LoadingError: LocalizedError {
    case invalidSnapshot(String)

    var errorDescription: String? {
      switch self {
      case let .invalidSnapshot(message):
        return "Invalid paged history snapshot: \(message)"
      }
    }
  }

  /// `nil` means the query is kept in one resident page.
  let pageSize: Int?
  let supportsBoundaryRangeSelection: Bool

  private(set) var count = 0
  private(set) var pages: [Int: PagedHistoryPage] = [:]
  private(set) var pageLayoutSummaries: [HistoryPageLayoutSummary] = []
  private(set) var hasLoaded = false
  private(set) var layoutRevision: UInt64 = 0
  private(set) var contentRevision: UInt64 = 0
  private(set) var reloadRevision: UInt64 = 0

  var pageCount: Int {
    guard count > 0 else { return 0 }
    guard let pageSize else { return 1 }
    return (count - 1) / pageSize + 1
  }

  var retainedPages: [PagedHistoryPage] {
    pages.values.sorted { $0.id < $1.id }
  }

  var retainedPageIndices: [Int] {
    pages.keys.sorted()
  }

  var loadedItems: [IndexedHistoryItem] {
    retainedPages.flatMap { page in
      page.items.enumerated().map {
        IndexedHistoryItem(
          item: $0.element,
          index: page.startIndex + $0.offset
        )
      }
    }
  }

  /// Items currently retained by the source, in global query order.
  var items: [HistoryItemDecorator] {
    loadedItems.sorted { $0.index < $1.index }.map(\.item)
  }

  private let maximumUnleasedPageCount: Int
  private let loader: QueryLoader

  @ObservationIgnored
  private var pageLeaseCounts: [Int: Int] = [:]

  @ObservationIgnored
  private var accessCounter: UInt64 = 0

  @ObservationIgnored
  private var lastAccess: [Int: UInt64] = [:]

  @ObservationIgnored
  private var decoratorCache: [
    PersistentIdentifier: WeakHistoryItemDecorator
  ] = [:]

  @ObservationIgnored
  private var knownItemsByID: [UUID: WeakIndexedHistoryItem] = [:]

  init(
    pageSize: Int? = 20,
    supportsBoundaryRangeSelection: Bool = false,
    maximumUnleasedPageCount: Int = 3,
    loader: @escaping QueryLoader
  ) {
    if let pageSize {
      precondition(
        pageSize > 0 && pageSize < Int.max,
        "Paged history page size must be positive and finite"
      )
    }
    precondition(
      maximumUnleasedPageCount > 0,
      "Paged history cache must retain at least its first page"
    )
    self.pageSize = pageSize
    self.supportsBoundaryRangeSelection = supportsBoundaryRangeSelection
    self.maximumUnleasedPageCount = maximumUnleasedPageCount
    self.loader = loader
  }

  /// Seeds canonical identity with decorators owned outside the page cache.
  ///
  /// This is needed when a pin is unpinned: its existing decorator may be
  /// selected, so the first storage fetch must adopt that object instead of
  /// creating a second wrapper for the same model.
  @MainActor
  func adopt(_ decorators: some Sequence<HistoryItemDecorator>) {
    for decorator in decorators {
      decoratorCache[decorator.item.persistentModelID] =
        WeakHistoryItemDecorator(decorator)
    }
    pruneDecoratorCache()
  }

  /// Records the current query location of an externally owned decorator.
  ///
  /// Pin mutations use this after an item moves into an unloaded page so
  /// navigation can still target it without retaining every preceding item.
  @MainActor
  func remember(_ decorator: HistoryItemDecorator, at index: Int) {
    adopt([decorator])
    register(decorator, at: index)
  }

  /// Loads the active query while preserving hosted page identities.
  @MainActor
  func load() throws {
    try reload()
  }

  @MainActor
  func reload() throws {
    let pageIndices = Set(pages.keys).union([0])
    try replaceQuery(
      retaining: pageIndices,
      forceContentRevisions: hasLoaded
    )
  }

  /// Atomically re-fetches, packs, and publishes every retained page.
  ///
  /// This synchronous operation is suitable for the app's synchronous
  /// MainActor mutation methods: pinning, unpinning, deleting, and inserting
  /// return with all hosted pages already backfilled.
  @MainActor
  func refreshAfterMutation() throws {
    let pageIndices = Set(pages.keys).union([0])
    try refreshRetainedPages(including: pageIndices)
  }

  @MainActor
  func item(at index: Int) async throws -> IndexedHistoryItem? {
    guard index >= 0 else { return nil }
    if !hasLoaded {
      try replaceQuery(
        retaining: [pageIndex(containing: index)],
        forceContentRevisions: false
      )
    }
    guard index < count,
      let page = try loadPage(at: pageIndex(containing: index))
    else {
      return nil
    }

    let localIndex = index - page.startIndex
    guard page.items.indices.contains(localIndex) else {
      throw LoadingError.invalidSnapshot(
        "page \(page.id) does not contain global index \(index)"
      )
    }
    return IndexedHistoryItem(item: page.items[localIndex], index: index)
  }

  func loadedItem(id: UUID) -> IndexedHistoryItem? {
    if let knownItem = knownItemsByID[id],
      let item = knownItem.value {
      return IndexedHistoryItem(item: item, index: knownItem.index)
    }

    for page in retainedPages {
      if let localIndex = page.items.firstIndex(where: { $0.id == id }) {
        return IndexedHistoryItem(
          item: page.items[localIndex],
          index: page.startIndex + localIndex
        )
      }
    }
    return nil
  }

  @MainActor
  func loadPage(at pageIndex: Int) throws -> PagedHistoryPage? {
    guard isRepresentable(pageIndex: pageIndex) else { return nil }
    if let page = pages[pageIndex] {
      touch(pageIndex)
      return page
    }
    if !hasLoaded {
      try replaceQuery(
        retaining: [pageIndex],
        forceContentRevisions: false
      )
      return pages[pageIndex]
    }
    guard pageIndex < pageCount else { return nil }

    let request = QueryRequest(
      ranges: [requestedRange(forPageAt: pageIndex)],
      includesLayoutSummaries: false,
      pageSize: pageSize
    )
    let snapshot = try loader(request)
    if snapshot.filteredCount != count {
      try refreshRetainedPages(
        including: Set(pages.keys).union([pageIndex])
      )
      return pages[pageIndex]
    }

    let stagedPages = try stagePages(
      from: snapshot,
      pageIndices: [pageIndex],
      layoutSummaries: pageLayoutSummaries
    )
    publish(
      stagedPages,
      with: Publication(
        totalCount: snapshot.filteredCount,
        layoutSummaries: pageLayoutSummaries,
        replacingAllPages: false,
        forceContentRevisions: false,
        isReload: false
      )
    )
    touch(pageIndex)
    pruneCache()
    return pages[pageIndex]
  }

  func loadedPage(at pageIndex: Int) -> PagedHistoryPage? {
    pages[pageIndex]
  }

  func layoutSummary(
    forPageAt pageIndex: Int
  ) -> HistoryPageLayoutSummary? {
    guard pageLayoutSummaries.indices.contains(pageIndex) else { return nil }
    return pageLayoutSummaries[pageIndex]
  }

  /// Protects a hosted page from cache eviction. A lease may be acquired
  /// before the page is loaded.
  @MainActor
  func retainPage(at pageIndex: Int) {
    guard pageIndex >= 0 else { return }
    pageLeaseCounts[pageIndex, default: 0] += 1
    touch(pageIndex)
  }

  @MainActor
  func releasePage(at pageIndex: Int) {
    guard let leaseCount = pageLeaseCounts[pageIndex] else { return }
    if leaseCount > 1 {
      pageLeaseCounts[pageIndex] = leaseCount - 1
    } else {
      pageLeaseCounts.removeValue(forKey: pageIndex)
    }
    pruneCache()
  }
}

private extension PagedHistoryItems {
  struct StagedPage {
    let startIndex: Int
    let items: [HistoryItemDecorator]
    let previousItem: HistoryItemDecorator?
    let nextItem: HistoryItemDecorator?
    let layoutSummary: HistoryPageLayoutSummary
  }

  struct Publication {
    let totalCount: Int
    let layoutSummaries: [HistoryPageLayoutSummary]
    let replacingAllPages: Bool
    let forceContentRevisions: Bool
    let isReload: Bool
  }

  @MainActor
  func replaceQuery(
    retaining pageIndices: Set<Int>,
    forceContentRevisions: Bool
  ) throws {
    let indices = normalizedPageIndices(pageIndices)
    let request = QueryRequest(
      ranges: indices.map(requestedRange),
      includesLayoutSummaries: true,
      pageSize: pageSize
    )
    let snapshot = try loader(request)
    let layoutSummaries = try validatedLayoutSummaries(from: snapshot)
    let stagedPages = try stagePages(
      from: snapshot,
      pageIndices: indices,
      layoutSummaries: layoutSummaries
    )
    publish(
      stagedPages,
      with: Publication(
        totalCount: snapshot.filteredCount,
        layoutSummaries: layoutSummaries,
        replacingAllPages: true,
        forceContentRevisions: forceContentRevisions,
        isReload: true
      )
    )
    hasLoaded = true
    pruneCache()
  }

  @MainActor
  func refreshRetainedPages(
    including pageIndices: Set<Int>
  ) throws {
    let indices = normalizedPageIndices(pageIndices)
    let request = QueryRequest(
      ranges: indices.map(requestedRange),
      includesLayoutSummaries: true,
      pageSize: pageSize
    )
    let snapshot = try loader(request)
    let layoutSummaries = try validatedLayoutSummaries(from: snapshot)
    let stagedPages = try stagePages(
      from: snapshot,
      pageIndices: indices,
      layoutSummaries: layoutSummaries
    )
    publish(
      stagedPages,
      with: Publication(
        totalCount: snapshot.filteredCount,
        layoutSummaries: layoutSummaries,
        replacingAllPages: true,
        forceContentRevisions: false,
        isReload: false
      )
    )
    hasLoaded = true
    pruneCache()
  }

  func stagePages(
    from snapshot: QuerySnapshot,
    pageIndices: [Int],
    layoutSummaries: [HistoryPageLayoutSummary]
  ) throws -> [Int: StagedPage] {
    guard snapshot.filteredCount >= 0 else {
      throw LoadingError.invalidSnapshot("the filtered count is negative")
    }
    guard snapshot.slices.count == pageIndices.count else {
      throw LoadingError.invalidSnapshot(
        "expected \(pageIndices.count) slices, got \(snapshot.slices.count)"
      )
    }

    for (pageIndex, slice) in zip(pageIndices, snapshot.slices) {
      try validate(
        slice,
        forPageAt: pageIndex,
        filteredCount: snapshot.filteredCount
      )
    }

    var stagedPages: [Int: StagedPage] = [:]
    for (pageIndex, slice) in zip(pageIndices, snapshot.slices) {
      guard let pageRange = pageRange(
        at: pageIndex,
        totalCount: snapshot.filteredCount
      ) else {
        continue
      }

      let canonicalItems = slice.items.map(canonicalDecorator)
      let firstLocalIndex = pageRange.lowerBound - slice.range.lowerBound
      let lastLocalIndex = pageRange.upperBound - slice.range.lowerBound
      guard firstLocalIndex >= 0,
        lastLocalIndex <= canonicalItems.count
      else {
        throw LoadingError.invalidSnapshot(
          "page \(pageIndex) does not contain its complete packed range"
        )
      }

      stagedPages[pageIndex] = StagedPage(
        startIndex: pageRange.lowerBound,
        items: Array(canonicalItems[firstLocalIndex..<lastLocalIndex]),
        previousItem: pageRange.lowerBound > 0
          ? canonicalItems[firstLocalIndex - 1]
          : nil,
        nextItem: pageRange.upperBound < snapshot.filteredCount
          ? canonicalItems[lastLocalIndex]
          : nil,
        layoutSummary: layoutSummaries[pageIndex]
      )
    }
    pruneDecoratorCache()
    return stagedPages
  }

  func validate(
    _ slice: QuerySlice,
    forPageAt pageIndex: Int,
    filteredCount: Int
  ) throws {
    let expectedRange = Self.clamp(
      requestedRange(forPageAt: pageIndex),
      toCount: filteredCount
    )
    guard slice.range == expectedRange else {
      throw LoadingError.invalidSnapshot(
        "page \(pageIndex) returned \(slice.range), expected \(expectedRange)"
      )
    }
    guard slice.items.count == slice.range.count else {
      throw LoadingError.invalidSnapshot(
        """
        page \(pageIndex) returned \(slice.items.count) items for \
        \(slice.range.count) indices
        """
      )
    }
  }

  func validatedLayoutSummaries(
    from snapshot: QuerySnapshot
  ) throws -> [HistoryPageLayoutSummary] {
    guard snapshot.filteredCount >= 0 else {
      throw LoadingError.invalidSnapshot("the filtered count is negative")
    }
    guard let summaries = snapshot.layoutSummaries else {
      throw LoadingError.invalidSnapshot("layout summaries are missing")
    }

    let expectedPageCount = pageCount(for: snapshot.filteredCount)
    guard summaries.count == expectedPageCount else {
      throw LoadingError.invalidSnapshot(
        "expected \(expectedPageCount) layout summaries, got \(summaries.count)"
      )
    }
    for (pageIndex, summary) in summaries.enumerated() {
      let expectedItemCount = pageRange(
        at: pageIndex,
        totalCount: snapshot.filteredCount
      )?.count ?? 0
      guard summary.itemCount == expectedItemCount else {
        throw LoadingError.invalidSnapshot(
          """
          layout for page \(pageIndex) describes \(summary.itemCount) items, \
          expected \(expectedItemCount)
          """
        )
      }
    }
    return summaries
  }

  func canonicalDecorator(
    _ candidate: HistoryItemDecorator
  ) -> HistoryItemDecorator {
    let modelID = candidate.item.persistentModelID
    if let cached = decoratorCache[modelID]?.value {
      if cached !== candidate,
         cached.attributedTitle != candidate.attributedTitle {
        cached.attributedTitle = candidate.attributedTitle
      }
      return cached
    }
    decoratorCache[modelID] = WeakHistoryItemDecorator(candidate)
    return candidate
  }
}

private extension PagedHistoryItems {
  func publish(
    _ stagedPages: [Int: StagedPage],
    with publication: Publication
  ) {
    let oldCount = count
    let oldLayoutSummaries = pageLayoutSummaries
    var nextPages = publication.replacingAllPages ? [:] : pages
    var contentChanged = false
    for (pageIndex, stagedPage) in stagedPages {
      if let existingPage = pages[pageIndex] {
        let changes = existingPage.replace(
          with: stagedPage,
          forceContentRevision: publication.forceContentRevisions
        )
        contentChanged = contentChanged || changes.contentChanged
        nextPages[pageIndex] = existingPage
      } else {
        nextPages[pageIndex] = PagedHistoryPage(
          pageIndex: pageIndex,
          startIndex: stagedPage.startIndex,
          items: stagedPage.items,
          previousItem: stagedPage.previousItem,
          nextItem: stagedPage.nextItem,
          layoutSummary: stagedPage.layoutSummary
        )
        contentChanged = true
      }
    }

    if publication.replacingAllPages,
      Set(nextPages.keys) != Set(pages.keys) {
      contentChanged = true
    }

    count = publication.totalCount
    pages = nextPages
    pageLayoutSummaries = publication.layoutSummaries
    registerKnownItems(
      in: stagedPages,
      replacingExistingLocations: publication.replacingAllPages
    )

    let layoutChanged = oldCount != publication.totalCount
      || oldLayoutSummaries != publication.layoutSummaries
    if layoutChanged {
      layoutRevision &+= 1
    }
    if contentChanged || layoutChanged || publication.isReload {
      contentRevision &+= 1
    }
    if publication.isReload {
      reloadRevision &+= 1
    }
  }

  func registerKnownItems(
    in stagedPages: [Int: StagedPage],
    replacingExistingLocations: Bool
  ) {
    if replacingExistingLocations {
      knownItemsByID.removeAll(keepingCapacity: true)
    } else {
      knownItemsByID = knownItemsByID.filter { $0.value.value != nil }
    }

    for stagedPage in stagedPages.values {
      if let previousItem = stagedPage.previousItem {
        register(previousItem, at: stagedPage.startIndex - 1)
      }
      for (offset, item) in stagedPage.items.enumerated() {
        register(item, at: stagedPage.startIndex + offset)
      }
      if let nextItem = stagedPage.nextItem {
        register(
          nextItem,
          at: stagedPage.startIndex + stagedPage.items.count
        )
      }
    }
  }

  func register(_ item: HistoryItemDecorator, at index: Int) {
    knownItemsByID[item.id] = WeakIndexedHistoryItem(item, index: index)
  }

  func pageIndex(containing itemIndex: Int) -> Int {
    guard let pageSize else { return 0 }
    return itemIndex / pageSize
  }

  func pageCount(for totalCount: Int) -> Int {
    guard totalCount > 0 else { return 0 }
    guard let pageSize else { return 1 }
    return (totalCount - 1) / pageSize + 1
  }

  func pageRange(
    at pageIndex: Int,
    totalCount: Int
  ) -> Range<Int>? {
    guard pageIndex >= 0, totalCount > 0 else { return nil }
    guard let pageSize else {
      return pageIndex == 0 ? 0..<totalCount : nil
    }

    guard isRepresentable(pageIndex: pageIndex) else { return nil }
    let startIndex = pageIndex * pageSize
    guard startIndex < totalCount else { return nil }
    let itemCount = min(pageSize, totalCount - startIndex)
    return startIndex..<(startIndex + itemCount)
  }

  func normalizedPageIndices(_ indices: Set<Int>) -> [Int] {
    guard pageSize != nil else { return [0] }
    let nonnegativeIndices = indices.filter { $0 >= 0 }
    return nonnegativeIndices.isEmpty
      ? [0]
      : nonnegativeIndices.sorted()
  }

  func requestedRange(forPageAt pageIndex: Int) -> Range<Int> {
    guard let pageSize else { return 0..<Int.max }
    let startIndex = pageIndex * pageSize
    let lowerBound = max(0, startIndex - 1)
    let (candidateUpperBound, overflow) =
      startIndex.addingReportingOverflow(pageSize + 1)
    let upperBound = overflow ? Int.max : candidateUpperBound
    return lowerBound..<upperBound
  }

  func isRepresentable(pageIndex: Int) -> Bool {
    guard pageIndex >= 0 else { return false }
    guard let pageSize else { return pageIndex == 0 }
    return pageIndex <= Int.max / pageSize
  }

  @MainActor
  func touch(_ pageIndex: Int) {
    accessCounter &+= 1
    lastAccess[pageIndex] = accessCounter
  }

  @MainActor
  func pruneCache() {
    guard pageSize != nil else { return }

    let leasedPageIndices = Set(
      pageLeaseCounts.compactMap { pageIndex, leaseCount in
        leaseCount > 0 ? pageIndex : nil
      }
    )
    let unleasedPageIndices = pages.keys
      .filter { !leasedPageIndices.contains($0) }
      .sorted {
        if $0 == 0 { return true }
        if $1 == 0 { return false }
        return lastAccess[$0, default: 0] > lastAccess[$1, default: 0]
      }
    let keptUnleasedPageIndices = Set(
      unleasedPageIndices.prefix(maximumUnleasedPageCount)
    )
    let keptPageIndices = leasedPageIndices.union(keptUnleasedPageIndices)
    let evictedPageIndices = Set(pages.keys).subtracting(keptPageIndices)
    guard !evictedPageIndices.isEmpty else { return }

    pages = pages.filter { keptPageIndices.contains($0.key) }
    lastAccess = lastAccess.filter { keptPageIndices.contains($0.key) }
    contentRevision &+= 1
  }

  func pruneDecoratorCache() {
    guard decoratorCache.count > 2 * max(pageSize ?? count, 20) else {
      return
    }
    decoratorCache = decoratorCache.filter { $0.value.value != nil }
  }

  static func clamp(
    _ range: Range<Int>,
    toCount count: Int
  ) -> Range<Int> {
    let lowerBound = min(max(0, range.lowerBound), count)
    let upperBound = min(max(lowerBound, range.upperBound), count)
    return lowerBound..<upperBound
  }
}

private final class WeakHistoryItemDecorator {
  weak var value: HistoryItemDecorator?

  init(_ value: HistoryItemDecorator) {
    self.value = value
  }
}

private final class WeakIndexedHistoryItem {
  weak var value: HistoryItemDecorator?
  let index: Int

  init(_ value: HistoryItemDecorator, index: Int) {
    self.value = value
    self.index = index
  }
}
