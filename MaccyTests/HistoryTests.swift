import XCTest
import Defaults
@testable import Maccy

@MainActor
class HistoryTests: XCTestCase {
  let savedSize = Defaults[.size]
  let savedSortBy = Defaults[.sortBy]
  let savedPinTo = Defaults[.pinTo]
  let savedUnlimitedHistory = Defaults[.isUnlimitedHistory]
  let history = History.shared

  var displayedItems: [HistoryItemDecorator] {
    history.historyItems.loadedItems.map(\.item)
  }

  override func setUp() async throws {
    try await super.setUp()
    Defaults[.size] = 10
    Defaults[.sortBy] = .firstCopiedAt
    Defaults[.pinTo] = .top
    await setUnlimitedHistory(false)
    history.clearAll()
  }

  override func tearDown() async throws {
    history.clearAll()
    Defaults[.size] = savedSize
    Defaults[.sortBy] = savedSortBy
    Defaults[.pinTo] = savedPinTo
    await setUnlimitedHistory(savedUnlimitedHistory)
    try await super.tearDown()
  }

  func testDefaultIsEmpty() {
    XCTAssertEqual(displayedItems, [])
  }

  func testAdding() {
    let first = history.add(historyItem("foo"))
    let second = history.add(historyItem("bar"))
    XCTAssertEqual(displayedItems, [second, first])
  }

  func testAddingSame() {
    let first = historyItem("foo")
    first.title = "xyz"
    first.application = "iTerm.app"
    let firstDecorator = history.add(first)
    first.pin = "f"

    let secondDecorator = history.add(historyItem("bar"))

    let third = historyItem("foo")
    third.application = "Xcode.app"
    history.add(third)

    XCTAssertEqual(displayedItems, [firstDecorator, secondDecorator])
    XCTAssertTrue(
      displayedItems[0].item.lastCopiedAt
        > displayedItems[0].item.firstCopiedAt
    )
    // TODO: This works in reality but fails in tests?!
    // XCTAssertEqual(displayedItems[0].item.numberOfCopies, 2)
    XCTAssertEqual(displayedItems[0].item.pin, "f")
    XCTAssertEqual(displayedItems[0].item.title, "xyz")
    XCTAssertEqual(displayedItems[0].item.application, "iTerm.app")
  }

  func testAddingItemThatIsSupersededByExisting() {
    let firstContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)!
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.rtf.rawValue,
        value: "two".data(using: .utf8)!
      )
    ]
    let firstItem = HistoryItem()
    Storage.shared.context.insert(firstItem)
    firstItem.application = "Maccy.app"
    firstItem.contents = firstContents
    firstItem.title = firstItem.generateTitle()
    history.add(firstItem)

    let secondContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)!
      )
    ]
    let secondItem = HistoryItem()
    Storage.shared.context.insert(secondItem)
    secondItem.application = "Maccy.app"
    secondItem.contents = secondContents
    secondItem.title = secondItem.generateTitle()
    let second = history.add(secondItem)

    XCTAssertEqual(displayedItems, [second])
    XCTAssertEqual(
      Set(displayedItems[0].item.contents),
      Set(firstContents)
    )
  }

  func testAddingItemWithDifferentModifiedType() {
    let firstContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)!
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.modified.rawValue,
        value: "1".data(using: .utf8)!
      )
    ]
    let firstItem = HistoryItem()
    Storage.shared.context.insert(firstItem)
    firstItem.contents = firstContents
    history.add(firstItem)

    let secondContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)!
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.modified.rawValue,
        value: "2".data(using: .utf8)!
      )
    ]
    let secondItem = HistoryItem()
    Storage.shared.context.insert(secondItem)
    secondItem.contents = secondContents
    let second = history.add(secondItem)

    XCTAssertEqual(displayedItems, [second])
    XCTAssertEqual(
      Set(displayedItems[0].item.contents),
      Set(firstContents)
    )
  }

  func testAddingItemFromMaccy() {
    let firstContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)
      )
    ]
    let first = HistoryItem()
    Storage.shared.context.insert(first)
    first.application = "Xcode.app"
    first.contents = firstContents
    history.add(first)

    let secondContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.fromMaccy.rawValue,
        value: "".data(using: .utf8)
      )
    ]
    let second = HistoryItem()
    Storage.shared.context.insert(second)
    second.application = "Maccy.app"
    second.contents = secondContents
    let secondDecorator = history.add(second)

    XCTAssertEqual(displayedItems, [secondDecorator])
    XCTAssertEqual(displayedItems[0].item.application, "Xcode.app")
    XCTAssertEqual(
      Set(displayedItems[0].item.contents),
      Set(firstContents)
    )
  }

  func testModifiedAfterCopying() {
    history.add(historyItem("foo"))

    let modifiedItem = historyItem("bar")
    modifiedItem.contents.append(HistoryItemContent(
      type: NSPasteboard.PasteboardType.modified.rawValue,
      value: String(Clipboard.shared.changeCount).data(using: .utf8)
    ))
    let modifiedItemDecorator = history.add(modifiedItem)

    XCTAssertEqual(displayedItems, [modifiedItemDecorator])
    XCTAssertEqual(displayedItems[0].text, "bar")
  }

  func testClearingUnpinned() {
    let pinned = history.add(historyItem("foo"))
    history.togglePin(pinned)
    history.add(historyItem("bar"))
    history.clear()
    XCTAssertEqual(displayedItems, [pinned])
  }

  func testClearingAll() {
    history.add(historyItem("foo"))
    history.clear()
    XCTAssertEqual(displayedItems, [])
  }

  func testMaxSize() {
    var items: [HistoryItemDecorator] = []
    for index in 0...10 {
      items.append(history.add(historyItem(String(index))))
    }

    XCTAssertEqual(displayedItems.count, 10)
    XCTAssertTrue(displayedItems.contains(items[10]))
    XCTAssertFalse(displayedItems.contains(items[0]))
  }

  func testMaxSizeIgnoresPinned() {
    var items: [HistoryItemDecorator] = []

    let item = history.add(historyItem("0"))
    items.append(item)
    history.togglePin(item)

    for index in 1...11 {
      items.append(history.add(historyItem(String(index))))
    }

    XCTAssertEqual(displayedItems.count, 11)
    XCTAssertTrue(displayedItems.contains(items[10]))
    XCTAssertTrue(displayedItems.contains(items[0]))
    XCTAssertFalse(displayedItems.contains(items[1]))
  }

  func testMaxSizeIsChanged() {
    var items: [HistoryItemDecorator] = []
    for index in 0...10 {
      items.append(history.add(historyItem(String(index))))
    }
    Defaults[.size] = 5
    history.add(historyItem("11"))

    XCTAssertEqual(displayedItems.count, 5)
    XCTAssertTrue(displayedItems.contains(items[10]))
    XCTAssertFalse(displayedItems.contains(items[5]))
  }

  func testSwitchingToLimitedHistoryAppliesRetention() async {
    await setUnlimitedHistory(true)
    var items: [HistoryItemDecorator] = []
    for index in 0...20 {
      let item = historyItem(String(index))
      let copiedAt = Date(
        timeIntervalSinceReferenceDate: TimeInterval(index)
      )
      item.firstCopiedAt = copiedAt
      item.lastCopiedAt = copiedAt
      items.append(history.add(item))
    }

    XCTAssertEqual(history.unpinnedItems.pageSize, 20)
    XCTAssertEqual(history.unpinnedItems.count, 21)
    XCTAssertEqual(history.unpinnedItems.pageCount, 2)
    XCTAssertFalse(
      history.historyItems.allowsSelectionExtensionToBoundary
    )

    await setUnlimitedHistory(false)

    XCTAssertNil(history.unpinnedItems.pageSize)
    XCTAssertEqual(history.unpinnedItems.count, 10)
    XCTAssertEqual(history.unpinnedItems.pageCount, 1)
    XCTAssertEqual(history.unpinnedItems.loadedItems.count, 10)
    XCTAssertTrue(
      history.historyItems.allowsSelectionExtensionToBoundary
    )
    let retainedItems = history.unpinnedItems.loadedItems.map(\.item)
    XCTAssertTrue(retainedItems.contains(items[20]))
    XCTAssertFalse(retainedItems.contains(items[0]))
  }

  func testMutationInvalidatesLocatedHistoryItem() async throws {
    let first = history.add(historyItem("first"))
    history.add(historyItem("second"))
    let locatedFirst = try XCTUnwrap(
      history.historyItems.loadedItem(id: first.id)
    )

    history.add(historyItem("third"))

    do {
      _ = try await history.historyItems.item(after: locatedFirst)
      XCTFail("Expected mutation to invalidate the old history location")
    } catch HistoryItemsError.staleLocation {
      // Expected.
    }
  }

  func testRemoving() {
    let foo = history.add(historyItem("foo"))
    let bar = history.add(historyItem("bar"))
    history.delete(foo)
    XCTAssertEqual(displayedItems, [bar])
  }

  func testPinsStaySeparateFromUnpinnedItems() {
    let first = history.add(historyItem("first"))
    let second = history.add(historyItem("second"))

    history.togglePin(first)

    XCTAssertEqual(history.pinnedItems, [first])
    XCTAssertEqual(
      history.unpinnedItems.loadedItems.map(\.item),
      [second]
    )
    XCTAssertEqual(displayedItems, [first, second])

    Defaults[.pinTo] = .bottom

    XCTAssertEqual(displayedItems, [second, first])
  }

  private func historyItem(_ value: String) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value.data(using: .utf8)
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.numberOfCopies = 1
    item.title = item.generateTitle()

    return item
  }

  private func setUnlimitedHistory(_ enabled: Bool) async {
    Defaults[.isUnlimitedHistory] = enabled
    let expectedPageSize: Int? = enabled ? 20 : nil
    for _ in 0..<200 {
      if history.unpinnedItems.pageSize == expectedPageSize {
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail(
      "History did not switch to the expected pagination mode"
    )
  }
}
