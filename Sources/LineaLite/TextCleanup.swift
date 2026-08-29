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
private let declaredListCountExpression = try! NSRegularExpression(
  pattern: #"([二两三四五六七八九十]|[2-9][0-9]*)\s*(?:种|个|项|点|条|类|份|组|步|方面|段)"#
)
private let inlineListMarkerExpression = try! NSRegularExpression(
  pattern: #"(?:^|[\s：:,，；;。.!！？?])([一二两三四五六七八九十]|[1-9][0-9]*)(?:[、.．)]?)\s*"#
)
private let spokenListMarkerExpression = try! NSRegularExpression(
  pattern: #"(?:^|[\s：:,，；;。.!！？?])((?:第)?([一二两三四五六七八九十]|[1-9][0-9]*)点是)[，,。.!！？?：:\s]*"#
)
private let compactThreeItemListExpression = try! NSRegularExpression(
  pattern: #"^(.*?有\s*(?:三|3)(?:种|个|项|点|条|类|份|组|步|方面|段)?)[：:.．]?\s*(?:一|1)[、.．)]?\s*(.+?)(?:二|2)[、.．)]?\s*(.+?)(?:三|3)[、.．)]?\s*(.+?)[。.!！？?]?$"#
)
private let paragraphCues = ["后续的话", "另外的话", "另一方面", "接下来", "另外", "最后"]
private let sentenceEndings: Set<Character> = ["。", "！", "？", ".", "!", "?"]
private let listTrimCharacters = CharacterSet.whitespacesAndNewlines.union(
  CharacterSet(charactersIn: "，,；;。.!！？?：:、")
)
private let chineseNumbers = [
  "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
  "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
]
private let measurementUnitInitials: Set<Character> = [
  "米", "厘", "元", "斤", "克", "秒", "分", "时", "年", "月", "日", "岁", "层", "楼", "度",
]

func cleanedTranscript(_ value: String) -> String {
  value
    .components(separatedBy: .whitespacesAndNewlines)
    .filter { !$0.isEmpty }
    .joined(separator: " ")
}

func formattedTranscript(_ value: String, paragraphBreaks: Bool = true) -> String {
  let cleaned = normalizedPunctuationSpacing(cleanedTranscript(value))
  guard !cleaned.isEmpty else { return "" }
  if paragraphBreaks, let list = formattedExplicitList(cleaned) { return list }

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

private func formattedExplicitList(_ text: String) -> String? {
  formattedInlineList(text) ?? formattedSpokenList(text) ?? formattedCompactThreeItemList(text)
}

private func formattedCompactThreeItemList(_ text: String) -> String? {
  guard let match = compactThreeItemListExpression.firstMatch(
    in: text,
    range: NSRange(text.startIndex..., in: text)
  ) else { return nil }

  let parts = (1...4).compactMap { index -> String? in
    guard let range = Range(match.range(at: index), in: text) else { return nil }
    return String(text[range]).trimmingCharacters(in: listTrimCharacters)
  }
  let itemInitials = parts.dropFirst().compactMap(\.first)
  guard parts.count == 4,
        parts.allSatisfy({ !$0.isEmpty }),
        !itemInitials.allSatisfy(measurementUnitInitials.contains) else { return nil }

  return parts[0] + "：\n" + parts.dropFirst().enumerated()
    .map { "\($0.offset + 1). \($0.element)" }
    .joined(separator: "\n")
}

private func formattedInlineList(_ text: String) -> String? {
  let fullRange = NSRange(text.startIndex..., in: text)
  let matches = inlineListMarkerExpression.matches(in: text, range: fullRange)
  guard matches.count >= 2,
        let firstRange = Range(matches[0].range, in: text) else { return nil }

  let heading = String(text[..<firstRange.lowerBound])
    .trimmingCharacters(in: listTrimCharacters)
  guard !heading.isEmpty,
        declaredListCount(in: heading) == matches.count else { return nil }

  let values = matches.compactMap { match -> Int? in
    guard let range = Range(match.range(at: 1), in: text) else { return nil }
    return numberValue(String(text[range]))
  }
  guard values == Array(1...matches.count) else { return nil }

  var items: [String] = []
  for (index, match) in matches.enumerated() {
    guard let markerRange = Range(match.range, in: text) else { return nil }
    let itemEnd = index + 1 < matches.count
      ? Range(matches[index + 1].range, in: text)!.lowerBound
      : text.endIndex
    let item = String(text[markerRange.upperBound..<itemEnd])
      .trimmingCharacters(in: listTrimCharacters)
    guard !item.isEmpty else { return nil }
    items.append(item)
  }

  return heading + "：\n" + items.enumerated()
    .map { "\($0.offset + 1). \($0.element)" }
    .joined(separator: "\n")
}

private func formattedSpokenList(_ text: String) -> String? {
  let matches = spokenListMarkerExpression.matches(
    in: text,
    range: NSRange(text.startIndex..., in: text)
  )
  guard matches.count >= 2,
        let firstRange = Range(matches[0].range, in: text) else { return nil }

  let heading = String(text[..<firstRange.lowerBound])
    .trimmingCharacters(in: listTrimCharacters)
  guard !heading.isEmpty,
        declaredListCount(in: heading) == matches.count else { return nil }

  let values = matches.compactMap { match -> Int? in
    guard let range = Range(match.range(at: 2), in: text) else { return nil }
    return numberValue(String(text[range]))
  }
  guard values == Array(1...matches.count) else { return nil }

  var items: [String] = []
  for (index, match) in matches.enumerated() {
    guard let markerRange = Range(match.range(at: 1), in: text),
          let fullMarkerRange = Range(match.range, in: text) else { return nil }
    let itemEnd = index + 1 < matches.count
      ? Range(matches[index + 1].range, in: text)!.lowerBound
      : text.endIndex
    let body = String(text[fullMarkerRange.upperBound..<itemEnd])
      .trimmingCharacters(in: listTrimCharacters)
    guard !body.isEmpty else { return nil }
    items.append("\(text[markerRange])，\(body)")
  }

  return heading + "：\n" + items.enumerated()
    .map { "\($0.offset + 1). \($0.element)" }
    .joined(separator: "\n")
}

private func declaredListCount(in text: String) -> Int? {
  guard let match = declaredListCountExpression.firstMatch(
    in: text,
    range: NSRange(text.startIndex..., in: text)
  ), let range = Range(match.range(at: 1), in: text) else { return nil }
  return numberValue(String(text[range]))
}

private func numberValue(_ value: String) -> Int? {
  Int(value) ?? chineseNumbers[value]
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
  private var longestNonEmpty = ""

  mutating func accept(text: String, isFinal: Bool) -> String? {
    let cleaned = cleanedTranscript(text)
    if cleaned.count >= longestNonEmpty.count {
      longestNonEmpty = cleaned
    }
    return isFinal ? longestNonEmpty : nil
  }
}
