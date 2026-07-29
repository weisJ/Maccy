import AppKit.NSEvent
import Sauce
import SwiftData
import XCTest
@testable import Maccy

@MainActor
final class HistoryItemsTests: XCTestCase {
  func testTraversesSectionBoundaries() async throws {
    let pin = decorator("pin")
    let first = decorator("first")
    let second = decorator("second")
    let unpinnedItems = ResidentHistoryItems()
    unpinnedItems.replace(with: [first, second])
    var pinTo = PinsPosition.top
    let items = historyItems(
      pins: { [pin] in [pin] },
      unpinned: unpinnedItems,
      pinTo: { pinTo }
    )

    let firstAtTop = try await items.first()
    let itemAfterPin = try await items.item(
      after: HistoryItemLocation(section: .pinned, index: 0)
    )
    let itemBeforeFirst = try await items.item(
      before: HistoryItemLocation(section: .unpinned, index: 0)
    )
    XCTAssertEqual(firstAtTop?.item, pin)
    XCTAssertEqual(itemAfterPin?.item, first)
    XCTAssertEqual(itemBeforeFirst?.item, pin)

    pinTo = .bottom

    let firstAtBottom = try await items.first()
    let lastAtBottom = try await items.last()
    let itemBeforePin = try await items.item(
      before: HistoryItemLocation(section: .pinned, index: 0)
    )
    let itemAfterSecond = try await items.item(
      after: HistoryItemLocation(section: .unpinned, index: 1)
    )
    XCTAssertEqual(firstAtBottom?.item, first)
    XCTAssertEqual(lastAtBottom?.item, pin)
    XCTAssertEqual(itemBeforePin?.item, second)
    XCTAssertEqual(itemAfterSecond?.item, pin)
  }

  func testEmptySectionsUseTheRemainingSection() async throws {
    let pin = decorator("pin")
    let unpinned = decorator("unpinned")
    let emptyUnpinnedItems = ResidentHistoryItems()
    let pinsOnly = historyItems(
      pins: { [pin] in [pin] },
      unpinned: emptyUnpinnedItems
    )

    let firstPin = try await pinsOnly.first()
    let lastPin = try await pinsOnly.last()
    XCTAssertEqual(firstPin?.item, pin)
    XCTAssertEqual(lastPin?.item, pin)

    let unpinnedItems = ResidentHistoryItems()
    unpinnedItems.replace(with: [unpinned])
    let unpinnedOnly = historyItems(
      pins: { [] },
      unpinned: unpinnedItems
    )

    let firstUnpinned = try await unpinnedOnly.first()
    let lastUnpinned = try await unpinnedOnly.last()
    XCTAssertEqual(firstUnpinned?.item, unpinned)
    XCTAssertEqual(lastUnpinned?.item, unpinned)
  }

  func testDisplayIndicesAndFirstLocationFollowPinPosition() async throws {
    let pin = decorator("pin")
    let first = decorator("first")
    let second = decorator("second")
    let unpinnedItems = ResidentHistoryItems()
    unpinnedItems.replace(with: [first, second])
    var pinTo = PinsPosition.top
    let items = historyItems(
      pins: { [pin] in [pin] },
      unpinned: unpinnedItems,
      pinTo: { pinTo }
    )

    let topFirst = try await items.item(atDisplayIndex: 0)?.item
    let topSecond = try await items.item(atDisplayIndex: 1)?.item
    let topThird = try await items.item(atDisplayIndex: 2)?.item
    let topItems = [topFirst, topSecond, topThird]
    XCTAssertEqual(topItems, [pin, first, second].map(Optional.some))
    XCTAssertTrue(items.isFirst(
      HistoryItemLocation(section: .pinned, index: 0)
    ))

    pinTo = .bottom

    let bottomFirst = try await items.item(atDisplayIndex: 0)?.item
    let bottomSecond = try await items.item(atDisplayIndex: 1)?.item
    let bottomThird = try await items.item(atDisplayIndex: 2)?.item
    let bottomItems = [bottomFirst, bottomSecond, bottomThird]
    XCTAssertEqual(bottomItems, [first, second, pin].map(Optional.some))
    XCTAssertTrue(items.isFirst(
      HistoryItemLocation(section: .unpinned, index: 0)
    ))
  }

  func testRangeCrossesSectionBoundaryInEitherDirection() async throws {
    let pin = decorator("pin")
    let first = decorator("first")
    let second = decorator("second")
    let unpinnedItems = ResidentHistoryItems()
    unpinnedItems.replace(with: [first, second])
    let items = historyItems(
      pins: { [pin] in [pin] },
      unpinned: unpinnedItems
    )
    let pinLocation = HistoryItemLocation(section: .pinned, index: 0)
    let secondLocation = HistoryItemLocation(section: .unpinned, index: 1)

    let forward = try await items.range(
      from: pinLocation,
      through: secondLocation
    )
    let reverse = try await items.range(
      from: secondLocation,
      through: pinLocation
    )

    XCTAssertEqual(forward.map(\.item), [pin, first, second])
    XCTAssertEqual(reverse.map(\.item), [second, first, pin])
  }

  func testFindsNearestMatchingItemAcrossSections() async throws {
    let pin = decorator("pin")
    let decorators = (0..<5).map { decorator(String($0)) }
    let unpinnedItems = ResidentHistoryItems()
    unpinnedItems.replace(with: decorators)
    let items = historyItems(
      pins: { [pin] in [pin] },
      unpinned: unpinnedItems
    )
    let middle = HistoryItemLocation(section: .unpinned, index: 2)

    let following = try await items.nearest(to: middle) {
      $0 == decorators[4]
    }
    XCTAssertEqual(following?.item, decorators[4])

    let equidistant = try await items.nearest(to: middle) {
      $0 == decorators[1] || $0 == decorators[3]
    }
    XCTAssertEqual(equidistant?.item, decorators[1])

    let acrossBoundary = try await items.nearest(
      to: HistoryItemLocation(section: .unpinned, index: 0)
    ) {
      $0 == pin
    }
    XCTAssertEqual(acrossBoundary?.item, pin)
  }

  func testRejectsInvalidLocations() async throws {
    let pin = decorator("pin")
    let unpinned = decorator("unpinned")
    let unpinnedItems = ResidentHistoryItems()
    unpinnedItems.replace(with: [unpinned])
    let items = historyItems(
      pins: { [pin] in [pin] },
      unpinned: unpinnedItems
    )

    let afterInvalidPin = try await items.item(
      after: HistoryItemLocation(section: .pinned, index: -1)
    )
    let beforeInvalidUnpinned = try await items.item(
      before: HistoryItemLocation(section: .unpinned, index: 1)
    )

    XCTAssertNil(afterInvalidPin)
    XCTAssertNil(beforeInvalidUnpinned)
  }

  func testLoadedItemRebindsAfterSectionAndIndexChanges() {
    let lead = decorator("lead")
    let inserted = decorator("inserted")
    var pins: [HistoryItemDecorator] = []
    let unpinnedItems = ResidentHistoryItems()
    unpinnedItems.replace(with: [lead])
    let items = historyItems(
      pins: { pins },
      unpinned: unpinnedItems
    )

    unpinnedItems.replace(with: [inserted, lead])
    XCTAssertEqual(
      items.loadedItem(id: lead.id)?.location,
      HistoryItemLocation(section: .unpinned, index: 1)
    )

    unpinnedItems.replace(with: [inserted])
    pins = [lead]
    XCTAssertEqual(
      items.loadedItem(id: lead.id)?.location,
      HistoryItemLocation(section: .pinned, index: 0)
    )
  }

  func testRejectsRelativeNavigationFromAStaleRevision() async throws {
    let first = decorator("first")
    let second = decorator("second")
    let unpinnedItems = ResidentHistoryItems()
    unpinnedItems.replace(with: [first, second])
    var revision: UInt64 = 0
    let items = historyItems(
      pins: { [] },
      unpinned: unpinnedItems,
      revision: { revision }
    )
    let firstItem = try await items.first()
    let secondItem = try await items.last()
    let locatedFirst = try XCTUnwrap(firstItem)
    let locatedSecond = try XCTUnwrap(secondItem)

    revision += 1

    await assertStaleLocation {
      _ = try await items.item(after: locatedFirst)
    }
    await assertStaleLocation {
      _ = try await items.item(before: locatedSecond)
    }
    await assertStaleLocation {
      _ = try await items.nearest(to: locatedFirst) { _ in true }
    }
    await assertStaleLocation {
      _ = try await items.range(
        from: locatedFirst,
        through: locatedSecond
      )
    }
  }

  private func historyItems(
    pins: @escaping () -> [HistoryItemDecorator],
    unpinned: ResidentHistoryItems,
    pinTo: @escaping () -> PinsPosition = { .top },
    revision: @escaping () -> UInt64 = { 0 }
  ) -> HistoryItems {
    HistoryItems(
      pinnedItems: pins,
      unpinnedItems: { unpinned },
      pinsPosition: pinTo,
      revision: revision
    )
  }

  private func decorator(_ title: String) -> HistoryItemDecorator {
    let item = HistoryItem()
    item.title = title
    return HistoryItemDecorator(item)
  }

  private func assertStaleLocation(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail(
        "Expected stale relative navigation to fail",
        file: file,
        line: line
      )
    } catch HistoryItemsError.staleLocation {
      // Expected.
    } catch {
      XCTFail(
        "Expected a stale-location error, got \(error)",
        file: file,
        line: line
      )
    }
  }
}

extension HistoryItemsTests {
  func testBoundaryShortcutClassification() {
    guard case .moveToFirst = KeyChord(.upArrow, [.command]) else {
      return XCTFail("Command-Up must move to the first item")
    }
    guard case .moveToLast = KeyChord(.downArrow, [.command]) else {
      return XCTFail("Command-Down must move to the last item")
    }
    guard case .moveToFirst = KeyChord(.pageUp, []) else {
      return XCTFail("Page Up must move to the first item")
    }
    guard case .moveToLast = KeyChord(.pageDown, []) else {
      return XCTFail("Page Down must move to the last item")
    }
    guard case .extendToFirst = KeyChord(
      .upArrow,
      [.command, .shift]
    ) else {
      return XCTFail("Shift-Command-Up must remain a range action")
    }
    guard case .extendToLast = KeyChord(
      .downArrow,
      [.command, .shift]
    ) else {
      return XCTFail("Shift-Command-Down must remain a range action")
    }
  }

  func testPagedSourceSupportsEndpointNavigationWithoutRanges() async throws {
    let decorators = (0..<5).map { decorator(String($0)) }
    let pageSize = 2
    let unpinnedItems = PagedHistoryItems(pageSize: pageSize) { request in
      let slices = request.ranges.map { requestedRange in
        let range = requestedRange.clamped(to: 0..<decorators.count)
        return PagedHistoryItems.QuerySlice(
          range: range,
          items: Array(decorators[range])
        )
      }
      let summaries: [HistoryPageLayoutSummary]? =
        request.includesLayoutSummaries
          ? stride(from: 0, to: decorators.count, by: pageSize).map {
            HistoryPageLayoutSummary(
              itemCount: min($0 + pageSize, decorators.count) - $0
            )
          }
          : nil
      return PagedHistoryItems.QuerySnapshot(
        filteredCount: decorators.count,
        slices: slices,
        layoutSummaries: summaries
      )
    }
    let items = HistoryItems(
      pinnedItems: { [] },
      unpinnedItems: { unpinnedItems },
      pinsPosition: { .top }
    )

    XCTAssertFalse(items.allowsSelectionExtensionToBoundary)
    let lastItem = try await items.last()
    let firstItem = try await items.first()
    let first = try XCTUnwrap(firstItem)
    let last = try XCTUnwrap(lastItem)
    let range = try await items.range(from: first, through: last)

    XCTAssertEqual(first.item, decorators[0])
    XCTAssertEqual(last.item, decorators[4])
    XCTAssertTrue(range.isEmpty)
  }

  func testScrollRequestRejectsPinnedTargets() throws {
    let item = decorator("item")
    let unpinned = LocatedHistoryItem(
      item: item,
      location: HistoryItemLocation(section: .unpinned, index: 0),
      revision: 0
    )
    let pinned = LocatedHistoryItem(
      item: item,
      location: HistoryItemLocation(section: .pinned, index: 0),
      revision: 0
    )

    let request = try XCTUnwrap(HistoryScrollRequest(item: unpinned))

    XCTAssertEqual(request.modelID, item.item.persistentModelID)
    XCTAssertNil(HistoryScrollRequest(item: pinned))
  }
}

@MainActor
private final class ResidentHistoryItems: UnpinnedHistoryItems {
  private(set) var items: [HistoryItemDecorator] = []

  var count: Int { items.count }
  var loadedItems: [IndexedHistoryItem] {
    items.enumerated().map {
      IndexedHistoryItem(item: $0.element, index: $0.offset)
    }
  }
  let allowsSelectionExtensionToBoundary = true

  func replace(with items: [HistoryItemDecorator]) {
    self.items = items
  }

  func item(at index: Int) async throws -> IndexedHistoryItem? {
    guard items.indices.contains(index) else { return nil }
    return IndexedHistoryItem(item: items[index], index: index)
  }

  func loadedItem(id: UUID) -> IndexedHistoryItem? {
    guard let index = items.firstIndex(where: { $0.id == id }) else {
      return nil
    }
    return IndexedHistoryItem(item: items[index], index: index)
  }

  func contains(modelID: PersistentIdentifier) throws -> Bool {
    items.contains {
      $0.item.persistentModelID == modelID
    }
  }

  func resolve(
    modelID: PersistentIdentifier
  ) async throws -> IndexedHistoryItem? {
    guard let index = items.firstIndex(where: {
      $0.item.persistentModelID == modelID
    }) else {
      return nil
    }
    return IndexedHistoryItem(item: items[index], index: index)
  }
}
