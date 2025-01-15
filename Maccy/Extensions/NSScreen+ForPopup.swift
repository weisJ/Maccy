import AppKit.NSScreen
import Defaults

extension NSScreen {
  static var forPopup: NSScreen? {
    var desiredScreen = Defaults[.popupScreen]
    if desiredScreen == -1 {
      desiredScreen = 1
    }
    if desiredScreen == 0 || desiredScreen > NSScreen.screens.count {
      return NSScreen.main
    } else {
      return NSScreen.screens[desiredScreen - 1]
    }
  }
}
