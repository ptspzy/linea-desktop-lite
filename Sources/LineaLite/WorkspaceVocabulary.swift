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

private struct WorkspaceVocabularyFile: Decodable {
  let terms: [WorkspaceVocabularyEntry]
}

func loadWorkspaceVocabulary(from workspaceURL: URL) throws -> [WorkspaceVocabularyEntry] {
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: workspaceURL.path, isDirectory: &isDirectory),
        isDirectory.boolValue else {
    throw CocoaError(.fileNoSuchFile)
  }
  var entries = [WorkspaceVocabularyEntry(canonical: workspaceURL.lastPathComponent)]
  let packageURL = workspaceURL.appendingPathComponent("package.json")
  if let data = try? Data(contentsOf: packageURL),
     let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    if let name = package["name"] as? String {
      entries.append(WorkspaceVocabularyEntry(canonical: name))
    }
    for key in ["dependencies", "devDependencies"] {
      if let dependencies = package[key] as? [String: Any] {
        entries += dependencies.keys.map { WorkspaceVocabularyEntry(canonical: $0) }
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

  var merged: [String: WorkspaceVocabularyEntry] = [:]
  for entry in entries {
    let canonical = entry.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (2...128).contains(canonical.count) else { continue }
    let aliases = entry.aliases
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && $0.count <= 128 }
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
  let replacements = entries.flatMap { entry in
    ([entry.canonical] + entry.aliases).map { ($0, entry.canonical) }
  }.sorted { $0.0.count > $1.0.count }

  return replacements.reduce(value) { text, replacement in
    replacingVocabularyTerm(in: text, term: replacement.0, with: replacement.1)
  }
}

private func replacingVocabularyTerm(in value: String, term: String, with canonical: String) -> String {
  var output = value
  var searchStart = output.startIndex
  while searchStart < output.endIndex,
        let range = output.range(
          of: term,
          options: [.caseInsensitive],
          range: searchStart..<output.endIndex
        ) {
    let leftIsClear = range.lowerBound == output.startIndex
      || !isVocabularyWordCharacter(output[output.index(before: range.lowerBound)])
      || !isVocabularyWordCharacter(term.first!)
    let rightIsClear = range.upperBound == output.endIndex
      || !isVocabularyWordCharacter(output[range.upperBound])
      || !isVocabularyWordCharacter(term.last!)
    guard leftIsClear, rightIsClear else {
      searchStart = range.upperBound
      continue
    }
    let startOffset = output.distance(from: output.startIndex, to: range.lowerBound)
    output.replaceSubrange(range, with: canonical)
    searchStart = output.index(output.startIndex, offsetBy: startOffset + canonical.count)
  }
  return output
}

private func isVocabularyWordCharacter(_ character: Character) -> Bool {
  character == "_" || (character.isASCII && character.isLetter) || character.isNumber
}
