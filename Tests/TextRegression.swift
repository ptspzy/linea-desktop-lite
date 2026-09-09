import Foundation

private func expectTextRegression(
  _ actual: String, _ expected: String, file: StaticString = #file, line: UInt = #line
) {
  precondition(actual == expected, "Expected: \(expected)\nActual: \(actual)", file: file, line: line)
}

private func expectTextRegression(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
  precondition(condition, "Text regression failed", file: file, line: line)
}

func runTextRegressionTests() throws {
  let formattingCases: [(String, String)] = [
    ("当前先完成配置和本地测试 后续的话 再进行录音验证和发布检查 最后整理结果并确认功能稳定",
     "当前先完成配置和本地测试。\n\n后续的话，再进行录音验证和发布检查。\n\n最后整理结果并确认功能稳定。"),
    ("第一段保留。\n\n第二段保留。\n\n第三段保留。", "第一段保留。\n\n第二段保留。\n\n第三段保留。"),
    ("支持三个环境：1开发，2测试，3生产。", "支持三个环境：\n1. 开发\n2. 测试\n3. 生产"),
    ("可以吃三种食物 一苹果 二香蕉 三西瓜", "可以吃三种食物：\n1. 苹果\n2. 香蕉\n3. 西瓜"),
    ("我下面说三点：第一点是延迟；第二点是准确率；第三点是稳定性。",
     "我下面说三点：\n1. 延迟\n2. 准确率\n3. 稳定性"),
    ("二三下面有3.1苹果二头三西瓜。", "二三下面有3：\n1. 苹果\n2. 头\n3. 西瓜"),
    ("下面有3.1苹果二苹果汁三苹果酱。", "下面有3：\n1. 苹果\n2. 苹果汁\n3. 苹果酱"),
    ("房间有3.1米宽二米高三米长。", "房间有3.1米宽二米高三米长"),
    ("1. Apple 2. Banana 3. Cherry.", "1. Apple\n2. Banana\n3. Cherry"),
    ("1. 分析 2. 总结。", "1. 分析\n2. 总结"),
    ("1. 3.14 2. v1.2.3 3. 127.0.0.1", "1. 3.14\n2. v1.2.3\n3. 127.0.0.1"),
    ("水果：3.1 Apple 3.2 Banana 3.3 Cherry.", "水果：\n3.1 Apple\n3.2 Banana\n3.3 Cherry"),
    ("3.1苹果，3.2香蕉，3.3西瓜。", "3.1 苹果\n3.2 香蕉\n3.3 西瓜"),
    ("3. Fruit 3.1 Apple 3.2 Banana 4. Water.", "3. Fruit\n3.1 Apple\n3.2 Banana\n4. Water"),
    ("3.1 Apple 3.3 Cherry", "3.1 Apple 3.3 Cherry"),
    ("3.14 Apple 3.15 Banana", "3.14 Apple 3.15 Banana"),
    ("Use 3.1 and 3.2 for comparison", "Use 3.1 and 3.2 for comparison"),
    ("v1.2.3 Apple v1.2.4 Banana", "v1.2.3 Apple v1.2.4 Banana"),
    ("/tmp/3.1 Apple /tmp/3.2 Banana", "/tmp/3.1 Apple /tmp/3.2 Banana"),
    ("3.1米宽 3.2米高", "3.1米宽 3.2米高"),
    ("普通数值 3.14，版本 v1.2.3，IP 127.0.0.1，路径 src/main.swift。",
     "普通数值 3.14，版本 v1.2.3，IP 127.0.0.1，路径 src/main.swift"),
    ("请在 DEV/2.5.1 分支检查 src-tauri/src/lib.rs 然后连接 127.0.0.1 端口",
     "请在 DEV/2.5.1 分支检查 src-tauri/src/lib.rs，然后连接 127.0.0.1 端口"),
    ("Open .env and ../src/main.swift then cd ..", "Open .env and ../src/main.swift then cd .."),
    ("cd .", "cd ."),
    ("cd ../..", "cd ../.."),
    (#"Open C:\src\main.swift and C:\src\.."#, #"Open C:\src\main.swift and C:\src\.."#),
    ("1. ../src/main.swift 2. /tmp/..", "1. ../src/main.swift\n2. /tmp/.."),
    ("这个 API uses MLX and Swift 处理一个 request。", "这个 API uses MLX and Swift 处理一个 request"),
    ("This is one English sentence with enough words to trigger the existing punctuation threshold.",
     "This is one English sentence with enough words to trigger the existing punctuation threshold"),
    ("Ready?!", "Ready"),
    ("First sentence. Second sentence.", "First sentence. Second sentence."),
    ("这个这个功能要慢慢检查，真的真的有用。", "这个这个功能要慢慢检查，真的真的有用"),
    ("We had had enough and that that clause is valid.", "We had had enough and that that clause is valid"),
  ]
  for (input, expected) in formattingCases {
    expectTextRegression(formattedTranscript(input), expected)
  }
  expectTextRegression(
    formattedTranscript("3.1 Apple 3.2 Banana", paragraphBreaks: false), "3.1 Apple 3.2 Banana"
  )
  expectTextRegression(
    formattedTranscript("当前先完成配置和本地测试 后续的话 再进行真实录音验证和发布检查", paragraphBreaks: false),
    "当前先完成配置和本地测试。后续的话，再进行真实录音验证和发布检查。"
  )
  let technicalSentence = String(repeating: "check 3.14 v1.2.3 127.0.0.1 src/main.swift ", count: 30)
  expectTextRegression(formattedTranscript(technicalSentence), technicalSentence.trimmingCharacters(in: .whitespaces))
  let longDictation = "第一部分主要说明当前项目的背景、目标和限制，并确认所有内容都在本地处理。"
    + "第二部分会检查语音识别、自动标点和历史记录在完整流程中是否保持一致。"
    + "第三部分开始验证较长文本在不同工作应用中的段落结构、阅读节奏和内容保护。"
    + "第四部分继续确认技术名词、版本号和文件路径不会因为格式处理发生变化。"
    + "最后一部分整理测试结果，并在确认没有内容被改写之后完成本地发布。"
  expectTextRegression(
    formattedTranscript(longDictation),
    "第一部分主要说明当前项目的背景、目标和限制，并确认所有内容都在本地处理。"
      + "第二部分会检查语音识别、自动标点和历史记录在完整流程中是否保持一致。\n\n"
      + "第三部分开始验证较长文本在不同工作应用中的段落结构、阅读节奏和内容保护。"
      + "第四部分继续确认技术名词、版本号和文件路径不会因为格式处理发生变化。\n\n"
      + "最后一部分整理测试结果，并在确认没有内容被改写之后完成本地发布。"
  )
  expectTextRegression(
    applyWorkspaceVocabulary(to: "当前模型使用坤三 A S R零点六 B四 bit M L X balanced。", entries: defaultDeveloperVocabulary),
    "当前模型使用Qwen3-ASR0.6B4-bit MLX balanced。"
  )
  let aliases = [
    WorkspaceVocabularyEntry(canonical: "Beta", aliases: ["Alpha"]),
    WorkspaceVocabularyEntry(canonical: "Gamma", aliases: ["Beta"]),
    WorkspaceVocabularyEntry(canonical: "Delta", aliases: ["Alpha Beta"]),
    WorkspaceVocabularyEntry(canonical: "Typeless", aliases: ["Tablas"]),
    WorkspaceVocabularyEntry(canonical: "CPlusPlus", aliases: ["C++"]),
    WorkspaceVocabularyEntry(canonical: "", aliases: [""]),
    WorkspaceVocabularyEntry(canonical: "Ignored", aliases: ["", String(repeating: "x", count: 129)]),
  ]
  expectTextRegression(applyWorkspaceVocabulary(to: "Alpha Beta; Alpha; Beta", entries: aliases), "Delta; Beta; Gamma")
  expectTextRegression(
    applyWorkspaceVocabulary(to: "Tablas TablasPlus preTablas Tablas_name Tablasé 使用Tablas。", entries: aliases),
    "Typeless TablasPlus preTablas Tablas_name Tablasé 使用Typeless。"
  )
  expectTextRegression(applyWorkspaceVocabulary(to: "Alpha Betamax", entries: aliases), "Beta Betamax")
  expectTextRegression(applyWorkspaceVocabulary(to: "C++ C++Builder", entries: aliases), "CPlusPlus C++Builder")
  expectTextRegression(
    applyWorkspaceVocabulary(to: "Tablas", entries: aliases + [WorkspaceVocabularyEntry(canonical: "Zed", aliases: ["Tablas"])]),
    "Zed"
  )

  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linea-text-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: directory) }
  let personalURL = directory.appendingPathComponent("support/personal-vocabulary.json")
  expectTextRegression(try loadPersonalVocabulary(from: personalURL).isEmpty)
  let firstSave = try savePersonalVocabularyCorrection(alias: " Tablas ", canonical: " Typeless ", to: personalURL)
  precondition(firstSave == [WorkspaceVocabularyEntry(canonical: "Typeless", aliases: ["Tablas"])])
  _ = try savePersonalVocabularyCorrection(alias: "千问三 ASR", canonical: "Qwen3-ASR", to: personalURL)
  let repeatedSave = try savePersonalVocabularyCorrection(alias: "Tablas", canonical: "Typeless", to: personalURL)
  expectTextRegression(repeatedSave == (try loadPersonalVocabulary(from: personalURL)))
  precondition(repeatedSave.count == 2)
  expectTextRegression(
    applyWorkspaceVocabulary(to: "使用 Tablas 和千问三 ASR。", entries: repeatedSave), "使用 Typeless 和Qwen3-ASR。"
  )
  let permissions = try FileManager.default.attributesOfItem(atPath: personalURL.path)[.posixPermissions] as? NSNumber
  precondition(permissions?.intValue == 0o600)
  let remapped = try savePersonalVocabularyCorrection(alias: "Tablas", canonical: "Linea Lite", to: personalURL)
  expectTextRegression(applyWorkspaceVocabulary(to: "Tablas", entries: remapped), "Linea Lite")
  try savePersonalVocabularyCorrection(alias: "M L X", canonical: "mlx", to: personalURL)
  let recased = try savePersonalVocabularyCorrection(alias: "M L X", canonical: "MLX", to: personalURL)
  expectTextRegression(applyWorkspaceVocabulary(to: "M L X", entries: recased), "MLX")
  let savedData = try Data(contentsOf: personalURL)
  for (alias, canonical) in [("", "Good"), ("x", "Good"), ("wrong", "a"), ("same", "same"),
                             ("two\nlines", "Good"), ("整句话。", "新句子"),
                             (String(repeating: "x", count: 129), "Good")] {
    do {
      try savePersonalVocabularyCorrection(alias: alias, canonical: canonical, to: personalURL)
      preconditionFailure("Invalid correction was accepted")
    } catch PersonalVocabularyError.invalidCorrection { }
    expectTextRegression(try Data(contentsOf: personalURL) == savedData)
  }
  try Data("not json".utf8).write(to: personalURL)
  do {
    try savePersonalVocabularyCorrection(alias: "wrong", canonical: "correct", to: personalURL)
    preconditionFailure("Corrupt vocabulary was overwritten")
  } catch is DecodingError { }
  expectTextRegression(try Data(contentsOf: personalURL) == Data("not json".utf8))

  let workspaceURL = directory.appendingPathComponent("workspace")
  try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
  let package = Data(#"{"name":"@linea/desktop","dependencies":{"swift-argument-parser":"1.5.0"}}"#.utf8)
  try package.write(to: workspaceURL.appendingPathComponent("package.json"))
  let composer = Data(#"{"name":"linea/backend","require":{"php":"^8.2","ext-json":"*","symfony/console":"^7"},"require-dev":{"phpunit/phpunit":"^11"}}"#.utf8)
  try composer.write(to: workspaceURL.appendingPathComponent("composer.json"))
  let workspaceAliases = Data(#"{"terms":[{"canonical":"Typeless","aliases":["Tablas"]},{"canonical":"CER"}]}"#.utf8)
  try workspaceAliases.write(to: workspaceURL.appendingPathComponent(".linea-vocabulary.json"))
  let workspaceEntries = try loadWorkspaceVocabulary(from: workspaceURL)
  let terms = Set(workspaceEntries.map(\.canonical))
  precondition(terms.isSuperset(of: ["workspace", "@linea/desktop", "swift-argument-parser", "linea/backend", "symfony/console", "phpunit/phpunit", "CER"]))
  precondition(!terms.contains("php") && !terms.contains("ext-json"))
  expectTextRegression(applyWorkspaceVocabulary(to: "Tablas", entries: workspaceEntries), "Typeless")
  try savePersonalVocabularyCorrection(alias: "Tablas", canonical: "Typeless", to: directory.appendingPathComponent("other/personal.json"))
  expectTextRegression(try Data(contentsOf: workspaceURL.appendingPathComponent("package.json")) == package)
  expectTextRegression(try Data(contentsOf: workspaceURL.appendingPathComponent("composer.json")) == composer)
  expectTextRegression(try Data(contentsOf: workspaceURL.appendingPathComponent(".linea-vocabulary.json")) == workspaceAliases)
  print("PASS: text regression tests")
}

#if TEXT_REGRESSION_STANDALONE
@main
private struct TextRegressionRunner {
  static func main() throws {
    try runTextRegressionTests()
  }
}
#endif
