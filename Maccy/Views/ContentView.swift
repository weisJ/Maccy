import SwiftData
import SwiftUI

struct PopoverView<Value, T: View>: NSViewRepresentable {
  @Binding private var item: Value?
  private let content: (Value?) -> T
  private var lastItem: Value? = nil

  init(item: Binding<Value?>, @ViewBuilder content: @escaping (Value?) -> T) {
    self._item = item
    self.content = content
  }

  func makeNSView(context: Context) -> NSView {
    return .init()
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    let coordinator = context.coordinator
    let currentItem = item
    coordinator.popover.contentViewController = NSHostingController(rootView: content(currentItem ?? coordinator.lastItem))
    coordinator.lastItem = currentItem
    coordinator.visibilityDidChange(currentItem != nil, in: nsView)
  }

  func makeCoordinator() -> Coordinator {
    let coordinator = Coordinator(popover: .init())
    coordinator.popover.contentViewController = NSHostingController(rootView: content(nil))
    return coordinator
  }

  @MainActor
  final class Coordinator: NSObject, NSPopoverDelegate {
    fileprivate let popover: NSPopover
    fileprivate var lastItem: Value? = nil
    var oldFrame: NSRect = .zero


    fileprivate init(popover: NSPopover) {
      self.popover = popover
      super.init()
      popover.delegate = self

      // Prevent NSPopover from becoming first responder.
      popover.behavior = .semitransient
    }

    fileprivate func visibilityDidChange(_ isVisible: Bool, in view: NSView) {
      if isVisible {
        if oldFrame == .zero {
          oldFrame = view.frame
        } else {
          view.frame = oldFrame
        }

        popover.show(relativeTo: .zero, of: view, preferredEdge: .maxX)
        // Ugly hack to hide the arrow
        view.frame = NSMakeRect(-1000, 0, 10, 10)

      } else if popover.isShown {
        popover.close()
      }
    }
  }
}


struct ContentView: View {
  @State private var appState = AppState.shared
  @State private var modifierFlags = ModifierFlags()
  @State private var scenePhase: ScenePhase = .background

  @FocusState private var searchFocused: Bool

  var body: some View {
    ZStack {
      VisualEffectView()

      VStack(alignment: .leading, spacing: 0) {
        KeyHandlingView(searchQuery: $appState.history.searchQuery, searchFocused: $searchFocused) {
          HeaderView(
            searchFocused: $searchFocused,
            searchQuery: $appState.history.searchQuery
          )

          HistoryListView(
            searchQuery: $appState.history.searchQuery,
            searchFocused: $searchFocused
          )

          FooterView(footer: appState.footer)
        }
      }
      .animation(.default.speed(3), value: appState.history.items)
      .animation(.easeInOut(duration: 0.2), value: appState.searchVisible)
      .padding(.horizontal, 5)
      .padding(.vertical, appState.popup.verticalPadding)
      .onAppear {
        searchFocused = true
      }
      .onMouseMove {
        appState.isKeyboardNavigating = false
      }
      .background {
        PopoverView(item: $appState.previewItem) { content in
          if let item = content {
            PreviewItemView(item: item)
          }
        }
      }
      .task {
        try? await appState.history.load()
      }
    }
    .environment(appState)
    .environment(modifierFlags)
    .environment(\.scenePhase, scenePhase)
    // FloatingPanel is not a scene, so let's implement custom scenePhase..
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
      if let window = $0.object as? NSWindow,
         let bundleIdentifier = Bundle.main.bundleIdentifier,
         window.identifier == NSUserInterfaceItemIdentifier(bundleIdentifier) {
        scenePhase = .active
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) {
      if let window = $0.object as? NSWindow,
         let bundleIdentifier = Bundle.main.bundleIdentifier,
         window.identifier == NSUserInterfaceItemIdentifier(bundleIdentifier) {
        scenePhase = .background
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) {
      if $0.object is NSPopover {
        appState.showPreview = false
      }
    }
  }
}

#Preview {
  ContentView()
    .environment(\.locale, .init(identifier: "en"))
    .modelContainer(Storage.shared.container)
}
