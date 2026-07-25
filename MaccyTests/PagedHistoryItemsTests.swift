import XCTest
@testable import Maccy

@MainActor
final class PagedHistoryItemsTests: XCTestCase {
  func testLoadsPackedPagesWithExactGlobalIndicesAndBoundaries() async throws {
    let query = InMemoryHistoryQuery(titles: (0..<8).map(String.init))
    let items = PagedHistoryItems(pageSize: 3, loader: query.load)

    try items.load()
    let item = try await items.item(at: 4)
    let firstPage = items.loadedPage(at: 0)
    let secondPage = items.loadedPage(at: 1)

    XCTAssertEqual(items.count, 8)
    XCTAssertEqual(items.pageCount, 3)
    XCTAssertEqual(firstPage?.startIndex, 0)
    XCTAssertEqual(firstPage?.items.map(\.title), ["0", "1", "2"])
    XCTAssertNil(firstPage?.previousItem)
    XCTAssertEqual(firstPage?.nextItem?.title, "3")
    XCTAssertEqual(item?.item.title, "4")
    XCTAssertEqual(item?.index, 4)
    XCTAssertEqual(secondPage?.startIndex, 3)
    XCTAssertEqual(secondPage?.items.map(\.title), ["3", "4", "5"])
    XCTAssertEqual(secondPage?.previousItem?.title, "2")
    XCTAssertEqual(secondPage?.nextItem?.title, "6")
  }

  func testAppliesFilterBeforeSlicing() async throws {
    let query = InMemoryHistoryQuery(titles: (0..<10).map(String.init))
    query.isIncluded = { Int($0.title)?.isMultiple(of: 2) == true }
    let items = PagedHistoryItems(pageSize: 3, loader: query.load)

    try items.load()
    let secondPage = try items.loadPage(at: 1)

    XCTAssertEqual(items.count, 5)
    XCTAssertEqual(
      items.loadedPage(at: 0)?.items.map(\.title),
      ["0", "2", "4"]
    )
    XCTAssertEqual(items.loadedPage(at: 0)?.nextItem?.title, "6")
    XCTAssertEqual(secondPage?.items.map(\.title), ["6", "8"])
    XCTAssertEqual(secondPage?.previousItem?.title, "4")
    XCTAssertNil(secondPage?.nextItem)
  }

  func testMutationRefreshBackfillsEveryRetainedPage() async throws {
    let query = InMemoryHistoryQuery(titles: (0..<8).map(String.init))
    let items = PagedHistoryItems(pageSize: 3, loader: query.load)
    items.retainPage(at: 0)
    items.retainPage(at: 1)

    try items.load()
    _ = try items.loadPage(at: 1)
    query.remove(title: "1")
    try items.refreshAfterMutation()

    XCTAssertEqual(items.count, 7)
    XCTAssertEqual(
      items.loadedPage(at: 0)?.items.map(\.title),
      ["0", "2", "3"]
    )
    XCTAssertEqual(items.loadedPage(at: 0)?.nextItem?.title, "4")
    XCTAssertEqual(
      items.loadedPage(at: 1)?.items.map(\.title),
      ["4", "5", "6"]
    )
    XCTAssertEqual(items.loadedPage(at: 1)?.previousItem?.title, "3")
    XCTAssertEqual(items.loadedPage(at: 1)?.nextItem?.title, "7")

    query.insert(title: "new", at: 1)
    try items.refreshAfterMutation()

    XCTAssertEqual(items.count, 8)
    XCTAssertEqual(
      items.loadedPage(at: 0)?.items.map(\.title),
      ["0", "new", "2"]
    )
    XCTAssertEqual(items.loadedPage(at: 0)?.nextItem?.title, "3")
    XCTAssertEqual(
      items.loadedPage(at: 1)?.items.map(\.title),
      ["3", "4", "5"]
    )
    XCTAssertEqual(items.loadedPage(at: 1)?.previousItem?.title, "2")
    XCTAssertEqual(items.loadedPage(at: 1)?.nextItem?.title, "6")
  }

  func testFailedMutationRefreshKeepsPublishedSnapshot() async throws {
    enum TestError: Error {
      case failed
    }

    let query = InMemoryHistoryQuery(titles: (0..<6).map(String.init))
    let items = PagedHistoryItems(pageSize: 3, loader: query.load)
    try items.load()

    let page = try XCTUnwrap(items.loadedPage(at: 0))
    let oldRevision = page.contentRevision
    let oldContentRevision = items.contentRevision
    query.error = TestError.failed

    do {
      try items.refreshAfterMutation()
      XCTFail("Expected the refresh to fail")
    } catch TestError.failed {
      // Expected.
    }

    XCTAssertEqual(items.count, 6)
    XCTAssertEqual(page.items.map(\.title), ["0", "1", "2"])
    XCTAssertEqual(page.contentRevision, oldRevision)
    XCTAssertEqual(items.contentRevision, oldContentRevision)
  }

  func testReusesDecoratorsByPersistentModelIdentity() async throws {
    let query = InMemoryHistoryQuery(titles: (0..<4).map(String.init))
    let items = PagedHistoryItems(pageSize: 3, loader: query.load)
    try items.load()

    let firstPage = try XCTUnwrap(items.loadedPage(at: 0))
    let originalDecorator = firstPage.items[1]
    let pageRevision = firstPage.contentRevision
    try items.refreshAfterMutation()

    let refreshedPage = try XCTUnwrap(items.loadedPage(at: 0))
    XCTAssertTrue(firstPage === refreshedPage)
    XCTAssertTrue(originalDecorator === refreshedPage.items[1])
    XCTAssertEqual(refreshedPage.contentRevision, pageRevision)
    XCTAssertEqual(
      items.loadedItem(id: originalDecorator.id)?.index,
      1
    )
  }

  func testLeasesProtectPagesFromCacheEviction() async throws {
    let query = InMemoryHistoryQuery(titles: (0..<12).map(String.init))
    let items = PagedHistoryItems(
      pageSize: 3,
      maximumUnleasedPageCount: 1,
      loader: query.load
    )
    items.retainPage(at: 0)
    try items.load()

    _ = try items.loadPage(at: 1)
    _ = try items.loadPage(at: 2)

    XCTAssertNotNil(items.loadedPage(at: 0))
    XCTAssertNil(items.loadedPage(at: 1))
    XCTAssertNotNil(items.loadedPage(at: 2))

    items.releasePage(at: 0)
    XCTAssertNotNil(items.loadedPage(at: 0))
    XCTAssertNil(items.loadedPage(at: 2))
  }

  func testLoadedItemSurvivesPageEvictionWhileDecoratorIsRetained() throws {
    let query = InMemoryHistoryQuery(titles: (0..<9).map(String.init))
    let items = PagedHistoryItems(
      pageSize: 3,
      maximumUnleasedPageCount: 1,
      loader: query.load
    )
    try items.load()
    items.retainPage(at: 1)
    _ = try items.loadPage(at: 1)
    let retainedDecorator = try XCTUnwrap(
      items.loadedPage(at: 1)?.items[1]
    )

    items.releasePage(at: 1)

    XCTAssertNil(items.loadedPage(at: 1))
    XCTAssertEqual(
      items.loadedItem(id: retainedDecorator.id)?.index,
      4
    )
    XCTAssertTrue(
      items.loadedItem(id: retainedDecorator.id)?.item ===
        retainedDecorator
    )
  }

  func testResidentConfigurationUsesOneCompleteSelectablePage() async throws {
    let query = InMemoryHistoryQuery(titles: (0..<8).map(String.init))
    let items = PagedHistoryItems(
      pageSize: nil,
      supportsBoundaryRangeSelection: true,
      loader: query.load
    )

    try items.load()
    let last = try await items.item(at: 7)

    XCTAssertTrue(items.supportsBoundaryRangeSelection)
    XCTAssertEqual(items.pageCount, 1)
    XCTAssertEqual(items.retainedPageIndices, [0])
    XCTAssertEqual(
      items.loadedPage(at: 0)?.items.map(\.title),
      (0..<8).map(String.init)
    )
    XCTAssertEqual(last?.item.title, "7")
  }

  func testAdoptsDecoratorOwnedByPinnedSection() throws {
    let query = InMemoryHistoryQuery(titles: ["pin", "other"])
    let adoptedDecorator = HistoryItemDecorator(query.item(titled: "pin"))
    let items = PagedHistoryItems(pageSize: 1, loader: query.load)

    items.adopt([adoptedDecorator])
    try items.load()
    let secondPage = try items.loadPage(at: 1)

    XCTAssertTrue(
      items.loadedPage(at: 0)?.items.first === adoptedDecorator
    )
    XCTAssertTrue(
      items.loadedPage(at: 0)?.nextItem ===
        secondPage?.items.first
    )
  }

  func testPublishesExactLayoutSummariesForUnloadedPages() throws {
    let query = InMemoryHistoryQuery(titles: (0..<8).map(String.init))
    query.isAlternate = { ["1", "4", "7"].contains($0.title) }
    let items = PagedHistoryItems(pageSize: 3, loader: query.load)

    try items.load()

    XCTAssertEqual(
      items.pageLayoutSummaries,
      [
        HistoryPageLayoutSummary(itemCount: 3, alternateItemCount: 1),
        HistoryPageLayoutSummary(itemCount: 3, alternateItemCount: 1),
        HistoryPageLayoutSummary(itemCount: 2, alternateItemCount: 1)
      ]
    )
    XCTAssertEqual(
      items.layoutSummary(forPageAt: 2)?
        .height(itemHeight: 10, alternateItemHeight: 20),
      30
    )
    XCTAssertNil(items.loadedPage(at: 2))
  }
}

@MainActor
private final class InMemoryHistoryQuery {
  var isIncluded: (HistoryItem) -> Bool = { _ in true }
  var isAlternate: (HistoryItem) -> Bool = { _ in false }
  var error: Error?

  private var items: [HistoryItem]

  init(titles: [String]) {
    items = titles.map { title in
      let item = HistoryItem()
      item.title = title
      return item
    }
  }

  func insert(title: String, at index: Int) {
    let item = HistoryItem()
    item.title = title
    items.insert(item, at: index)
  }

  func remove(title: String) {
    items.removeAll { $0.title == title }
  }

  func item(titled title: String) -> HistoryItem {
    items.first { $0.title == title }!
  }

  func load(
    _ request: PagedHistoryItems.QueryRequest
  ) throws -> PagedHistoryItems.QuerySnapshot {
    if let error {
      throw error
    }

    // The complete query is filtered before any requested range is sliced.
    let filteredItems = items.filter(isIncluded)
    let slices = request.ranges.map { range in
      let clampedRange = clamp(range, toCount: filteredItems.count)
      return PagedHistoryItems.QuerySlice(
        range: clampedRange,
        items: filteredItems[clampedRange].map {
          HistoryItemDecorator($0)
        }
      )
    }
    let layoutSummaries = request.includesLayoutSummaries
      ? layoutSummaries(
        items: filteredItems,
        pageSize: request.pageSize
      )
      : nil
    return PagedHistoryItems.QuerySnapshot(
      filteredCount: filteredItems.count,
      slices: slices,
      layoutSummaries: layoutSummaries
    )
  }

  private func layoutSummaries(
    items: [HistoryItem],
    pageSize: Int?
  ) -> [HistoryPageLayoutSummary] {
    guard !items.isEmpty else { return [] }
    guard let pageSize else {
      return [
        HistoryPageLayoutSummary(
          itemCount: items.count,
          alternateItemCount: items.lazy.filter(isAlternate).count
        )
      ]
    }

    return stride(from: 0, to: items.count, by: pageSize).map { start in
      let end = min(start + pageSize, items.count)
      let pageItems = items[start..<end]
      return HistoryPageLayoutSummary(
        itemCount: pageItems.count,
        alternateItemCount: pageItems.lazy.filter(isAlternate).count
      )
    }
  }

  private func clamp(
    _ range: Range<Int>,
    toCount count: Int
  ) -> Range<Int> {
    let lowerBound = min(max(0, range.lowerBound), count)
    let upperBound = min(max(lowerBound, range.upperBound), count)
    return lowerBound..<upperBound
  }
}
