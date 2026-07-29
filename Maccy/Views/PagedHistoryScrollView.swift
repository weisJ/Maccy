// swiftlint:disable file_length
import AppKit
import SwiftData
import SwiftUI

/// A vertically scrolling view that retains only the visible history pages.
///
/// The collection view has one item per page. Page geometry comes from the
/// source's layout summaries, so loading or selecting an item cannot change
/// the document layout.
@MainActor
// swiftlint:disable:next type_body_length
struct PagedHistoryScrollView<Content: View>: NSViewRepresentable {
  typealias NSViewType = NSScrollView

  private let historyItems: PagedHistoryItems
  private let sourceLayoutRevision: UInt64
  private let sourceContentRevision: UInt64
  private let sourceReloadRevision: UInt64
  private let regularItemHeight: CGFloat
  private let imageItemHeight: CGFloat
  private let rowHeightProvider: (HistoryItemDecorator) -> CGFloat
  private let scrollTargetModelID: PersistentIdentifier?
  private let scrollRequestID: UUID?
  private let contentInsets: EdgeInsets
  private let scrollIndicatorInsets: EdgeInsets
  private let makeContent: (PagedHistoryPage) -> AnyView

  /// `scrollRequestID` should be a fresh token for each request. This permits
  /// consecutive requests for the same item to scroll it into view again.
  init(
    historyItems: PagedHistoryItems,
    regularItemHeight: CGFloat,
    imageItemHeight: CGFloat? = nil,
    rowHeightProvider: ((HistoryItemDecorator) -> CGFloat)? = nil,
    scrollTargetModelID: PersistentIdentifier? = nil,
    scrollRequestID: UUID? = nil,
    contentInsets: EdgeInsets = EdgeInsets(),
    scrollIndicatorInsets: EdgeInsets = EdgeInsets(),
    @ViewBuilder content: @escaping (PagedHistoryPage) -> Content
  ) {
    let regularItemHeight = max(0, regularItemHeight)
    self.historyItems = historyItems
    sourceLayoutRevision = historyItems.layoutRevision
    sourceContentRevision = historyItems.contentRevision
    sourceReloadRevision = historyItems.reloadRevision
    self.regularItemHeight = regularItemHeight
    self.imageItemHeight = max(
      0,
      imageItemHeight ?? regularItemHeight
    )
    self.rowHeightProvider =
      rowHeightProvider ?? { _ in regularItemHeight }
    self.scrollTargetModelID = scrollTargetModelID
    self.scrollRequestID = scrollRequestID
    self.contentInsets = contentInsets.clampedToNonnegativeValues
    self.scrollIndicatorInsets =
      scrollIndicatorInsets.clampedToNonnegativeValues
    self.makeContent = { page in AnyView(content(page)) }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(configuration: self)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay
    configure(
      scrollView,
      layoutDirection: context.environment.layoutDirection
    )

    let collectionView = FlippedCollectionView()
    collectionView.frame = NSRect(
      x: 0,
      y: 0,
      width: max(1, scrollView.contentSize.width),
      height: 1
    )
    collectionView.autoresizingMask = [.width]
    collectionView.isSelectable = false
    collectionView.backgroundColors = [.clear]

    let layout = PagePrefixLayout()
    collectionView.collectionViewLayout = layout
    collectionView.register(
      HostingPageItem.self as AnyClass,
      forItemWithIdentifier: HostingPageItem.reuseIdentifier
    )
    collectionView.dataSource = context.coordinator
    collectionView.delegate = context.coordinator

    scrollView.documentView = collectionView

    context.coordinator.attach(
      collectionView: collectionView,
      layout: layout
    )
    context.coordinator.apply(
      configuration: self,
      layoutDirection: context.environment.layoutDirection,
      forceReload: true
    )
    return scrollView
  }

  func updateNSView(
    _ scrollView: NSScrollView,
    context: Context
  ) {
    configure(
      scrollView,
      layoutDirection: context.environment.layoutDirection
    )
    context.coordinator.apply(
      configuration: self,
      layoutDirection: context.environment.layoutDirection,
      forceReload: false
    )
  }

  static func dismantleNSView(
    _ scrollView: NSScrollView,
    coordinator: Coordinator
  ) {
    coordinator.detach()
  }

  @MainActor
  // swiftlint:disable:next type_body_length
  final class Coordinator: NSObject,
    NSCollectionViewDataSource,
    NSCollectionViewDelegate {
    private weak var collectionView: NSCollectionView?
    private weak var layout: PagePrefixLayout?

    private var historyItems: PagedHistoryItems
    private var historyItemsIdentity: ObjectIdentifier
    private var layoutRevision: UInt64
    private var contentRevision: UInt64
    private var reloadRevision: UInt64
    private var renderedPageCount: Int
    private var regularItemHeight: CGFloat
    private var imageItemHeight: CGFloat
    private var rowHeightProvider: (HistoryItemDecorator) -> CGFloat
    private var scrollTargetModelID: PersistentIdentifier?
    private var scrollRequestID: UUID?
    private var contentInsets: ResolvedInsets
    private var layoutDirection: LayoutDirection
    private var makeContent: (PagedHistoryPage) -> AnyView

    private var lastHandledScrollTargetModelID: PersistentIdentifier?
    private var lastHandledScrollRequestID: UUID?
    private var isLayoutBatchUpdateInFlight = false
    private var pendingCollectionUpdate: CollectionUpdate?

    fileprivate init(configuration: PagedHistoryScrollView) {
      historyItems = configuration.historyItems
      historyItemsIdentity = ObjectIdentifier(configuration.historyItems)
      layoutRevision = configuration.sourceLayoutRevision
      contentRevision = configuration.sourceContentRevision
      reloadRevision = configuration.sourceReloadRevision
      renderedPageCount = configuration.historyItems.pageCount
      regularItemHeight = configuration.regularItemHeight
      imageItemHeight = configuration.imageItemHeight
      rowHeightProvider = configuration.rowHeightProvider
      scrollTargetModelID = configuration.scrollTargetModelID
      scrollRequestID = configuration.scrollRequestID
      contentInsets = ResolvedInsets(
        configuration.contentInsets,
        layoutDirection: .leftToRight
      )
      layoutDirection = .leftToRight
      makeContent = configuration.makeContent
      super.init()
    }

    fileprivate func attach(
      collectionView: NSCollectionView,
      layout: PagePrefixLayout
    ) {
      self.collectionView = collectionView
      self.layout = layout
    }

    fileprivate func detach() {
      releaseVisiblePageLeases(using: historyItems)
      pendingCollectionUpdate = nil
      collectionView?.dataSource = nil
      collectionView?.delegate = nil
      collectionView = nil
      layout = nil
    }

    fileprivate func apply(
      configuration: PagedHistoryScrollView,
      layoutDirection: LayoutDirection,
      forceReload: Bool
    ) {
      let newIdentity = ObjectIdentifier(configuration.historyItems)
      let sourceChanged = newIdentity != historyItemsIdentity
      let newLayoutRevision = configuration.sourceLayoutRevision
      let newContentRevision = configuration.sourceContentRevision
      let newReloadRevision = configuration.sourceReloadRevision
      let newContentInsets = ResolvedInsets(
        configuration.contentInsets,
        layoutDirection: layoutDirection
      )

      let layoutChanged = newLayoutRevision != layoutRevision
      let contentChanged = newContentRevision != contentRevision
      let reloadChanged = newReloadRevision != reloadRevision
      let rowHeightsChanged =
        configuration.regularItemHeight != regularItemHeight
        || configuration.imageItemHeight != imageItemHeight
      let contentInsetsChanged = newContentInsets != contentInsets
      let hostEnvironmentChanged =
        layoutDirection != self.layoutDirection
      let scrollTargetChanged =
        configuration.scrollTargetModelID != scrollTargetModelID
        || configuration.scrollRequestID != scrollRequestID

      if sourceChanged {
        releaseVisiblePageLeases(using: historyItems)
      }

      historyItems = configuration.historyItems
      historyItemsIdentity = newIdentity
      layoutRevision = newLayoutRevision
      contentRevision = newContentRevision
      reloadRevision = newReloadRevision
      regularItemHeight = configuration.regularItemHeight
      imageItemHeight = configuration.imageItemHeight
      rowHeightProvider = configuration.rowHeightProvider
      scrollTargetModelID = configuration.scrollTargetModelID
      scrollRequestID = configuration.scrollRequestID
      contentInsets = newContentInsets
      self.layoutDirection = layoutDirection
      makeContent = configuration.makeContent

      scheduleCollectionUpdate(
        CollectionUpdate(
          mustReload: forceReload || sourceChanged || reloadChanged,
          layoutChanged: layoutChanged,
          contentChanged: contentChanged,
          rowHeightsChanged: rowHeightsChanged,
          contentInsetsChanged: contentInsetsChanged,
          hostEnvironmentChanged: hostEnvironmentChanged,
          scrollTargetChanged: scrollTargetChanged
        )
      )
    }

    // MARK: NSCollectionViewDataSource

    func numberOfSections(
      in collectionView: NSCollectionView
    ) -> Int {
      1
    }

    func collectionView(
      _ collectionView: NSCollectionView,
      numberOfItemsInSection section: Int
    ) -> Int {
      renderedPageCount
    }

    func collectionView(
      _ collectionView: NSCollectionView,
      itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
      let item = collectionView.makeItem(
        withIdentifier: HostingPageItem.reuseIdentifier,
        for: indexPath
      )
      guard let item = item as? HostingPageItem else {
        assertionFailure("Unexpected paged-history item type")
        return item
      }
      configure(item, forPageAt: indexPath.item)
      return item
    }

    // MARK: NSCollectionViewDelegate

    func collectionView(
      _ collectionView: NSCollectionView,
      didEndDisplaying item: NSCollectionViewItem,
      forRepresentedObjectAt indexPath: IndexPath
    ) {
      guard let item = item as? HostingPageItem,
        item.representedPageIndex == indexPath.item
      else {
        return
      }
      releasePageLease(for: item)
      item.clear()
    }

    // MARK: Page hosting

    private func configure(
      _ item: HostingPageItem,
      forPageAt pageIndex: Int,
      preserveContent: Bool = false
    ) {
      if item.retainedPageIndex != pageIndex {
        releasePageLease(for: item)
        historyItems.retainPage(at: pageIndex)
        item.retainedPageIndex = pageIndex
      }
      item.prepareForConfiguration(
        pageIndex: pageIndex,
        preserveContent: preserveContent
      )

      let height = pageHeight(at: pageIndex)
      do {
        guard let page = try historyItems.loadPage(at: pageIndex) else {
          item.clearContent(height: height)
          return
        }
        item.pageContentRevision = page.contentRevision
        item.setContent(makeContent(page), height: height)
      } catch {
        if preserveContent {
          item.updateHeight(height)
        } else {
          item.setContent(
            AnyView(
              Text(error.localizedDescription)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            ),
            height: height
          )
        }
      }
    }

    private func releasePageLease(for item: HostingPageItem) {
      guard let pageIndex = item.retainedPageIndex else { return }
      historyItems.releasePage(at: pageIndex)
      item.retainedPageIndex = nil
    }

    private func releaseVisiblePageLeases(
      using source: PagedHistoryItems
    ) {
      guard let collectionView else { return }
      for case let item as HostingPageItem
        in collectionView.visibleItems() {
        guard let pageIndex = item.retainedPageIndex else { continue }
        source.releasePage(at: pageIndex)
        item.retainedPageIndex = nil
      }
    }

    private func clearVisibleItems() {
      guard let collectionView else { return }
      for case let item as HostingPageItem
        in collectionView.visibleItems() {
        releasePageLease(for: item)
        item.clear()
      }
    }

    // MARK: Source updates

    private func scheduleCollectionUpdate(
      _ update: CollectionUpdate
    ) {
      guard collectionView != nil, layout != nil else { return }

      if isLayoutBatchUpdateInFlight {
        if pendingCollectionUpdate == nil {
          pendingCollectionUpdate = update
        } else {
          pendingCollectionUpdate?.merge(update)
        }
        return
      }

      performCollectionUpdate(update)
    }

    private func performCollectionUpdate(
      _ update: CollectionUpdate
    ) {
      guard let collectionView, let layout else { return }

      if update.mustReload {
        reloadCollectionView(collectionView, layout: layout)
        scrollIfNeeded(to: scrollTargetModelID)
        return
      }

      if update.layoutChanged {
        applyLayoutUpdate(
          collectionView,
          layout: layout,
          update: update
        )
        return
      }

      if update.rowHeightsChanged || update.contentInsetsChanged {
        configureLayout(layout)
        layout.invalidateLayout()
      }

      if update.contentChanged
        || update.rowHeightsChanged
        || update.hostEnvironmentChanged {
        refreshChangedVisibleItems(
          forceContentRefresh:
            update.rowHeightsChanged || update.hostEnvironmentChanged
        )
      }

      scrollIfNeeded(to: scrollTargetModelID)
    }

    private func applyLayoutUpdate(
      _ collectionView: NSCollectionView,
      layout: PagePrefixLayout,
      update: CollectionUpdate
    ) {
      let oldPageCount = renderedPageCount
      let newPageCount = historyItems.pageCount
      renderedPageCount = newPageCount
      configureLayout(layout)

      guard oldPageCount != newPageCount else {
        layout.invalidateLayout()
        updateVisibleItemHeights()
        refreshChangedVisibleItems(
          forceContentRefresh:
            update.rowHeightsChanged || update.hostEnvironmentChanged
        )
        finishLayoutUpdate(update)
        return
      }

      isLayoutBatchUpdateInFlight = true
      if newPageCount > oldPageCount {
        let insertedItems = Set(
          (oldPageCount..<newPageCount).map {
            IndexPath(item: $0, section: 0)
          }
        )
        collectionView.performBatchUpdates {
          collectionView.insertItems(at: insertedItems)
        } completionHandler: { [weak self] _ in
          self?.completeLayoutBatch(update)
        }
      } else {
        let deletedItems = Set(
          (newPageCount..<oldPageCount).map {
            IndexPath(item: $0, section: 0)
          }
        )
        collectionView.performBatchUpdates {
          collectionView.deleteItems(at: deletedItems)
        } completionHandler: { [weak self] _ in
          self?.completeLayoutBatch(update)
        }
      }
    }

    private func completeLayoutBatch(
      _ update: CollectionUpdate
    ) {
      layout?.invalidateLayout()
      updateVisibleItemHeights()
      refreshChangedVisibleItems(
        forceContentRefresh:
          update.rowHeightsChanged || update.hostEnvironmentChanged
      )
      isLayoutBatchUpdateInFlight = false
      finishLayoutUpdate(update)
    }

    private func finishLayoutUpdate(
      _ completedUpdate: CollectionUpdate
    ) {
      if var pendingUpdate = pendingCollectionUpdate {
        pendingCollectionUpdate = nil
        pendingUpdate.contentChanged =
          pendingUpdate.contentChanged || completedUpdate.contentChanged
        pendingUpdate.rowHeightsChanged =
          pendingUpdate.rowHeightsChanged
          || completedUpdate.rowHeightsChanged
        pendingUpdate.hostEnvironmentChanged =
          pendingUpdate.hostEnvironmentChanged
          || completedUpdate.hostEnvironmentChanged
        pendingUpdate.scrollTargetChanged =
          pendingUpdate.scrollTargetChanged
          || completedUpdate.scrollTargetChanged
        performCollectionUpdate(pendingUpdate)
        return
      }

      scrollIfNeeded(to: scrollTargetModelID)
    }

    private func refreshChangedVisibleItems(
      forceContentRefresh: Bool
    ) {
      guard let collectionView else { return }
      for case let item as HostingPageItem
        in collectionView.visibleItems() {
        guard let pageIndex = item.representedPageIndex,
          pageIndex >= 0,
          pageIndex < renderedPageCount
        else {
          continue
        }
        let pageRevision =
          historyItems.loadedPage(at: pageIndex)?.contentRevision
        guard forceContentRefresh
          || item.pageContentRevision != pageRevision
        else {
          continue
        }
        configure(
          item,
          forPageAt: pageIndex,
          preserveContent: true
        )
      }
    }

    private func updateVisibleItemHeights() {
      guard let collectionView else { return }
      for case let item as HostingPageItem
        in collectionView.visibleItems() {
        guard let pageIndex = item.representedPageIndex,
          pageIndex >= 0,
          pageIndex < renderedPageCount
        else {
          continue
        }
        item.updateHeight(pageHeight(at: pageIndex))
      }
    }

    private func configureLayout(_ layout: PagePrefixLayout) {
      let heights = (0..<renderedPageCount).map(pageHeight)
      layout.configure(
        pageHeights: heights,
        contentInsets: contentInsets
      )
    }

    private func reloadCollectionView(
      _ collectionView: NSCollectionView,
      layout: PagePrefixLayout
    ) {
      renderedPageCount = historyItems.pageCount
      clearVisibleItems()
      configureLayout(layout)
      layout.invalidateLayout()
      collectionView.reloadData()
    }

    private func pageHeight(at pageIndex: Int) -> CGFloat {
      historyItems.layoutSummary(forPageAt: pageIndex)?.height(
        regularItemHeight: regularItemHeight,
        imageItemHeight: imageItemHeight
      ) ?? 0
    }

    // MARK: Scrolling

    private func scrollIfNeeded(
      to modelID: PersistentIdentifier?
    ) {
      guard let modelID else {
        lastHandledScrollTargetModelID = nil
        lastHandledScrollRequestID = nil
        return
      }
      let alreadyHandled = if let scrollRequestID {
        scrollRequestID == lastHandledScrollRequestID
      } else {
        modelID == lastHandledScrollTargetModelID
      }
      guard !alreadyHandled, let collectionView,
        let layout
      else {
        return
      }

      do {
        guard let globalIndex = try historyItems.index(of: modelID),
          globalIndex >= 0,
          globalIndex < historyItems.count
        else {
          return
        }
        let pageIndex = pageIndex(containing: globalIndex)
        historyItems.retainPage(at: pageIndex)
        defer { historyItems.releasePage(at: pageIndex) }

        guard let page = try historyItems.loadPage(at: pageIndex),
          page.range.contains(globalIndex),
          let pageFrame = layout.frameForPage(at: pageIndex),
          let rowFrame = rowFrame(
            for: globalIndex,
            in: page,
            pageFrame: pageFrame
          )
        else {
          return
        }

        collectionView.scrollToVisible(rowFrame)
        lastHandledScrollTargetModelID = modelID
        lastHandledScrollRequestID = scrollRequestID
      } catch {
        return
      }
    }

    private func pageIndex(containing itemIndex: Int) -> Int {
      historyItems.pageSize.map { itemIndex / $0 } ?? 0
    }

    private func rowFrame(
      for globalIndex: Int,
      in page: PagedHistoryPage,
      pageFrame: NSRect
    ) -> NSRect? {
      let localIndex = globalIndex - page.startIndex
      guard page.items.indices.contains(localIndex) else { return nil }

      let offset = page.items[..<localIndex].reduce(CGFloat.zero) {
        $0 + max(0, rowHeightProvider($1))
      }
      return NSRect(
        x: pageFrame.minX,
        y: pageFrame.minY + offset,
        width: pageFrame.width,
        height: max(0, rowHeightProvider(page.items[localIndex]))
      )
    }
  }
}

private struct CollectionUpdate {
  var mustReload = false
  var layoutChanged = false
  var contentChanged = false
  var rowHeightsChanged = false
  var contentInsetsChanged = false
  var hostEnvironmentChanged = false
  var scrollTargetChanged = false

  mutating func merge(_ other: CollectionUpdate) {
    mustReload = mustReload || other.mustReload
    layoutChanged = layoutChanged || other.layoutChanged
    contentChanged = contentChanged || other.contentChanged
    rowHeightsChanged = rowHeightsChanged || other.rowHeightsChanged
    contentInsetsChanged =
      contentInsetsChanged || other.contentInsetsChanged
    hostEnvironmentChanged =
      hostEnvironmentChanged || other.hostEnvironmentChanged
    scrollTargetChanged =
      scrollTargetChanged || other.scrollTargetChanged
  }
}

private extension PagedHistoryScrollView {
  func configure(
    _ scrollView: NSScrollView,
    layoutDirection: LayoutDirection
  ) {
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.contentInsets = NSEdgeInsets()
    scrollView.scrollerInsets = ResolvedInsets(
      scrollIndicatorInsets,
      layoutDirection: layoutDirection
    ).edgeInsets
  }
}

// MARK: - Reusable collection-view item

@MainActor
private final class HostingPageItem: NSCollectionViewItem {
  static let reuseIdentifier = NSUserInterfaceItemIdentifier(
    "PagedHistoryScrollView.HostingPageItem"
  )

  var representedPageIndex: Int?
  var retainedPageIndex: Int?
  var pageContentRevision: UInt64?

  private let hostingView = NSHostingView(
    rootView: AnyView(EmptyView())
  )
  private var content: AnyView?
  private var contentHeight: CGFloat = 0

  override func loadView() {
    let container = NSView()
    container.wantsLayer = true
    container.layer?.masksToBounds = true

    hostingView.translatesAutoresizingMaskIntoConstraints = false
    hostingView.setContentHuggingPriority(.defaultLow, for: .horizontal)
    hostingView.setContentHuggingPriority(.defaultLow, for: .vertical)
    hostingView.setContentCompressionResistancePriority(
      .defaultLow,
      for: .horizontal
    )
    hostingView.setContentCompressionResistancePriority(
      .defaultLow,
      for: .vertical
    )

    container.addSubview(hostingView)
    NSLayoutConstraint.activate([
      hostingView.leadingAnchor.constraint(
        equalTo: container.leadingAnchor
      ),
      hostingView.trailingAnchor.constraint(
        equalTo: container.trailingAnchor
      ),
      hostingView.topAnchor.constraint(equalTo: container.topAnchor),
      hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
    ])
    view = container
  }

  func prepareForConfiguration(
    pageIndex: Int,
    preserveContent: Bool
  ) {
    let canPreserve = preserveContent
      && representedPageIndex == pageIndex
      && content != nil
    representedPageIndex = pageIndex

    if !canPreserve {
      pageContentRevision = nil
      content = nil
      if isViewLoaded {
        hostingView.rootView = AnyView(EmptyView())
      }
    }
  }

  func setContent(_ content: AnyView, height: CGFloat) {
    self.content = content
    contentHeight = max(0, height)
    renderContent()
  }

  func clearContent(height: CGFloat) {
    setContent(AnyView(EmptyView()), height: height)
  }

  func updateHeight(_ height: CGFloat) {
    let height = max(0, height)
    guard content != nil, height != contentHeight else { return }
    contentHeight = height
    renderContent()
  }

  func clear() {
    representedPageIndex = nil
    retainedPageIndex = nil
    pageContentRevision = nil
    content = nil
    contentHeight = 0
    if isViewLoaded {
      hostingView.rootView = AnyView(EmptyView())
    }
  }

  private func renderContent() {
    guard let content else { return }
    loadViewIfNeeded()
    hostingView.rootView = AnyView(
      content
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: contentHeight, alignment: .topLeading)
        .clipped()
    )
  }
}

// MARK: - Prefix-sum layout

/// A vertical layout that keeps only scalar page geometry in memory.
@MainActor
private final class PagePrefixLayout: NSCollectionViewLayout {
  private var configuredHeights: [CGFloat] = []
  private var contentInsets = ResolvedInsets()

  private var cachedWidth: CGFloat = -1
  private var offsets: [CGFloat] = []
  private var calculatedContentHeight: CGFloat = 0
  private var needsRebuild = true

  func configure(
    pageHeights: [CGFloat],
    contentInsets: ResolvedInsets
  ) {
    let pageHeights = pageHeights.map { max(0, $0) }
    guard configuredHeights != pageHeights
      || self.contentInsets != contentInsets
    else {
      return
    }
    configuredHeights = pageHeights
    self.contentInsets = contentInsets
    needsRebuild = true
  }

  override func invalidateLayout() {
    needsRebuild = true
    super.invalidateLayout()
  }

  override func prepare() {
    super.prepare()
    rebuildIfNeeded()
  }

  override var collectionViewContentSize: NSSize {
    rebuildIfNeeded()
    return NSSize(
      width: max(1, cachedWidth),
      height: calculatedContentHeight
    )
  }

  override func layoutAttributesForElements(
    in rect: NSRect
  ) -> [NSCollectionViewLayoutAttributes] {
    rebuildIfNeeded()
    guard !configuredHeights.isEmpty else { return [] }

    var pageIndex = firstPageIntersecting(verticalPosition: rect.minY)
    var result: [NSCollectionViewLayoutAttributes] = []
    while pageIndex < configuredHeights.count {
      let frame = frameForPageUnchecked(at: pageIndex)
      if frame.minY >= rect.maxY {
        break
      }
      if frame.intersects(rect) {
        let attributes = NSCollectionViewLayoutAttributes(
          forItemWith: IndexPath(item: pageIndex, section: 0)
        )
        attributes.frame = frame
        result.append(attributes)
      }
      pageIndex += 1
    }
    return result
  }

  override func layoutAttributesForItem(
    at indexPath: IndexPath
  ) -> NSCollectionViewLayoutAttributes? {
    rebuildIfNeeded()
    guard indexPath.section == 0,
      configuredHeights.indices.contains(indexPath.item)
    else {
      return nil
    }

    let attributes = NSCollectionViewLayoutAttributes(
      forItemWith: indexPath
    )
    attributes.frame = frameForPageUnchecked(at: indexPath.item)
    return attributes
  }

  override func shouldInvalidateLayout(
    forBoundsChange newBounds: NSRect
  ) -> Bool {
    abs(newBounds.width - cachedWidth) > 0.5
  }

  func frameForPage(at pageIndex: Int) -> NSRect? {
    rebuildIfNeeded()
    guard configuredHeights.indices.contains(pageIndex) else {
      return nil
    }
    return frameForPageUnchecked(at: pageIndex)
  }

  private func rebuildIfNeeded() {
    guard let collectionView else { return }

    let width = max(1, collectionView.bounds.width)
    let widthChanged = abs(width - cachedWidth) > 0.5
    guard needsRebuild || widthChanged else { return }

    cachedWidth = width
    offsets = Array(repeating: 0, count: configuredHeights.count)

    var nextY = contentInsets.top
    for pageIndex in configuredHeights.indices {
      offsets[pageIndex] = nextY
      nextY += configuredHeights[pageIndex]
    }
    calculatedContentHeight = nextY + contentInsets.bottom
    needsRebuild = false
  }

  private func frameForPageUnchecked(at pageIndex: Int) -> NSRect {
    NSRect(
      x: contentInsets.left,
      y: offsets[pageIndex],
      width: max(
        1,
        cachedWidth - contentInsets.left - contentInsets.right
      ),
      height: configuredHeights[pageIndex]
    )
  }

  /// Returns the first page whose bottom edge lies below the given position.
  private func firstPageIntersecting(
    verticalPosition: CGFloat
  ) -> Int {
    var lowerBound = 0
    var upperBound = configuredHeights.count
    while lowerBound < upperBound {
      let middle = lowerBound + (upperBound - lowerBound) / 2
      let bottom = offsets[middle] + configuredHeights[middle]
      if bottom <= verticalPosition {
        lowerBound = middle + 1
      } else {
        upperBound = middle
      }
    }
    return lowerBound
  }
}

private final class FlippedCollectionView: NSCollectionView {
  override var isFlipped: Bool { true }
}

private struct ResolvedInsets: Equatable {
  var top: CGFloat = 0
  var left: CGFloat = 0
  var bottom: CGFloat = 0
  var right: CGFloat = 0

  init() {}

  init(
    _ insets: EdgeInsets,
    layoutDirection: LayoutDirection
  ) {
    top = insets.top
    bottom = insets.bottom
    switch layoutDirection {
    case .leftToRight:
      left = insets.leading
      right = insets.trailing
    case .rightToLeft:
      left = insets.trailing
      right = insets.leading
    @unknown default:
      left = insets.leading
      right = insets.trailing
    }
  }

  var edgeInsets: NSEdgeInsets {
    NSEdgeInsets(
      top: top,
      left: left,
      bottom: bottom,
      right: right
    )
  }
}

private extension EdgeInsets {
  var clampedToNonnegativeValues: EdgeInsets {
    EdgeInsets(
      top: max(0, top),
      leading: max(0, leading),
      bottom: max(0, bottom),
      trailing: max(0, trailing)
    )
  }
}
