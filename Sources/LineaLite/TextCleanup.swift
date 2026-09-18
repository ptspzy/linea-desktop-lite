import Foundation

private let semanticUnitExpression = try! NSRegularExpression(
  pattern: #"\p{Han}|[A-Za-z0-9]+(?:[._/-][A-Za-z0-9]+)*"#
)
private let punctuationSpacingExpression = try! NSRegularExpression(
  pattern: #"\s+([，。！？；：,!?;:])"#
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
  pattern: #"(?:^|[\s：:,，；;。.!！？?])(?:第([一二两三四五六七八九十]|[1-9][0-9]*)(?:[点项条步](?:是)?|(?![0-9零〇一二两三四五六七八九十百千万天年月季代名届次级层章节集册卷组轮版位个部]))|([一二两三四五六七八九十]|[1-9][0-9]*)点是)[，,。.!！？?：:；;、\s]*"#
)
private let compactThreeItemListExpression = try! NSRegularExpression(
  pattern: #"^(.*?有\s*(?:三|3)(?:种|个|项|点|条|类|份|组|步|方面|段)?)[：:.．]?\s*(?:一|1)[、.．)]?\s*(.+?)(?:二|2)[、.．)]?\s*(.+?)(?:三|3)[、.．)]?\s*(.+?)[。.!！？?]?$"#
)
private let numberedListMarkerExpression = try! NSRegularExpression(
  pattern: #"(?:^|[\s：:,，；;。!！？?])(?:([1-9][0-9]*(?:\.[1-9][0-9]*)+)(?:[.)．、])?(?:\s+|(?=\p{Han}))|([1-9][0-9]*)[.)．、]\s+)"#
)
private let paragraphCues = ["后续的话", "另外的话", "另一方面", "接下来", "另外", "最后"]
private let sentenceEndings: Set<Character> = ["。", "！", "？", ".", "!", "?"]
private let terminalPunctuation: Set<Character> = ["，", "。", "！", "？", "；", "：", "、", ",", ".", "!", "?", ";", ":"]
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
  // Preformatted code is literal, including indentation and line breaks.
  if value.contains("```") {
    return paragraphBreaks ? value.trimmingCharacters(in: .whitespacesAndNewlines) : cleanedTranscript(value)
  }
  let value = normalizedDeveloperIdentifiers(value)
  let structured = paragraphBreaks ? expandedLayoutCommands(value) : value
  let cleaned = normalizedPunctuationSpacing(cleanedTranscript(value))
  guard !cleaned.isEmpty else { return "" }
  let paragraphs = structured.replacingOccurrences(of: "\r\n", with: "\n")
    .components(separatedBy: "\n\n")
    .map { paragraph in
      paragraph.components(separatedBy: "\n")
        .map { normalizedPunctuationSpacing(cleanedTranscript($0)) }
        .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    .filter { !$0.isEmpty }
  if paragraphBreaks, paragraphs.count == 1, let list = formattedExplicitList(paragraphs[0]) {
    return normalizedSpokenNumbers(list)
  }

  let sections = (paragraphBreaks ? paragraphs : [cleaned]).flatMap(strongParagraphSections)
  let formatted = sections
    .map { section in
      if paragraphBreaks, let list = formattedExplicitList(section) { return list }
      return section.components(separatedBy: "\n").map(formatSentenceSequence).joined(separator: "\n")
    }
    .joined(separator: paragraphBreaks && sections.count > 1 ? "\n\n" : "")
  let result = paragraphBreaks ? groupedLongParagraphs(formatted) : formatted
  return normalizedSpokenNumbers(withoutSingleSentenceTerminalPunctuation(result))
}

private let layoutCommandExpression = try! NSRegularExpression(
  pattern: #"(?:^|(?<=[\s，,。.!！？?；;：:]))(另起一段|换一段|新段落|下一段|换段|另起一行|换行)(?=$|[\s，,。.!！？?；;：:])[ \t，,。.!！？?；;：:]*"#
)

private func expandedLayoutCommands(_ text: String) -> String {
  var result = text
  for match in unquotedMatches(layoutCommandExpression, in: text).reversed() {
    let command = (text as NSString).substring(with: match.range(at: 1))
    result = (result as NSString).replacingCharacters(
      in: match.range, with: command.hasSuffix("行") ? "\n" : "\n\n"
    )
  }
  return result
}

private let spokenNumberExpression = try! NSRegularExpression(
  pattern: #"(?:负?百分之)?[负零〇一二两三四五六七八九十百千万亿点]+"#
)
private let spokenNumberContextExpression = try! NSRegularExpression(
  pattern: #"(版本号?|端口号?|行号|数值|数字|小数|圆周率|阈值|百分比|等于|设置为|设为|改为|改成|比如说|比如|例如|(?:参数|值|系数|常量)(?:为|是))(?:设置为|设为|改为|改成|为|是)?[\s：:]*$"#
)
private let quotedNumberExpression = try! NSRegularExpression(
  pattern: #"`[^`]*(?:`|$)|"(?:\\.|[^"\\])*(?:"|$)|'(?:\\.|[^'\\])*(?:'|$)|“[^”]*(?:”|$)|‘[^’]*(?:’|$)|「[^」]*(?:」|$)"#
)
private let technicalNumberExpression = try! NSRegularExpression(
  pattern: #"""
    (?<![^\n，。！？；,!?;])[^\n，。！？；,!?;]*
      (?:[-=+*/%<>{}()\[\]]|\b(?:let|var|const|func|class|struct|enum|def|return|case|import|from|if|for|while|switch|echo|export)\s)
      [^\n，。！？；,!?;]*
    |(?<![^\s，。！？；：、,!?;:])[^\s，。！？；：、,!?;:]*
      (?:[A-Za-z0-9_/@\\-]|\.(?=[^\s，。！？；：、,!?;:]))[^\s，。！？；：、,!?;:]*
    """#,
  options: .allowCommentsAndWhitespace
)
private let spokenDigits: [Character: String] = [
  "零": "0", "〇": "0", "一": "1", "二": "2", "两": "2", "三": "3", "四": "4",
  "五": "5", "六": "6", "七": "7", "八": "8", "九": "9",
]
private let developerIdentifierExpression = try! NSRegularExpression(
  pattern: #"""
    (?<![A-Za-z0-9_./\\-])(?:
      ((?i:dev|develop|release|hotfix|feature|bugfix|d\h+e\h+v)|戴夫|德夫|迪夫)
      \h*([/／]|正?斜杠|(?i:slash))?\h*
      ([0-9零〇一二两三四五六七八九十百千]+(?:\h*(?:点|[.．])\h*[0-9零〇一二两三四五六七八九十百千]+)+)
      |([vV])([0-9零〇一二两三四五六七八九十百千]+(?:\h*(?:点|[.．])\h*[0-9零〇一二两三四五六七八九十百千]+)+)
    )(?![A-Za-z0-9_./\\点零〇一二两三四五六七八九十百千-])
    """#,
  options: .allowCommentsAndWhitespace
)

private func normalizedDeveloperIdentifiers(_ text: String) -> String {
  var result = text
  for match in unquotedMatches(developerIdentifierExpression, in: text).reversed() {
    let isBranch = match.range(at: 1).location != NSNotFound
    let inferredBranch = isBranch && match.range(at: 2).location == NSNotFound
    if inferredBranch {
      let suffix = (text as NSString).substring(from: NSMaxRange(match.range))
      guard suffix.range(of: #"^\h*分支"#, options: .regularExpression) != nil else { continue }
    }
    let prefix = (text as NSString).substring(with: match.range(at: isBranch ? 1 : 4))
    let raw = (text as NSString).substring(with: match.range(at: isBranch ? 3 : 5))
      .replacingOccurrences(of: "．", with: "点").replacingOccurrences(of: ".", with: "点")
      .filter { !$0.isWhitespace }
    let parts = raw.split(separator: "点", omittingEmptySubsequences: false)
    let numbers = parts.compactMap(spokenInteger)
    guard numbers.count == parts.count else { continue }
    let original = (text as NSString).substring(with: match.range)
    let spokenBranch = isBranch && original.unicodeScalars.contains { $0.properties.isIdeographic }
    let name = ["戴夫", "德夫", "迪夫"].contains(prefix) || prefix.contains(where: \.isWhitespace)
      ? "dev" : (inferredBranch || (spokenBranch && prefix == prefix.capitalized) ? prefix.lowercased() : prefix)
    // An omitted slash requires explicit branch context; arbitrary paths stay literal.
    let replacement = name + (isBranch ? "/" : "") + numbers.joined(separator: ".")
    result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
  }
  return result
}
private let spokenIntegerFormatter: NumberFormatter = {
  let formatter = NumberFormatter()
  formatter.locale = Locale(identifier: "zh_CN")
  formatter.numberStyle = .spellOut
  return formatter
}()

private func normalizedSpokenNumbers(_ text: String) -> String {
  let fullRange = NSRange(text.startIndex..., in: text)
  let matches = spokenNumberExpression.matches(in: text, range: fullRange)
  guard !matches.isEmpty else { return text }
  let protected = [quotedNumberExpression, technicalNumberExpression]
    .flatMap { $0.matches(in: text, range: fullRange).map(\.range) }
    .sorted { $0.location < $1.location }
  var protectedIndex = 0
  var cursor = text.startIndex
  var output = ""
  for match in matches {
    while protectedIndex < protected.count, NSMaxRange(protected[protectedIndex]) <= match.range.location {
      protectedIndex += 1
    }
    if protectedIndex < protected.count,
       NSIntersectionRange(protected[protectedIndex], match.range).length > 0 { continue }
    guard let range = Range(match.range, in: text) else { continue }
    let token = String(text[range])
    let before = String(text[..<range.lowerBound].suffix(48))
    let after = text[range.upperBound...]
    let context = spokenNumberContextExpression.firstMatch(
      in: before, range: NSRange(before.startIndex..., in: before)
    )
    let contextName = context.flatMap { Range($0.range(at: 1), in: before) }
      .map { String(before[$0]) }
    let version = contextName?.hasPrefix("版本") ?? false
    let standalone = spokenNumberBoundary(before.last) && spokenNumberBoundary(after.first)
    let lineNumber = before.hasSuffix("第") && after.hasPrefix("行")
      && !token.contains("点") && !token.contains("负")
      && (spokenNumberBoundary(after.dropFirst().first) || after.hasPrefix("行的") || after.hasPrefix("行报错"))
    let percentage = token.hasPrefix("百分之") || token.hasPrefix("负百分之")
    guard standalone || lineNumber
      || ((context != nil || percentage) && (spokenNumberBoundary(after.first)
        || after.hasPrefix("的") || after.hasPrefix("这样的"))) else { continue }
    if (context == nil || ["比如说", "比如", "例如"].contains(contextName ?? "")),
       ["七七八八", "三三两两", "三三五五"].contains(token) { continue }
    if token.contains("点"), !version {
      let previous = before.trimmingCharacters(in: listTrimCharacters)
      let following = after.prefix(8).trimmingCharacters(in: .whitespacesAndNewlines)
      if ["上午", "下午", "晚上", "凌晨", "中午", "早上", "早晨", "傍晚"].contains(where: previous.hasSuffix)
        || ["刻", "分", "秒", "钟", "半"].contains(where: following.hasPrefix) { continue }
    }
    guard let number = spokenNumber(token, version: version) else { continue }
    output += text[cursor..<range.lowerBound] + number
    cursor = range.upperBound
  }
  output += text[cursor...]
  return output
}

private func spokenNumberBoundary(_ character: Character?) -> Bool {
  guard let character else { return true }
  return character.isWhitespace || "，。！？；：、,.!?;:（）".contains(character)
}

private func spokenNumber(_ token: String, version: Bool) -> String? {
  var body = token[...]
  var negative = body.hasPrefix("负")
  if negative { body.removeFirst() }
  let percentage = body.hasPrefix("百分之")
  if percentage {
    body = body.dropFirst(3)
    if !negative, body.hasPrefix("负") {
      negative = true
      body.removeFirst()
    }
  }
  let parts = body.split(separator: "点", omittingEmptySubsequences: false)
  guard let first = parts.first, let integer = spokenInteger(first) else { return nil }
  var number = integer
  if version {
    guard !negative, !percentage else { return nil }
    for part in parts.dropFirst() {
      guard let component = spokenInteger(part) else { return nil }
      number += "." + component
    }
  } else if parts.count > 1 {
    guard parts.count == 2, !parts[1].isEmpty else { return nil }
    // Fractional digits stay strings, including leading/trailing zeros and arbitrarily long decimals.
    let fraction = parts[1].compactMap { spokenDigits[$0] }
    guard fraction.count == parts[1].count, !parts[1].contains("两") else { return nil }
    number += "." + fraction.joined()
  }
  return (negative ? "-" : "") + number + (percentage ? "%" : "")
}

private func spokenInteger(_ text: Substring) -> String? {
  guard !text.isEmpty else { return nil }
  if text.allSatisfy({ $0.isASCII && $0.isNumber }) { return String(text) }
  let digits = text.compactMap { spokenDigits[$0] }
  if digits.count == text.count {
    guard text.count == 1 || !text.contains("两") else { return nil }
    return digits.joined()
  }
  // ponytail: unit-form integers are limited to 15 digits; larger values need exact parser tests.
  guard text.count <= 48, !text.contains("负"),
        let number = spokenIntegerFormatter.number(from: String(text)),
        number.compare(0) != .orderedAscending,
        number.compare(999_999_999_999_999) != .orderedDescending,
        let spelling = spokenIntegerFormatter.string(from: number) else { return nil }
  let normalized = text.replacingOccurrences(of: "两", with: "二").replacingOccurrences(of: "〇", with: "零")
  // Reject partial parses and ambiguous shorthand such as 一百二 (Foundation reads it as 102).
  guard spelling.replacingOccurrences(of: "〇", with: "零") == normalized else { return nil }
  return number.stringValue
}

func paragraphFormattingAllowed(appName: String?) -> Bool {
  guard let name = appName?.lowercased() else { return true }
  return !["terminal", "iterm2", "warp", "alacritty", "kitty", "wezterm"].contains(name)
}

private func formattedExplicitList(_ text: String) -> String? {
  formattedNumberedList(text) ?? formattedInlineList(text)
    ?? formattedSpokenList(text) ?? formattedCompactThreeItemList(text)
}

private func formattedNumberedList(_ text: String) -> String? {
  let matches = numberedListMarkerExpression.matches(in: text, range: NSRange(text.startIndex..., in: text))
  guard matches.count >= 2 else { return nil }
  let labels = matches.compactMap { match -> String? in
    let group = match.range(at: 1).location == NSNotFound ? 2 : 1
    return Range(match.range(at: group), in: text).map { String(text[$0]) }
  }
  let numbers = labels.map { $0.split(separator: ".").compactMap { Int($0) } }
  guard zip(labels, numbers).allSatisfy({ $0.split(separator: ".").count == $1.count }),
        numbers[0].last == 1 || numbers[1] == numbers[0] + [1] else { return nil }
  for (previous, next) in zip(numbers, numbers.dropFirst()) {
    if next == previous + [1] { continue }
    guard next.count <= previous.count,
          next.dropLast() == previous.prefix(next.count - 1),
          previous[next.count - 1] < Int.max,
          next.last == previous[next.count - 1] + 1 else { return nil }
  }

  var lines: [String] = []
  let firstGroup = matches[0].range(at: 1).location == NSNotFound ? 2 : 1
  let firstRange = Range(matches[0].range(at: firstGroup), in: text)!
  let heading = String(text[..<firstRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
  guard heading.isEmpty || heading.hasSuffix(":") || heading.hasSuffix("：")
    || declaredListCount(in: heading) != nil else { return nil }
  if !heading.isEmpty { lines.append(heading) }
  for (index, match) in matches.enumerated() {
    let start = Range(match.range, in: text)!.upperBound
    let end = index + 1 < matches.count
      ? Range(matches[index + 1].range, in: text)!.lowerBound : text.endIndex
    let item = trimmedListItem(String(text[start..<end]))
    guard let initial = item.first else { return nil }
    if numbers[index].count > 1, !text[text.index(before: start)].isWhitespace,
       measurementUnitInitials.contains(initial) { return nil }
    let label = labels[index] + (numbers[index].count == 1 ? "." : "")
    lines.append("\(label) \(item)")
  }
  return lines.joined(separator: "\n")
}

private func formattedCompactThreeItemList(_ text: String) -> String? {
  guard let match = compactThreeItemListExpression.firstMatch(
    in: text,
    range: NSRange(text.startIndex..., in: text)
  ) else { return nil }

  let parts = (1...4).compactMap { index -> String? in
    guard let range = Range(match.range(at: index), in: text) else { return nil }
    return trimmedListItem(String(text[range]))
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
    let item = trimmedListItem(String(text[markerRange.upperBound..<itemEnd]))
    guard !item.isEmpty else { return nil }
    items.append(item)
  }

  return heading + "：\n" + items.enumerated()
    .map { "\($0.offset + 1). \($0.element)" }
    .joined(separator: "\n")
}

private func formattedSpokenList(_ text: String) -> String? {
  let matches = unquotedMatches(spokenListMarkerExpression, in: text)
  guard matches.count >= 2,
        let firstRange = Range(matches[0].range, in: text) else { return nil }

  let heading = String(text[..<firstRange.lowerBound])
    .trimmingCharacters(in: listTrimCharacters)
  if let declared = declaredListCount(in: heading), declared != matches.count { return nil }

  let values = matches.compactMap { match -> Int? in
    let group = match.range(at: 1).location == NSNotFound ? 2 : 1
    guard let range = Range(match.range(at: group), in: text) else { return nil }
    return numberValue(String(text[range]))
  }
  guard values == Array(1...matches.count) else { return nil }

  var items: [String] = []
  for (index, match) in matches.enumerated() {
    guard let fullMarkerRange = Range(match.range, in: text) else { return nil }
    let itemEnd = index + 1 < matches.count
      ? Range(matches[index + 1].range, in: text)!.lowerBound
      : text.endIndex
    let body = trimmedListItem(String(text[fullMarkerRange.upperBound..<itemEnd]))
    guard !body.isEmpty else { return nil }
    items.append(body)
  }

  return (heading.isEmpty ? "" : heading + "：\n") + items.enumerated()
    .map { "\($0.offset + 1). \($0.element)" }
    .joined(separator: "\n")
}

private func unquotedMatches(_ expression: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
  let range = NSRange(text.startIndex..., in: text)
  let quoted = quotedNumberExpression.matches(in: text, range: range).map(\.range)
  return expression.matches(in: text, range: range).filter { match in
    !quoted.contains { NSIntersectionRange($0, match.range).length > 0 }
  }
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

private func trimmedListItem(_ value: String) -> String {
  var result = value.trimmingCharacters(in: listTrimCharacters.subtracting(CharacterSet(charactersIn: ".")))
  while result.last == ".", isSentenceEnding(in: result, at: result.index(before: result.endIndex)) {
    result.removeLast()
  }
  return result.trimmingCharacters(in: .whitespacesAndNewlines)
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
  let quoted = quotedNumberExpression.matches(in: text, range: NSRange(text.startIndex..., in: text))

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
    let boundary = before.last.map { $0.isWhitespace || "。！？.!?；;".contains($0) } ?? false
    let isQuoted = quoted.contains { NSIntersectionRange($0.range, NSRange(range, in: text)).length > 0 }
    if boundary, !isQuoted, semanticUnitCount(before) >= 8, semanticUnitCount(after) >= 8 {
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

  return paragraphs.map { $0.joined().trimmingCharacters(in: .whitespacesAndNewlines) }
    .joined(separator: "\n\n")
}

private func splitSentences(_ text: String) -> [String] {
  var sentences: [String] = []
  var current = ""
  for index in text.indices {
    current.append(text[index])
    let next = text.index(after: index)
    if isSentenceEnding(in: text, at: index),
       next == text.endIndex || !sentenceEndings.contains(text[next]) {
      sentences.append(current)
      current = ""
    }
  }
  if !current.isEmpty { sentences.append(current) }
  return sentences
}

private func isSentenceEnding(in text: String, at index: String.Index) -> Bool {
  guard sentenceEndings.contains(text[index]) else { return false }
  guard text[index] == "." else { return true }
  let next = text.index(after: index)
  if next < text.endIndex, !text[next].isWhitespace, !sentenceEndings.contains(text[next]) {
    return false
  }
  let tokenStart = text[..<index].lastIndex(where: \.isWhitespace)
    .map { text.index(after: $0) } ?? text.startIndex
  let token = text[tokenStart...index]
  return token != "." && token != ".." && !token.hasSuffix("/.") && !token.hasSuffix("/..")
    && !token.hasSuffix("\\.") && !token.hasSuffix("\\..")
}

private func withoutSingleSentenceTerminalPunctuation(_ text: String) -> String {
  guard !text.contains("\n\n"),
        splitSentences(text).filter({ semanticUnitCount($0) > 0 }).count <= 1 else { return text }
  var result = text
  while let last = result.last, terminalPunctuation.contains(last) {
    if last == ".", !isSentenceEnding(in: result, at: result.index(before: result.endIndex)) { break }
    result.removeLast()
  }
  return result.trimmingCharacters(in: .whitespacesAndNewlines)
}
