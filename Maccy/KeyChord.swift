import AppKit.NSEvent
import KeyboardShortcuts
import Sauce

enum KeyChord: CaseIterable {
  static var pasteKey: Key { pasteMenuItem?.key ?? Key.v }
  static var pasteKeyModifiers: NSEvent.ModifierFlags { pasteMenuItem?.keyEquivalentModifierMask ?? .command }
  private static var pasteMenuItem: NSMenuItem? {
    NSApp.mainMenu?.items
      .flatMap { $0.submenu?.items ?? [] }
      .first { $0.action == #selector(NSText.paste) }
  }

  static var deleteKey: Key? { Sauce.shared.key(shortcut: .delete) }
  static var deleteModifiers: NSEvent.ModifierFlags? { KeyboardShortcuts.Shortcut(name: .delete)?.modifiers }

  static var pinKey: Key? { Sauce.shared.key(shortcut: .pin) }
  static var pinModifiers: NSEvent.ModifierFlags? { KeyboardShortcuts.Shortcut(name: .pin)?.modifiers }

  static var previewKey: Key? { Sauce.shared.key(shortcut: .togglePreview) }
  static var previewModifiers: NSEvent.ModifierFlags? { KeyboardShortcuts.Shortcut(name: .togglePreview)?.modifiers }

  case clearHistory
  case clearHistoryAll
  case clearSearch
  case deleteCurrentItem
  case deleteOneCharFromSearch
  case deleteLastWordFromSearch
  case ignored
  case moveToNext
  case moveToLast
  case moveToPrevious
  case moveToFirst
  case extendToNext
  case extendToLast
  case extendToPrevious
  case extendToFirst
  case openPreferences
  case pinOrUnpin
  case selectCurrentItem
  case close
  case togglePreview
  case unknown

  init(_ event: NSEvent?) {
    guard let event, event.type == .keyDown,
          let key = Sauce.shared.key(for: Int(event.keyCode)) else {
      self = .unknown
      return
    }

    self.init(
      key,
      event.modifierFlags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.capsLock, .numericPad, .function])
    )
  }

  init(_ key: Key, _ modifierFlags: NSEvent.ModifierFlags) { // swiftlint:disable:this cyclomatic_complexity
    switch (key, modifierFlags) {
    case (.delete, [.command, .option]):
      self = .clearHistory
    case (.delete, [.command, .option, .shift]):
      self = .clearHistoryAll
    case (.u, [.control]):
      self = .clearSearch
    case (KeyChord.deleteKey, KeyChord.deleteModifiers):
      self = .deleteCurrentItem
    case (.h, [.control]):
      self = .deleteOneCharFromSearch
    case (.w, [.control]):
      self = .deleteLastWordFromSearch
    case (.downArrow, [.shift]),
         (.n, [.control, .shift]):
      self = .extendToNext
    case (.downArrow, []),
         (.n, [.control]),
         (.j, [.control]):
      self = .moveToNext
    case (.downArrow, [.command, .shift]),
         (.downArrow, [.option, .shift]),
         (.n, [.control, .option, .shift]):
      self = .extendToLast
    case (.downArrow, _) where modifierFlags.contains(.command) || modifierFlags.contains(.option),
         (.n, [.control, .option]):
      self = .moveToLast
    case (.upArrow, [.shift]),
         (.p, [.control, .shift]):
      self = .extendToPrevious
    case (.upArrow, []),
         (.p, [.control]) ,
         (.k, [.control]):
      self = .moveToPrevious
    case (.upArrow, [.command, .shift]),
         (.upArrow, [.option, .shift]),
         (.p, [.control, .option, .shift]):
      self = .extendToFirst
    case (.upArrow, _) where modifierFlags.contains(.command) || modifierFlags.contains(.option),
         (.p, [.control, .option]):
      self = .moveToFirst
    case (KeyChord.pinKey, KeyChord.pinModifiers):
      self = .pinOrUnpin
    case (.comma, [.command]):
      self = .openPreferences
    case (.return, _),
         (.keypadEnter, _):
      self = .selectCurrentItem
    case (.escape, _):
      self = .close
    case (KeyChord.previewKey, KeyChord.previewModifiers):
      self = .togglePreview
    case (_, _) where !modifierFlags.isDisjoint(with: [.command, .control, .option]):
      self = .ignored
    default:
      self = .unknown
    }
  }
}
