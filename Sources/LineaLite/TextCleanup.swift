import Foundation

private let semanticUnitExpression = try! NSRegularExpression(
  pattern: #"\p{Han}|[A-Za-z0-9]+(?:[._/-][A-Za-z0-9]+)*"#
)
private let punctuationSpacingExpression = try! NSRegularExpression(
  pattern: #"\s+([，。！？；：,.!?;:])"#
)
private let connectorExpression = try! NSRegularExpression(
  pattern: #"(?<![，。！？；：,.!?;:])\s+(然后|但是|不过|所以|而且|同时|接着|因此)\s*"#
)
private let paragraphCues = ["后续的话", "另外的话", "另一方面", "接下来", "另外", "最后"]
private let sentenceEndings: Set<Character> = ["。", "！", "？", ".", "!", "?"]

func cleanedTranscript(_ value: String) -> String {
  value
    .components(separatedBy: .whitespacesAndNewlines)
    .filter { !$0.isEmpty }
    .joined(separator: " ")
}

func formattedTranscript(_ value: String, paragraphBreaks: Bool = true) -> String {
  let cleaned = normalizedPunctuationSpacing(cleanedTranscript(value))
  guard !cleaned.isEmpty else { return "" }

  let sections = strongParagraphSections(cleaned)
  let formatted = sections
    .map(formatSentenceSequence)
    .joined(separator: paragraphBreaks && sections.count > 1 ? "\n\n" : "")
  return paragraphBreaks ? groupedLongParagraphs(formatted) : formatted
}

func paragraphFormattingAllowed(appName: String?) -> Bool {
  guard let name = appName?.lowercased() else { return true }
  return !["terminal", "iterm2", "warp", "alacritty", "kitty", "wezterm"].contains(name)
}

private func normalizedPunctuationSpacing(_ text: String) -> String {
  punctuationSpacingExpression.stringByReplacingMatches(
    in: text,
    range: NSRange(text.startIndex..., in: text),
    withTemplate: "$1"
  )
}

private func semanticUnitCount(_ text: String) -> Int {
  semanticUnitExpression.numberOfMatches(
    in: text,
    range: NSRange(text.startIndex..., in: text)
  )
}

private func strongParagraphSections(_ text: String) -> [String] {
  var sections: [String] = []
  var remainder = text

  while let range = firstValidParagraphCue(in: remainder) {
    sections.append(String(remainder[..<range.lowerBound]))
    remainder = String(remainder[range.lowerBound...])
  }
  sections.append(remainder)
  return sections
}

private func firstValidParagraphCue(in text: String) -> Range<String.Index>? {
  var searchStart = text.startIndex

  while searchStart < text.endIndex {
    let candidates = paragraphCues.compactMap {
      text.range(of: $0, range: searchStart..<text.endIndex)
    }
    guard let range = candidates.min(by: {
      $0.lowerBound < $1.lowerBound
        || ($0.lowerBound == $1.lowerBound
          && text.distance(from: $0.lowerBound, to: $0.upperBound)
            > text.distance(from: $1.lowerBound, to: $1.upperBound))
    }) else { return nil }

    let before = String(text[..<range.lowerBound])
    let after = String(text[range.lowerBound...])
    if semanticUnitCount(before) >= 8, semanticUnitCount(after) >= 8 {
      return range
    }
    searchStart = range.upperBound
  }
  return nil
}

private func formatSentenceSequence(_ value: String) -> String {
  var text = cleanedTranscript(value)
  text = connectorExpression.stringByReplacingMatches(
    in: text,
    range: NSRange(text.startIndex..., in: text),
    withTemplate: "，$1"
  )
  text = addLeadingCueComma(text)
  return addTerminalPunctuation(text)
}

private func addLeadingCueComma(_ text: String) -> String {
  for cue in paragraphCues where text.hasPrefix(cue) {
    let rawRest = text.dropFirst(cue.count)
    let rest = rawRest.trimmingCharacters(in: .whitespaces)
    guard !rest.isEmpty, !rest.hasPrefix("，"), !rest.hasPrefix(",") else { return text }
    guard cue.hasSuffix("的话") || cue == "另一方面" || rawRest.first?.isWhitespace == true else {
      return text
    }
    return "\(cue)，\(rest)"
  }
  return text
}

private func addTerminalPunctuation(_ text: String) -> String {
  guard let last = text.last, !sentenceEndings.contains(last), !"；;：:".contains(last) else {
    return text
  }

  let base = "，,、".contains(last) ? String(text.dropLast()) : text
  let questionCues = ["吗", "么", "呢", "为什么", "怎么样", "怎么办", "是什么", "有什么区别", "有什么不同"]
  if questionCues.contains(where: { base.hasSuffix($0) }) {
    return base + "？"
  }
  if base != text { return base + "。" }
  return semanticUnitCount(text) > 10 ? text + "。" : text
}

private func groupedLongParagraphs(_ text: String) -> String {
  if text.contains("\n\n") {
    return text.components(separatedBy: "\n\n")
      .map(groupedLongParagraphs)
      .joined(separator: "\n\n")
  }
  guard semanticUnitCount(text) >= 121 else { return text }
  let sentences = splitSentences(text)
  guard sentences.count > 1 else { return text }

  var paragraphs: [[String]] = []
  var current: [String] = []
  var currentUnits = 0
  for sentence in sentences {
    let units = semanticUnitCount(sentence)
    if !current.isEmpty, currentUnits + units > 85 {
      paragraphs.append(current)
      current = []
      currentUnits = 0
    }
    current.append(sentence)
    currentUnits += units
  }
  if !current.isEmpty { paragraphs.append(current) }

  if paragraphs.count > 1,
     paragraphs.last!.reduce(0, { $0 + semanticUnitCount($1) }) < 30,
     paragraphs[paragraphs.count - 2].count > 1 {
    let previousIndex = paragraphs.count - 2
    let candidate = paragraphs[previousIndex].last!
    let remaining = paragraphs[previousIndex].dropLast().reduce(0) { $0 + semanticUnitCount($1) }
    if remaining >= 30 {
      paragraphs[previousIndex].removeLast()
      paragraphs[paragraphs.count - 1].insert(candidate, at: 0)
    }
  }

  return paragraphs.map { $0.joined() }.joined(separator: "\n\n")
}

private func splitSentences(_ text: String) -> [String] {
  var sentences: [String] = []
  var current = ""
  for character in text {
    current.append(character)
    if sentenceEndings.contains(character) {
      sentences.append(current)
      current = ""
    }
  }
  if !current.isEmpty { sentences.append(current) }
  return sentences
}

struct SpeechResultAccumulator {
  private var latestNonEmpty = ""

  mutating func accept(text: String, isFinal: Bool) -> String? {
    let cleaned = cleanedTranscript(text)
    if !cleaned.isEmpty {
      latestNonEmpty = cleaned
    }
    return isFinal ? latestNonEmpty : nil
  }
}
