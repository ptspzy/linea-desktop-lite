import Foundation

func runHistoryRegressionTests() throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("linea-history-regression-\(UUID().uuidString)")
  try fm.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: root) }
  let now = Date(timeIntervalSince1970: 1_783_000_000)
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .millisecondsSince1970
  let old = HistoryEntry(id: "old", createdAt: now.addingTimeInterval(-400 * 86_400), text: "old", duration: 1, appName: nil)
  let first = HistoryEntry(id: "first", createdAt: now, text: "first", duration: 2, appName: "TextEdit")
  let second = HistoryEntry(id: "second", createdAt: now.addingTimeInterval(-1), text: "second", duration: 3, appName: "Notes")
  let original = [first, second, old]
  let url = root.appendingPathComponent("legacy.json")
  let legacyData = try encoder.encode([old, first, second])
  try legacyData.write(to: url)
  let store = HistoryStore(url: url, limit: 2)
  precondition(store.entries == original && store.retention == .keep500)
  let untouchedData = try Data(contentsOf: url)
  precondition(untouchedData == legacyData, "Loading must not rewrite or prune legacy history")
  precondition(store.update(id: second.id, text: "corrected"))
  let corrected = HistoryEntry(id: second.id, createdAt: second.createdAt, text: "corrected", duration: second.duration, appName: second.appName)
  precondition(store.entries == [first, corrected, old], "Correction must preserve metadata and unrelated records")
  precondition(HistoryStore(url: url).entries == store.entries)
  let permissions = try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
  precondition(permissions?.intValue == 0o600)
  let beforeInvalid = try Data(contentsOf: url)
  precondition(!store.update(id: second.id, text: " \n "))
  precondition(!store.update(id: "missing", text: "no"))
  precondition(!store.delete(id: "missing"))
  let afterInvalid = try Data(contentsOf: url)
  precondition(beforeInvalid == afterInvalid)
  precondition(store.delete(id: second.id))
  precondition(store.entries == [first, old])
  precondition(HistoryStore(url: url).entries == [first, old])

  let cappedURL = root.appendingPathComponent("capped.json")
  let cappedEntries = (1...500).map {
    HistoryEntry(id: "cap-\($0)", createdAt: now.addingTimeInterval(-Double($0)), text: "entry", duration: 1, appName: nil)
  }
  try encoder.encode(cappedEntries).write(to: cappedURL)
  let capped = HistoryStore(url: cappedURL)
  precondition(capped.append(first, now: now))
  precondition(capped.entries.count == 500 && capped.entries.first == first)
  precondition(!capped.entries.contains(where: { $0.id == "cap-500" }))

  for policy in [HistoryRetention.days7, .days30, .days90] {
    let policyURL = root.appendingPathComponent("retention-\(policy.rawValue).json")
    let cutoff = Calendar.current.date(byAdding: .day, value: 1 - policy.rawValue, to: Calendar.current.startOfDay(for: now))!
    let boundary = HistoryEntry(id: "boundary", createdAt: cutoff, text: "boundary", duration: 1, appName: nil)
    let expired = HistoryEntry(id: "expired", createdAt: cutoff.addingTimeInterval(-1), text: "expired", duration: 1, appName: nil)
    try encoder.encode([expired, boundary, first]).write(to: policyURL)
    let policyStore = HistoryStore(url: policyURL)
    precondition(policyStore.entries.count == 3, "Default must not prune by age")
    precondition(policyStore.setRetention(policy, now: now))
    precondition(policyStore.entries == [first, boundary], "Retention includes its entire boundary day")
    let reloaded = HistoryStore(url: policyURL)
    precondition(reloaded.retention == policy && reloaded.entries == policyStore.entries)
    let later = Calendar.current.date(byAdding: .day, value: policy.rawValue + 1, to: now)!
    precondition(reloaded.applyRetention(now: later) && reloaded.entries.isEmpty)
    let fresh = HistoryEntry(createdAt: later, text: "fresh", duration: 1, appName: nil)
    precondition(reloaded.append(fresh, now: later) && reloaded.entries == [fresh])
    precondition(reloaded.setRetention(.keep500, now: later))
    precondition(HistoryStore(url: policyURL).retention == .keep500)
  }

  let writeDirectory = root.appendingPathComponent("write-failure")
  let writeURL = writeDirectory.appendingPathComponent("history.json")
  let retry = HistoryStore(url: writeURL)
  precondition(retry.append(first, now: now))
  let savedDirectory = root.appendingPathComponent("saved")
  try fm.moveItem(at: writeDirectory, to: savedDirectory)
  try Data("blocked".utf8).write(to: writeDirectory)
  precondition(!retry.append(second, now: now))
  precondition(!retry.update(id: first.id, text: "lost"))
  precondition(!retry.delete(id: first.id))
  precondition(!retry.setRetention(.days7, now: now))
  precondition(!retry.clearAll())
  precondition(retry.entries == [first] && retry.retention == .keep500)
  precondition(HistoryStore(url: savedDirectory.appendingPathComponent("history.json")).entries == [first])
  try fm.removeItem(at: writeDirectory)
  try fm.moveItem(at: savedDirectory, to: writeDirectory)
  precondition(retry.append(second, now: now), "A failed write must be retryable")
  let displacedFile = root.appendingPathComponent("displaced-history.json")
  try fm.moveItem(at: writeURL, to: displacedFile)
  try fm.createDirectory(at: writeURL, withIntermediateDirectories: true)
  let sentinel = writeURL.appendingPathComponent("unrelated.txt")
  try Data("unrelated".utf8).write(to: sentinel)
  precondition(!retry.update(id: first.id, text: "no"))
  precondition(fm.fileExists(atPath: sentinel.path) && retry.entries == [first, second])
  try fm.removeItem(at: writeURL)
  try fm.moveItem(at: displacedFile, to: writeURL)

  let corruptURL = root.appendingPathComponent("history.json")
  let corruptData = Data("not json: private dictation".utf8)
  try corruptData.write(to: corruptURL)
  let recovered = HistoryStore(url: corruptURL)
  guard let backup = recovered.recoveredCorruptFileURL else { preconditionFailure("Missing corrupt backup") }
  let backupData = try Data(contentsOf: backup)
  let backupPermissions = try fm.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber
  precondition(backupData == corruptData && backupPermissions?.intValue == 0o600)
  precondition(recovered.append(first, now: now))
  precondition(recovered.update(id: first.id, text: "revised"))
  precondition(recovered.delete(id: first.id))
  precondition(recovered.setRetention(.days7, now: now))
  precondition(recovered.clear())
  precondition(fm.fileExists(atPath: backup.path), "Ordinary operations must not remove recovery backups")
  let olderBackup = root.appendingPathComponent("history-corrupt-\(UUID().uuidString).json")
  let unrelated = root.appendingPathComponent("other-corrupt-\(UUID().uuidString).json")
  let similar = root.appendingPathComponent("history-corrupt-not-a-uuid.json")
  let directoryBackup = root.appendingPathComponent("history-corrupt-\(UUID().uuidString).json")
  for path in [olderBackup, unrelated, similar] { try corruptData.write(to: path) }
  try fm.createDirectory(at: directoryBackup, withIntermediateDirectories: true)
  precondition(recovered.clearAll())
  precondition(!fm.fileExists(atPath: backup.path) && !fm.fileExists(atPath: olderBackup.path))
  precondition(fm.fileExists(atPath: unrelated.path) && fm.fileExists(atPath: similar.path))
  precondition(fm.fileExists(atPath: directoryBackup.path))
  precondition(recovered.recoveredCorruptFileURL == nil && HistoryStore(url: corruptURL).entries.isEmpty)
  precondition(HistoryStore(url: corruptURL).retention == .days7)

  let blockedURL = root.appendingPathComponent("blocked.json")
  try fm.createDirectory(at: blockedURL, withIntermediateDirectories: true)
  let blocked = HistoryStore(url: blockedURL)
  precondition(!blocked.append(first, now: now), "Never replace an unexpected directory with history")
  try fm.removeItem(at: blockedURL)
  try corruptData.write(to: blockedURL)
  precondition(blocked.append(first, now: now), "Recovery must retry, not permanently disable saving")
  guard let retriedBackup = blocked.recoveredCorruptFileURL else { preconditionFailure("Missing retried backup") }
  let retriedData = try Data(contentsOf: retriedBackup)
  precondition(retriedData == corruptData && HistoryStore(url: blockedURL).entries == [first])

  let activity = historyActivity(entries: original, endingAt: now, days: 7, calendar: .current)
  precondition(activity.reduce(0) { $0 + $1.count } == 2)
  precondition(filteredHistoryEntries(original, query: " NOTES ") == [second])
  print("History regression tests passed")
}

#if HISTORY_MENU_REGRESSION
import AppKit

@MainActor
func runHistoryMenuRegressionTests(snapshotDirectory: URL) throws {
  _ = NSApplication.shared
  let clipboard = NSPasteboard(name: NSPasteboard.Name("linea-history-test-\(UUID().uuidString)"))
  let view = HistoryMenuView(pasteboard: clipboard)
  view.wantsLayer = true
  let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.intrinsicContentSize), styleMask: .borderless, backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = view
  defer { window.close() }
  let now = Date(timeIntervalSince1970: 1_783_000_000)
  let entries = (0..<500).map {
    HistoryEntry(id: "\($0)", createdAt: now.addingTimeInterval(-Double($0)), text: String(repeating: "这是一段用于检查长文本换行的转写内容。", count: 200), duration: 30, appName: "An application with a very long name")
  }
  var corrected: HistoryEntry?
  var deleted: HistoryEntry?
  view.onCorrect = { corrected = $0 }
  view.onDelete = { deleted = $0 }
  view.update(entries: entries, now: now)
  let scrollViews = view.subviews.compactMap { $0 as? NSScrollView }
  let table = scrollViews.compactMap { $0.documentView as? NSTableView }.first!
  let preview = scrollViews.compactMap { $0.documentView as? NSTextView }.first!
  let buttons = view.subviews.compactMap { $0 as? NSButton }
  let search = view.subviews.compactMap { $0 as? NSSearchField }.first!
  precondition(preview.string == entries[0].text && table.numberOfRows == 500)

  for (width, height) in [(320, 444), (380, 424), (392, 444), (400, 460)] {
    window.setContentSize(NSSize(width: width, height: height))
    view.needsLayout = true
    view.layoutSubtreeIfNeeded()
    let visible = view.subviews.filter { !$0.isHidden }
    for (index, child) in visible.enumerated() {
      precondition(view.bounds.contains(child.frame), "Out-of-bounds control at \(width): \(child)")
      for other in visible.dropFirst(index + 1) {
        precondition(!child.frame.intersects(other.frame), "Overlapping controls at \(width): \(child), \(other)")
      }
    }
    precondition(table.tableColumns.reduce(CGFloat(0)) { $0 + $1.width + table.intercellSpacing.width } <= table.enclosingScrollView!.contentSize.width + 1)
    let graph = view.subviews.compactMap { $0 as? HistoryActivityView }.first!
    precondition(graph.dayToolTip(at: NSPoint(x: 4, y: 6))?.contains("0 条") == true)
    let weekday = (Calendar.current.component(.weekday, from: now) - Calendar.current.firstWeekday + 7) % 7
    precondition(graph.dayToolTip(at: NSPoint(x: 139, y: 6 + weekday * 9))?.contains("500 条") == true)
    for label in graph.subviews { precondition(graph.bounds.contains(label.frame)) }
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      view.appearance = NSAppearance(named: appearance)
      view.effectiveAppearance.performAsCurrentDrawingAppearance {
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
      }
      view.needsDisplay = true
      view.displayIfNeeded()
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
      view.cacheDisplay(in: view.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])!.write(
        to: snapshotDirectory.appendingPathComponent("history-\(width)-\(appearance.rawValue).png")
      )
    }
  }
  table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
  view.update(entries: [HistoryEntry(id: "new", createdAt: now, text: "new", duration: 1, appName: nil)] + entries, now: now)
  precondition(table.selectedRow == 3 && preview.string == entries[2].text, "Updates must preserve the selected record by ID")
  buttons.first { $0.toolTip == "复制记录" }!.performClick(nil)
  precondition(clipboard.string(forType: .string) == entries[2].text, "Copy must preserve the full selected transcript")
  buttons.first { $0.toolTip == "纠正记录" }!.performClick(nil)
  buttons.first { $0.toolTip == "删除记录" }!.performClick(nil)
  precondition(corrected == entries[2] && deleted == entries[2])
  precondition(table.numberOfRows == 501 && table.selectedRow == 3, "Callbacks must not mutate selection or history")
  search.stringValue = "no matching entry"
  view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
  precondition(table.numberOfRows == 0 && preview.string.isEmpty && buttons.allSatisfy { !$0.isEnabled })
  view.update(entries: [], now: now)
  precondition(table.numberOfRows == 0 && preview.string.isEmpty)
  print("History menu regression tests passed; snapshots: \(snapshotDirectory.path)")
}
#endif

#if HISTORY_REGRESSION_STANDALONE
@main
enum HistoryRegressionRunner {
  @MainActor static func main() throws {
    try runHistoryRegressionTests()
    #if HISTORY_MENU_REGRESSION
    try runHistoryMenuRegressionTests(snapshotDirectory: URL(fileURLWithPath: CommandLine.arguments[1]))
    #endif
  }
}
#endif
