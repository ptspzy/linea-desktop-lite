import AppKit
import ApplicationServices

struct DictationTarget {
  let processID: pid_t
  let appName: String?
  private let element: AXUIElement?
  private let selection: CFTypeRef?

  @MainActor
  static func capture() -> DictationTarget? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let element = focusedElement(processID: app.processIdentifier)
    var selection: CFTypeRef?
    if let element {
      AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selection)
    }
    return DictationTarget(processID: app.processIdentifier, appName: app.localizedName,
                           element: element, selection: selection)
  }

  @MainActor
  var stillFocused: Bool {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
          let element, let current = Self.focusedElement(processID: processID),
          CFEqual(element, current) else { return false }
    var subrole: CFTypeRef?
    AXUIElementCopyAttributeValue(current, kAXSubroleAttribute as CFString, &subrole)
    guard subrole as? String != kAXSecureTextFieldSubrole as String else { return false }
    if let selection {
      var currentSelection: CFTypeRef?
      guard AXUIElementCopyAttributeValue(current, kAXSelectedTextRangeAttribute as CFString,
                                        &currentSelection) == .success,
            let currentSelection, CFEqual(selection, currentSelection) else { return false }
    }
    return true
  }

  private static func focusedElement(processID: pid_t) -> AXUIElement? {
    var value: CFTypeRef?
    let app = AXUIElementCreateApplication(processID)
    AXUIElementSetMessagingTimeout(app, 0.15)
    guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    let element = unsafeBitCast(value, to: AXUIElement.self)
    AXUIElementSetMessagingTimeout(element, 0.15)
    return element
  }
}

func canAutomaticallyPaste(targetIsFocused: Bool, modifiers: NSEvent.ModifierFlags) -> Bool {
  targetIsFocused && modifiers.intersection([.command, .control, .option, .shift]).isEmpty
}

struct PasteboardSnapshot {
  private let items: [[NSPasteboard.PasteboardType: Data]]

  init(pasteboard: NSPasteboard) {
    items = (pasteboard.pasteboardItems ?? []).map { item in
      Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
        item.data(forType: type).map { (type, $0) }
      })
    }
  }

  @discardableResult
  func restore(to pasteboard: NSPasteboard, ifUnchangedSince changeCount: Int) -> Bool {
    guard pasteboard.changeCount == changeCount else { return false }
    pasteboard.clearContents()
    guard !items.isEmpty else { return true }
    let pasteboardItems = items.map { values in
      let item = NSPasteboardItem()
      for (type, data) in values {
        item.setData(data, forType: type)
      }
      return item
    }
    return pasteboard.writeObjects(pasteboardItems)
  }
}

func setPasteboardText(_ text: String, on pasteboard: NSPasteboard) -> Int? {
  pasteboard.clearContents()
  guard pasteboard.setString(text, forType: .string) else { return nil }
  return pasteboard.changeCount
}
