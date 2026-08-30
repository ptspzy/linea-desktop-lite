import AppKit

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
