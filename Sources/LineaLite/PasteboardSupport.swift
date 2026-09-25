import AppKit
import ApplicationServices

@MainActor
func focusedFieldSubrole() -> String? {
  guard let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
  let app = AXUIElementCreateApplication(processID)
  AXUIElementSetMessagingTimeout(app, 0.15)
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
        let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
  let element = unsafeBitCast(value, to: AXUIElement.self)
  AXUIElementSetMessagingTimeout(element, 0.15)
  var subrole: CFTypeRef?
  AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
  return subrole as? String
}

func automaticPasteBlockReason(
  allowInsertion: Bool, accessibilityTrusted: Bool, modifiers: NSEvent.ModifierFlags,
  secureInput: Bool, focusedSubrole: String?
) -> String? {
  guard allowInsertion else { return "retry-copy-only" }
  guard accessibilityTrusted else { return "accessibility-not-trusted" }
  guard !secureInput, focusedSubrole != kAXSecureTextFieldSubrole as String else { return "secure-field" }
  guard modifiers.intersection([.command, .control, .option, .shift]).isEmpty else {
    return "modifiers-still-held"
  }
  // Some editors expose no AX focus at all. Paste follows the live keyboard focus.
  return nil
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

@MainActor
final class DictationPasteboard {
  private var original: PasteboardSnapshot?
  private var lastChangeCount: Int?

  func write(_ text: String, to pasteboard: NSPasteboard) -> Int? {
    if lastChangeCount != pasteboard.changeCount {
      original = PasteboardSnapshot(pasteboard: pasteboard)
    }
    let count = setPasteboardText(text, on: pasteboard)
    guard let count else {
      original?.restore(to: pasteboard, ifUnchangedSince: pasteboard.changeCount)
      original = nil
      lastChangeCount = nil
      return nil
    }
    lastChangeCount = count
    return count
  }

  func restore(_ pasteboard: NSPasteboard, after count: Int) {
    guard lastChangeCount == count else { return }
    original?.restore(to: pasteboard, ifUnchangedSince: count)
    original = nil
    lastChangeCount = nil
  }

  func keepCopiedText() {
    original = nil
    lastChangeCount = nil
  }
}

func setPasteboardText(_ text: String, on pasteboard: NSPasteboard) -> Int? {
  pasteboard.clearContents()
  guard pasteboard.setString(text, forType: .string) else { return nil }
  return pasteboard.changeCount
}
