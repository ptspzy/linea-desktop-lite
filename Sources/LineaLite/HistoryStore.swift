import Foundation

struct HistoryEntry: Codable, Equatable {
  let id: String
  let createdAt: Date
  let text: String
  let duration: TimeInterval
  let appName: String?

  init(
    id: String = UUID().uuidString,
    createdAt: Date = Date(),
    text: String,
    duration: TimeInterval,
    appName: String?
  ) {
    self.id = id
    self.createdAt = createdAt
    self.text = text
    self.duration = duration
    self.appName = appName
  }
}

struct HistoryActivityDay: Equatable {
  let date: Date
  var count: Int
  var characters: Int
}

func historyActivity(
  entries: [HistoryEntry],
  endingAt endDate: Date,
  days: Int,
  calendar: Calendar
) -> [HistoryActivityDay] {
  guard days > 0 else { return [] }

  let end = calendar.startOfDay(for: endDate)
  let start = calendar.date(byAdding: .day, value: 1 - days, to: end)!
  var totals: [Date: (count: Int, characters: Int)] = [:]

  for entry in entries {
    let day = calendar.startOfDay(for: entry.createdAt)
    guard day >= start, day <= end else { continue }
    totals[day, default: (0, 0)].count += 1
    totals[day, default: (0, 0)].characters += entry.text.count
  }

  return (0..<days).map { offset in
    let date = calendar.date(byAdding: .day, value: offset, to: start)!
    let total = totals[date, default: (0, 0)]
    return HistoryActivityDay(date: date, count: total.count, characters: total.characters)
  }
}

func historyActivityLevel(characters: Int, maximum: Int) -> Int {
  guard characters > 0, maximum > 0 else { return 0 }
  return min(4, max(1, Int(ceil(Double(characters) / Double(maximum) * 4))))
}

final class HistoryStore {
  private let url: URL
  private let limit: Int
  private var canSave = true
  private(set) var entries: [HistoryEntry]
  private(set) var recoveredCorruptFileURL: URL?

  init(url: URL = HistoryStore.defaultURL, limit: Int = 500) {
    self.url = url
    self.limit = limit
    do {
      entries = try Self.load(from: url)
    } catch {
      entries = []
      do {
        recoveredCorruptFileURL = try Self.preserveCorruptHistory(at: url)
      } catch {
        canSave = false
      }
    }
    entries.sort { $0.createdAt > $1.createdAt }
    entries = Array(entries.prefix(limit))
  }

  @discardableResult
  func append(_ entry: HistoryEntry) -> Bool {
    let previous = entries
    entries.append(entry)
    entries.sort { $0.createdAt > $1.createdAt }
    entries = Array(entries.prefix(limit))
    guard save() else {
      entries = previous
      return false
    }
    return true
  }

  @discardableResult
  func clear() -> Bool {
    let previous = entries
    entries.removeAll()
    guard save() else {
      entries = previous
      return false
    }
    return true
  }

  private func save() -> Bool {
    guard canSave else { return false }
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .millisecondsSince1970
      try encoder.encode(entries).write(to: url, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      return true
    } catch {
      return false
    }
  }

  private static func load(from url: URL) throws -> [HistoryEntry] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try decoder.decode([HistoryEntry].self, from: Data(contentsOf: url))
  }

  private static func preserveCorruptHistory(at url: URL) throws -> URL {
    let backupURL = url.deletingLastPathComponent().appendingPathComponent(
      "history-corrupt-\(UUID().uuidString).json"
    )
    try FileManager.default.moveItem(at: url, to: backupURL)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
    return backupURL
  }

  private static let defaultURL = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Linea Lite", isDirectory: true)
    .appendingPathComponent("history.json")
}
