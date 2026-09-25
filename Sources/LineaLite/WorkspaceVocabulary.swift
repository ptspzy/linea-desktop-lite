import Foundation

struct WorkspaceVocabularyEntry: Codable, Hashable {
  let canonical: String
  let aliases: [String]

  private enum CodingKeys: String, CodingKey {
    case canonical
    case aliases
  }

  init(canonical: String, aliases: [String] = []) {
    self.canonical = canonical
    self.aliases = aliases
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    canonical = try container.decode(String.self, forKey: .canonical)
    aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
  }
}

let defaultDeveloperVocabulary = [
  WorkspaceVocabularyEntry(
    canonical: "Qwen3-ASR",
    aliases: ["坤三 A S R", "坤三ASR", "鲲三 A S R", "鲲三ASR", "千问三 A S R", "千问三 ASR", "千问三ASR"]
  ),
  WorkspaceVocabularyEntry(canonical: "0.6B", aliases: ["零点六 B", "零点六B"]),
  WorkspaceVocabularyEntry(canonical: "4-bit", aliases: ["四 bit", "四bit", "4 bit"]),
  WorkspaceVocabularyEntry(canonical: "MLX", aliases: ["M L X"]),
]

// Recognition hints must not lowercase common English words during text replacement.
let defaultRecognitionHotwords = defaultDeveloperVocabulary.map(\.canonical)
  + ["dev", "develop", "release", "hotfix", "feature", "bugfix"]

private struct WorkspaceVocabularyFile: Codable {
  let terms: [WorkspaceVocabularyEntry]
}

let defaultPersonalVocabularyURL = FileManager.default
  .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  .appendingPathComponent("Linea Lite/personal-vocabulary.json")

private let personalVocabularyWriteLock = NSLock()

enum PersonalVocabularyError: LocalizedError {
  case invalidCorrection

  var errorDescription: String? {
    "Enter a mistaken term and a different correction, each 2-128 characters without sentence punctuation or line breaks."
  }
}

func loadPersonalVocabulary(
  from url: URL = defaultPersonalVocabularyURL
) throws -> [WorkspaceVocabularyEntry] {
  guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
  let data: Data
  do {
    data = try Data(contentsOf: url)
  } catch CocoaError.fileReadNoSuchFile {
    return []
  }
  let entries = try JSONDecoder().decode(WorkspaceVocabularyFile.self, from: data).terms
  guard entries.allSatisfy({ entry in
    validPersonalVocabularyTerm(entry.canonical)
      && entry.aliases.allSatisfy(validPersonalVocabularyTerm)
  }) else { throw CocoaError(.fileReadCorruptFile) }
  return mergedVocabularyEntries(entries)
}

@discardableResult
func savePersonalVocabularyCorrection(
  alias: String,
  canonical: String,
  to url: URL = defaultPersonalVocabularyURL
) throws -> [WorkspaceVocabularyEntry] {
  let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
  let canonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
  guard url.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
  guard validPersonalVocabularyTerm(alias), validPersonalVocabularyTerm(canonical),
        alias != canonical else { throw PersonalVocabularyError.invalidCorrection }

  personalVocabularyWriteLock.lock()
  defer { personalVocabularyWriteLock.unlock() }
  // Only explicit mistake pairs are learned; never infer aliases from an edited sentence.
  var entries = try loadPersonalVocabulary(from: url).map { entry in
    WorkspaceVocabularyEntry(
      canonical: entry.canonical.caseInsensitiveCompare(canonical) == .orderedSame
        ? canonical : entry.canonical,
      aliases: entry.aliases.filter { $0.caseInsensitiveCompare(alias) != .orderedSame }
    )
  }
  entries.append(WorkspaceVocabularyEntry(canonical: canonical, aliases: [alias]))
  entries = mergedVocabularyEntries(entries)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  let data = try encoder.encode(WorkspaceVocabularyFile(terms: entries))
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
  )
  try data.write(to: url, options: .atomic)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  return entries
}

private func validPersonalVocabularyTerm(_ value: String) -> Bool {
  (2...128).contains(value.count)
    && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    && value.rangeOfCharacter(from: .controlCharacters) == nil
    && value.rangeOfCharacter(from: CharacterSet(charactersIn: "。！？!?；;")) == nil
}

func loadWorkspaceVocabulary(from workspaceURL: URL) throws -> [WorkspaceVocabularyEntry] {
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: workspaceURL.path, isDirectory: &isDirectory),
        isDirectory.boolValue else {
    throw CocoaError(.fileNoSuchFile)
  }
  var entries = [WorkspaceVocabularyEntry(canonical: workspaceURL.lastPathComponent)]
  for (manifest, dependencyKeys) in [
    ("package.json", ["dependencies", "devDependencies"]),
    ("composer.json", ["require", "require-dev"]),
  ] {
    guard let data = try? Data(contentsOf: workspaceURL.appendingPathComponent(manifest)),
          let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { continue }
    if let name = package["name"] as? String {
      entries.append(WorkspaceVocabularyEntry(canonical: name))
    }
    for key in dependencyKeys {
      if let dependencies = package[key] as? [String: Any] {
        entries += dependencies.keys
          .filter { manifest != "composer.json" || $0.contains("/") }
          .map { WorkspaceVocabularyEntry(canonical: $0) }
      }
    }
  }

  let vocabularyURL = workspaceURL.appendingPathComponent(".linea-vocabulary.json")
  if FileManager.default.fileExists(atPath: vocabularyURL.path) {
    entries += try JSONDecoder().decode(
      WorkspaceVocabularyFile.self,
      from: Data(contentsOf: vocabularyURL)
    ).terms
  }

  return mergedVocabularyEntries(entries)
}

// Read refs through Git so packed refs and linked worktrees work without scanning source files.
func workspaceBranchHotwords(from workspaceURL: URL) -> [String] {
  guard workspaceURL.isFileURL else { return [] }
  let base = ["--no-optional-locks", "-C", workspaceURL.path]
  let git = URL(fileURLWithPath: "/usr/bin/git")
  let current = (try? processOutput(executableURL: git,
    arguments: base + ["symbolic-ref", "--quiet", "--short", "HEAD"], timeout: 2)) ?? ""
  let recent = (try? processOutput(executableURL: git,
    arguments: base + ["for-each-ref", "--count=24", "--sort=-committerdate",
      "--format=%(refname:strip=2)", "refs/heads/"], timeout: 2)) ?? ""
  var seen = Set<String>()
  return (current + "\n" + recent).split(whereSeparator: \.isNewline).map(String.init).filter {
    (2...128).contains($0.count) && seen.insert($0).inserted
  }
}

private func mergedVocabularyEntries(
  _ entries: [WorkspaceVocabularyEntry]
) -> [WorkspaceVocabularyEntry] {
  var merged: [String: WorkspaceVocabularyEntry] = [:]
  for entry in entries {
    let canonical = entry.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (2...128).contains(canonical.count),
          canonical.rangeOfCharacter(from: .controlCharacters) == nil else { continue }
    let aliases = entry.aliases
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter {
        !$0.isEmpty && $0.count <= 128 && $0.rangeOfCharacter(from: .controlCharacters) == nil
      }
    let key = canonical.lowercased()
    let existing = merged[key]
    merged[key] = WorkspaceVocabularyEntry(
      canonical: existing?.canonical ?? canonical,
      aliases: Array(Set((existing?.aliases ?? []) + aliases)).sorted()
    )
  }
  return merged.values.sorted { $0.canonical.localizedCaseInsensitiveCompare($1.canonical) == .orderedAscending }
}

func applyWorkspaceVocabulary(
  to value: String,
  entries: [WorkspaceVocabularyEntry]
) -> String {
  // Later sources (for example personal corrections) override earlier aliases on a tie.
  let entries = entries.reversed().flatMap { mergedVocabularyEntries([$0]) }
  let replacements = entries.flatMap { entry in
    entry.aliases.map { ($0, entry.canonical) }
  } + entries.map { ($0.canonical, $0.canonical) }
  var matches: [(range: Range<String.Index>, canonical: String, priority: Int)] = []
  for (priority, replacement) in replacements.enumerated() {
    let (term, canonical) = replacement
    var searchStart = value.startIndex
    while searchStart < value.endIndex,
          let range = value.range(
            of: term, options: [.caseInsensitive], range: searchStart..<value.endIndex
          ) {
      let leftIsClear = range.lowerBound == value.startIndex
        || !isVocabularyWordCharacter(value[value.index(before: range.lowerBound)])
        || isVocabularyIdeograph(term.first!)
      let rightIsClear = range.upperBound == value.endIndex
        || !isVocabularyWordCharacter(value[range.upperBound])
        || isVocabularyIdeograph(term.last!)
      if leftIsClear, rightIsClear { matches.append((range, canonical, priority)) }
      searchStart = value.index(after: range.lowerBound)
    }
  }
  matches.sort {
    if $0.range.lowerBound != $1.range.lowerBound { return $0.range.lowerBound < $1.range.lowerBound }
    if $0.range.upperBound != $1.range.upperBound { return $0.range.upperBound > $1.range.upperBound }
    return $0.priority < $1.priority
  }
  // Match the original input once so replacement text cannot trigger another alias.
  var output = ""
  var cursor = value.startIndex
  for match in matches where match.range.lowerBound >= cursor {
    output += value[cursor..<match.range.lowerBound] + match.canonical
    cursor = match.range.upperBound
  }
  output += value[cursor...]
  return output
}

private func isVocabularyWordCharacter(_ character: Character) -> Bool {
  // Han aliases also occur directly beside Chinese prose, without word separators.
  character == "_" || ((character.isLetter || character.isNumber)
    && !isVocabularyIdeograph(character))
}

private func isVocabularyIdeograph(_ character: Character) -> Bool {
  character.unicodeScalars.contains { $0.properties.isIdeographic }
}
