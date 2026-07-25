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

  private func historyItems(
    pins: @escaping () -> [HistoryItemDecorator],
    unpinned: ResidentHistoryItems,
    pinTo: @escaping () -> PinsPosition = { .top }
  ) -> HistoryItems {
    HistoryItems(
      pinnedItems: pins,
      unpinnedItems: { unpinned },
      pinsPosition: pinTo
    )
  }

  private func decorator(_ title: String) -> HistoryItemDecorator {
    let item = HistoryItem()
    item.title = title
    return HistoryItemDecorator(item)
  }
}
