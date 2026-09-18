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
  let developerCases: [(String, String)] = [
    ("分支是Dev斜杠一点一", "分支是dev/1.1"),
    ("切到 dev/一点一 分支", "切到 dev/1.1 分支"),
    ("合并到dev斜杠一点一分支", "合并到dev/1.1分支"),
    ("切到 D E V 斜杠 一点一", "切到 dev/1.1"),
    ("切到戴夫斜杠一点一分支", "切到dev/1.1分支"),
    ("release/一点十点零", "release/1.10.0"),
    ("hotfix／2点零点一", "hotfix/2.0.1"),
    ("版本 v一点二点三", "版本 v1.2.3"),
    ("DEV/1.1，src/一.swift，dev/一.txt", "DEV/1.1，src/一.swift，dev/一.txt"),
    ("戴夫今天发布一点东西", "戴夫今天发布一点东西"),
    ("`dev/一点一`", "`dev/一点一`"),
    (#""dev斜杠一点一""#, #""dev斜杠一点一""#),
  ]
  for (input, expected) in developerCases {
    expectTextRegression(formattedTranscript(input), expected)
  }
  let formattingCases: [(String, String)] = [
    ("第一修复登录，第二补充测试，第三发布版本。", "1. 修复登录\n2. 补充测试\n3. 发布版本"),
    ("第一名和第二名需要参加评审。", "第一名和第二名需要参加评审"),
    ("第一季度完成开发，第二季度开始上线。", "第一季度完成开发，第二季度开始上线"),
    ("第一点修复登录。换行。第二点补充测试。", "1. 修复登录\n2. 补充测试"),
    ("接口已经修复。换段。接下来补测试。换段。最后发布版本。",
     "接口已经修复。\n\n接下来补测试。\n\n最后发布版本。"),
    ("接口已经修复。换行。接下来补测试。", "接口已经修复。\n接下来补测试。"),
    ("接口已经修复。\n接下来补测试。", "接口已经修复。\n接下来补测试。"),
    ("这里需要换行处理，另外两个参数暂时保留。", "这里需要换行处理，另外两个参数暂时保留"),
    ("这个字段的描述里面包含另外一个参数的信息，不能拆开。", "这个字段的描述里面包含另外一个参数的信息，不能拆开"),
    ("请原样保留“换段”这两个字。", "请原样保留“换段”这两个字"),
    ("```swift\nlet 一 = 二\n```", "```swift\nlet 一 = 二\n```"),
    ("第一，修复登录。第二，补充测试。第三，发布版本。", "1. 修复登录\n2. 补充测试\n3. 发布版本"),
    ("今天的任务：第一步修复登录，第二步补充测试，第三步发布版本。",
     "今天的任务：\n1. 修复登录\n2. 补充测试\n3. 发布版本"),
    ("第一点是延迟，第二点是准确率，第三点是稳定性。", "1. 延迟\n2. 准确率\n3. 稳定性"),
    ("第一天写接口，第二天补测试。", "第一天写接口，第二天补测试"),
    ("第一，修复登录，第三，发布版本。", "第一，修复登录，第三，发布版本"),
    ("下面有三点：第一，修复登录，第二，补充测试。", "下面有三点：第一，修复登录，第二，补充测试"),
    (#"示例是"第一，修复登录，第二，补充测试""#, #"示例是"第一，修复登录，第二，补充测试""#),
    ("示例是“第一，修复登录，第二，补充测试”", "示例是“第一，修复登录，第二，补充测试”"),
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
  let numberCases: [(String, String)] = [
    ("三点一四一五九二六三", "3.14159263"),
    ("数值是三点一四一五九二六三", "数值是3.14159263"),
    ("比如说三点一四一五九二六三这样的", "比如说3.14159263这样的"),
    ("这个值是三点一四一五九二六三这样的", "这个值是3.14159263这样的"),
    ("参数是负零点零零一", "参数是-0.001"),
    ("数值是七七八八", "数值是7788"),
    ("负零点零零一零", "-0.0010"),
    ("零点一二三四五六七八九零一二三四五六七八九零", "0.12345678901234567890"),
    ("一二三四五六七八九零一二三四五六七八九零点零零", "12345678901234567890.00"),
    ("零零一二三", "00123"),
    ("〇一〇", "010"),
    ("零", "0"),
    ("一", "1"),
    ("两", "2"),
    ("十二", "12"),
    ("负四十二", "-42"),
    ("两千零二十四", "2024"),
    ("二十三万四千五百六十七", "234567"),
    ("一万零三", "10003"),
    ("一百零二点零一零", "102.010"),
    ("九千九百九十九亿九千九百九十九万九千九百九十九", "999999999999"),
    ("端口八零八零", "端口8080"),
    ("请把端口改成八千零八十", "请把端口改成8080"),
    ("端口号：三零零零", "端口号：3000"),
    ("版本是一点二点三", "版本是1.2.3"),
    ("版本号十二点十点零", "版本号12.10.0"),
    ("版本三点十四", "版本3.14"),
    ("跳到第一百二十八行", "跳到第128行"),
    ("第十二行的代码", "第12行的代码"),
    ("行号为二百五十六", "行号为256"),
    ("圆周率是三点一四一五九二六三", "圆周率是3.14159263"),
    ("阈值设为负零点零一", "阈值设为-0.01"),
    ("百分之三点五", "3.5%"),
    ("成功率百分之九十九点九零", "成功率99.90%"),
    ("百分之负零点五", "-0.5%"),
    ("负百分之二十", "-20%"),
    ("百分之二十的请求", "20%的请求"),
    ("1. 三点一四 2. 负十二", "1. 3.14\n2. -12"),
    ("我说两点：第一点是端口八零八零；第二点是版本一点二点三。",
     "我说两点：\n1. 端口8080\n2. 版本1.2.3"),
    ("数值为三点一四。\n\n端口八零八零。", "数值为3.14。\n\n端口8080。"),
    ("检查 src/一.swift，端口八零八零", "检查 src/一.swift，端口8080"),
    ("三点一，三点二", "3.1，3.2"),
  ]
  for (input, expected) in numberCases {
    expectTextRegression(formattedTranscript(input), expected)
  }
  let unchangedNumbers = [
    "一点问题", "有一点问题", "三点要求", "第一点", "第一点是延迟", "统一处理", "一心一意",
    "不三不四", "七七八八", "三三两两", "三三五五", "千千万万", "略知一二", "二进制", "三维数组",
    "比如说七七八八的事情", "例如三三五五的人",
    "三点一刻", "三点三刻", "三点十五", "三点零五分", "下午三点一五", "下午 三点一五",
    "一点二点三", "一百二", "一千二", "十百", "一百百", "一百零零二", "一亿亿",
    "三点", "三点点一", "负负三", "负百分之负三", "百分之一点问题", "版本一律不变",
    "第一行星", "第十二点要求", "第负三行", "第三点一行", "端口三号文件", "一.二", "../一/二", "三点一四.txt",
    "src/一二.swift", #"C:\一\二.swift"#, "https://example.com/一二", "foo一二", "一二foo", "值_一二",
    "变量三点一四", "let 一 = 二", "一 + 二", "函数(一)", "`一二三`", "`三点一四",
    "一 - 二", "一/二", "一 / 二", "一 % 二", "2 - 三",
    "let 一", "return 一", "let 一: 二", "for 一 in 二", "echo 一", "一两", "一点两", "一万万亿",
    #""三点一四""#, #"print("三点一四")"#,
    "3.14159263", "-0.0010", "v1.2.3", "127.0.0.1", "localhost:8080", "3.50%",
  ]
  for input in unchangedNumbers {
    expectTextRegression(formattedTranscript(input), cleanedTranscript(input))
  }
  expectTextRegression(cleanedQwenOutput("第一段。\n\n第二段。"), "第一段。\n\n第二段。")
  expectTextRegression(cleanedQwenOutput("```swift\n  let x = 1\n```"), "```swift\n  let x = 1\n```")
  expectTextRegression(
    formattedTranscript("修复登录。换段。补充测试。", paragraphBreaks: false),
    "修复登录。换段。补充测试。"
  )
  expectTextRegression(formattedTranscript("三点一四一五九二六三", paragraphBreaks: false), "3.14159263")
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
  expectTextRegression(
    applyWorkspaceVocabulary(to: "Release this Feature to DEV/1.1.", entries: defaultDeveloperVocabulary),
    "Release this Feature to DEV/1.1."
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
