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

func filteredHistoryEntries(_ entries: [HistoryEntry], query: String) -> [HistoryEntry] {
  let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !query.isEmpty else { return entries }
  return entries.filter {
    $0.text.localizedCaseInsensitiveContains(query)
      || ($0.appName?.localizedCaseInsensitiveContains(query) ?? false)
  }
}

final class HistoryStore {
  private let url: URL
  private let limit: Int
  private var needsRecovery = false
  private(set) var entries: [HistoryEntry]
  private(set) var retention: HistoryRetention
  private(set) var recoveredCorruptFileURL: URL?

  init(url: URL = HistoryStore.defaultURL, limit: Int = 500) {
    self.url = url
    self.limit = max(1, limit)
    retention = .keep500
    do {
      let archive = try Self.load(from: url)
      entries = archive.entries
      retention = archive.retention
    } catch {
      entries = []
      do {
        recoveredCorruptFileURL = try Self.preserveCorruptHistory(at: url)
      } catch {
        needsRecovery = true
      }
    }
    entries.sort { $0.createdAt > $1.createdAt }
  }

  @discardableResult
  func append(_ entry: HistoryEntry, now: Date = Date()) -> Bool {
    persist(retained(entries + [entry], policy: retention, now: now), retention: retention)
  }

  @discardableResult
  func delete(id: String) -> Bool {
    guard entries.contains(where: { $0.id == id }) else { return false }
    return persist(entries.filter { $0.id != id }, retention: retention)
  }

  @discardableResult
  func update(id: String, text: String) -> Bool {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let index = entries.firstIndex(where: { $0.id == id }) else { return false }
    var updated = entries
    let entry = entries[index]
    updated[index] = HistoryEntry(
      id: entry.id, createdAt: entry.createdAt, text: text,
      duration: entry.duration, appName: entry.appName
    )
    return persist(updated, retention: retention)
  }

  @discardableResult
  func setRetention(_ retention: HistoryRetention, now: Date = Date()) -> Bool {
    persist(retained(entries, policy: retention, now: now), retention: retention)
  }

  @discardableResult
  func applyRetention(now: Date = Date()) -> Bool {
    let retained = retained(entries, policy: retention, now: now)
    guard retained != entries else { return true }
    return persist(retained, retention: retention)
  }

  @discardableResult
  func clear() -> Bool {
    persist([], retention: retention)
  }

  @discardableResult
  func clearAll() -> Bool {
    guard clear() else { return false }
    do {
      let files = try FileManager.default.contentsOfDirectory(
        at: url.deletingLastPathComponent(), includingPropertiesForKeys: [.isRegularFileKey]
      )
      let prefix = Self.backupPrefix(for: url)
      for file in files where file.lastPathComponent.hasPrefix(prefix) && file.pathExtension == "json" {
        let identifier = String(file.deletingPathExtension().lastPathComponent.dropFirst(prefix.count))
        guard UUID(uuidString: identifier) != nil,
              try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        try FileManager.default.removeItem(at: file)
        if recoveredCorruptFileURL?.lastPathComponent == file.lastPathComponent {
          recoveredCorruptFileURL = nil
        }
      }
      return true
    } catch {
      return false
    }
  }

  private func retained(
    _ entries: [HistoryEntry], policy: HistoryRetention, now: Date
  ) -> [HistoryEntry] {
    let cutoff = policy.days.flatMap {
      Calendar.current.date(byAdding: .day, value: 1 - $0, to: Calendar.current.startOfDay(for: now))
    }
    return Array(entries.filter { entry in cutoff.map { entry.createdAt >= $0 } ?? true }
      .sorted { $0.createdAt > $1.createdAt }.prefix(limit))
  }

  private func persist(_ updated: [HistoryEntry], retention: HistoryRetention) -> Bool {
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .millisecondsSince1970
      let data = try encoder.encode(HistoryArchive(entries: updated, retention: retention))
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if needsRecovery {
        if FileManager.default.fileExists(atPath: url.path) {
          recoveredCorruptFileURL = try Self.preserveCorruptHistory(at: url)
        }
        needsRecovery = false
      }
      let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(".history-\(UUID().uuidString).tmp")
      defer { try? FileManager.default.removeItem(at: temporaryURL) }
      guard FileManager.default.createFile(
        atPath: temporaryURL.path, contents: data, attributes: [.posixPermissions: 0o600]
      ) else { return false }
      if FileManager.default.fileExists(atPath: url.path) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL, options: .usingNewMetadataOnly)
      } else {
        try FileManager.default.moveItem(at: temporaryURL, to: url)
      }
      entries = updated
      self.retention = retention
      return true
    } catch {
      return false
    }
  }

  private struct HistoryArchive: Codable {
    let entries: [HistoryEntry]
    let retention: HistoryRetention
  }

  private static func load(from url: URL) throws -> HistoryArchive {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return HistoryArchive(entries: [], retention: .keep500)
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let data = try Data(contentsOf: url)
    if let legacy = try? decoder.decode([HistoryEntry].self, from: data) {
      return HistoryArchive(entries: legacy, retention: .keep500)
    }
    return try decoder.decode(HistoryArchive.self, from: data)
  }

  private static func backupPrefix(for url: URL) -> String {
    "\(url.deletingPathExtension().lastPathComponent)-corrupt-"
  }

  private static func preserveCorruptHistory(at url: URL) throws -> URL {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw CocoaError(.fileReadUnknown)
    }
    let backupURL = url.deletingLastPathComponent().appendingPathComponent(
      "\(backupPrefix(for: url))\(UUID().uuidString).json"
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    try FileManager.default.moveItem(at: url, to: backupURL)
    return backupURL
  }

  private static let defaultURL = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Linea Lite", isDirectory: true)
    .appendingPathComponent("history.json")
}

enum HistoryRetention: Int, Codable, CaseIterable {
  case keep500 = 0
  case days7 = 7
  case days30 = 30
  case days90 = 90

  var days: Int? { self == .keep500 ? nil : rawValue }

  var title: String {
    self == .keep500 ? "保留最近 500 条（默认）" : "保留最近 \(rawValue) 天（最多 500 条）"
  }
}
