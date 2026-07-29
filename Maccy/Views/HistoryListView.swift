import Defaults
import SwiftUI

struct HistoryListView: View {
  @FocusState.Binding var searchFocused: Bool

  @Environment(AppState.self) private var appState
  @Environment(ModifierFlags.self) private var modifierFlags
  @Environment(\.layoutDirection) private var layoutDirection
  @Environment(\.scenePhase) private var scenePhase

  @Default(.imageMaxHeight) private var imageMaxHeight
  @Default(.pinTo) private var pinTo
  @Default(.showApplicationIcons) private var showApplicationIcons
  @Default(.showFooter) private var showFooter

  private var pinnedItems: [HistoryItemDecorator] {
    appState.history.pinnedItems
  }

  private var pinsVisible: Bool {
    !pinnedItems.isEmpty
  }

  private var pasteStackVisible: Bool {
    guard let stack = appState.history.pasteStack else { return false }
    return !stack.items.isEmpty
  }

  private var regularItemHeight: CGFloat {
    ListItemMetrics.minimumHeight(
      showsApplicationIcon: showApplicationIcons
    )
  }

  private var imageItemHeight: CGFloat {
    max(
      regularItemHeight,
      CGFloat(imageMaxHeight)
        + 2 * ListItemMetrics.verticalContentPadding
    )
  }

  private var topPadding: CGFloat {
    Popup.verticalSeparatorPadding
  }

  private var bottomPadding: CGFloat {
    showFooter
      ? Popup.verticalSeparatorPadding
      : (Popup.verticalSeparatorPadding - 1)
  }

  private func rowHeight(
    for item: HistoryItemDecorator
  ) -> CGFloat {
    item.hasImage ? imageItemHeight : regularItemHeight
  }

  private func contentHeight(
    topPadding: CGFloat,
    bottomPadding: CGFloat
  ) -> CGFloat {
    appState.history.unpinnedItems.pageLayoutSummaries.reduce(
      topPadding + bottomPadding
    ) {
      $0 + $1.height(
        regularItemHeight: regularItemHeight,
        imageItemHeight: imageItemHeight
      )
    }
  }

  private func topSeparator() -> some View {
    Divider()
      .padding(.horizontal, Popup.horizontalSeparatorPadding)
      .padding(.top, Popup.verticalSeparatorPadding)
  }

  @ViewBuilder
  private func bottomSeparator() -> some View {
    Divider()
      .padding(.horizontal, Popup.horizontalSeparatorPadding)
      .padding(.bottom, Popup.verticalSeparatorPadding)
  }

  @ViewBuilder
  private func separator() -> some View {
    Divider()
      .padding(.horizontal, Popup.horizontalSeparatorPadding)
      .padding(.vertical, Popup.verticalSeparatorPadding)
  }

  var body: some View {
    let topPinsVisible = pinTo == .top && pinsVisible
    let bottomPinsVisible = pinTo == .bottom && pinsVisible
    let topSeparatorVisible = topPinsVisible || pasteStackVisible
    let bottomSeparatorVisible = bottomPinsVisible
    let scrollTopPadding = topSeparatorVisible
      ? Popup.verticalSeparatorPadding
      : topPadding
    let scrollBottomPadding = bottomSeparatorVisible
      ? Popup.verticalSeparatorPadding
      : bottomPadding
    let scrollRequest = appState.navigator.scrollRequest
    let scrollContentHeight = contentHeight(
      topPadding: scrollTopPadding,
      bottomPadding: scrollBottomPadding
    )

    VStack(spacing: 0) {
      if let stack = appState.history.pasteStack,
         !stack.items.isEmpty {
        PasteStackView(stack: stack)

        if topPinsVisible {
          separator()
        }
      }

      if topPinsVisible {
        PinsView(items: pinnedItems)
      }

      if topSeparatorVisible {
        topSeparator()
      }
    }
    .padding(.top, topSeparatorVisible ? topPadding : 0)
    .readHeight(appState, into: \.popup.extraTopHeight)
    .onChange(of: appState.popup.extraTopHeight) {
      appState.popup.needsResize = true
    }

    PagedHistoryScrollView(
      historyItems: appState.history.unpinnedItems,
      regularItemHeight: regularItemHeight,
      imageItemHeight: imageItemHeight,
      rowHeightProvider: rowHeight(for:),
      scrollTargetModelID: scrollRequest?.modelID,
      scrollRequestID: scrollRequest?.requestID,
      contentInsets: EdgeInsets(
        top: scrollTopPadding,
        leading: 0,
        bottom: scrollBottomPadding,
        trailing: 0
      ),
      scrollIndicatorInsets: EdgeInsets(
        top: scrollTopPadding,
        leading: 10,
        bottom: scrollBottomPadding,
        trailing: 0
      )
    ) { page in
      MultipleSelectionListView(
        items: page.items,
        itemBeforeFirst: page.previousItem,
        itemAfterLast: page.nextItem
      ) { previous, item, next in
        HistoryItemView(
          item: item,
          previous: previous,
          next: next
        )
        .frame(height: rowHeight(for: item))
      }
      // NSHostingView starts a new SwiftUI root for each recycled page.
      .environment(appState)
      .environment(modifierFlags)
      .environment(\.layoutDirection, layoutDirection)
    }
    .task(id: scrollContentHeight) {
      try? await Task.sleep(for: .milliseconds(10))
      guard !Task.isCancelled else { return }
      appState.popup.resize(height: scrollContentHeight)
    }
    .task(id: appState.popup.needsResize) {
      guard appState.popup.needsResize else { return }
      try? await Task.sleep(for: .milliseconds(10))
      guard !Task.isCancelled else { return }
      appState.popup.resize(height: scrollContentHeight)
    }
    .onChange(of: scenePhase) {
      if scenePhase == .active {
        searchFocused = true
        appState.navigator.isKeyboardNavigating = true
        appState.navigator.highlightFirstUnpinned()
        appState.preview.enableAutoOpen()
        appState.preview.resetAutoOpenSuppression()
        appState.preview.startAutoOpen()
      } else {
        modifierFlags.flags = []
        appState.navigator.isKeyboardNavigating = true
        appState.preview.cancelAutoOpen()
      }
    }

    VStack(spacing: 0) {
      if bottomSeparatorVisible {
        bottomSeparator()
      }

      if bottomPinsVisible {
        PinsView(items: pinnedItems)
      }
    }
    .padding(.bottom, bottomSeparatorVisible ? bottomPadding : 0)
    .readHeight(appState, into: \.popup.extraBottomHeight)
    .onChange(of: appState.popup.extraBottomHeight) {
      appState.popup.needsResize = true
    }
  }
}
