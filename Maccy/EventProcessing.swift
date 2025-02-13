import AppKit
import Carbon.HIToolbox
import Foundation

func dispatchAndWait(events: [CGEvent], at location: CGEventTapLocation) async throws {
  guard let lastEvent = events.last else {
    return
  }
  let manager = EventProcessingManager()
  try manager.setupEventTap(at: location, eventMask: CGEventMask(1 << lastEvent.type.rawValue))
  await manager.waitFor(events: events, withID: Int64.random(in: 0...Int64.max), at: location)
  print("Events processed")

}

fileprivate class EventProcessingManager {
  private static let expectedEventID: Int64 = 123_456_789
  private var continuation: CheckedContinuation<Void, Never>?
  private var expectedEventID: Int64?
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?

  func setupEventTap(at location: CGEventTapLocation, eventMask: CGEventMask) throws {
    // Event tap callback
    let callback: CGEventTapCallBack = { proxy, type, event, refcon in
      guard
        let expectedID = Unmanaged<EventProcessingManager>
          .fromOpaque(refcon!)
          .takeUnretainedValue()
          .expectedEventID
      else {
        return Unmanaged.passUnretained(event)
      }

      if event.getIntegerValueField(.eventSourceUserData) == expectedID {
        Unmanaged<EventProcessingManager>
          .fromOpaque(refcon!)
          .takeUnretainedValue()
          .handleProcessedEvent()
      }
      return Unmanaged.passUnretained(event)
    }

    // Create event tap
    eventTap = CGEvent.tapCreate(
      tap: location,
      place: .tailAppendEventTap,
      options: .defaultTap,
      eventsOfInterest: eventMask,
      callback: callback,
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    )

    guard let eventTap else {
      print("Could not create event Tap")
      throw NSError(domain: "EventTapError", code: 1, userInfo: nil)
    }

    runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)
  }

  private func handleProcessedEvent() {
    continuation?.resume()
    continuation = nil
    expectedEventID = nil
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
      self.eventTap = nil
    }
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
      self.runLoopSource = nil
    }
  }

  func waitFor(events: [CGEvent], withID eventID: Int64, at location: CGEventTapLocation) async {
    guard !events.isEmpty else { return }

    await withCheckedContinuation { cont in
      self.continuation = cont
      self.expectedEventID = eventID
      CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)

      for event in events.dropLast() {
        event.post(tap: location)
      }
      let markerEvent = events.last!
      markerEvent.setIntegerValueField(.eventSourceUserData, value: eventID)
      markerEvent.post(tap: location)
      print("Events posted with markerID: \(eventID)")
    }
  }

  func waitForEvent(withID eventID: Int64, at location: CGEventTapLocation) async {
    guard let markerEvent = CGEvent(source: nil) else {
      print("Failed to create marker event")
      return
    }
    markerEvent.type = .null
    await waitFor(events: [markerEvent], withID: eventID, at: location)
  }
}
