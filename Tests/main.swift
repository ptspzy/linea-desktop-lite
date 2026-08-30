import Foundation

assert(
  qwenCommandArguments(
    modelURL: URL(fileURLWithPath: "/models/qwen.gguf"),
    audioURL: URL(fileURLWithPath: "/tmp/sample.wav")
  ) == [
    "--backend", "qwen3", "-m", "/models/qwen.gguf", "-f", "/tmp/sample.wav",
    "-np", "-nt", "-l", "auto", "--lid-backend", "off",
  ]
)
assert(cleanedQwenOutput("  最后一句没有缺少。\n") == "最后一句没有缺少。")
assert(
  qwenServerArguments(modelURL: URL(fileURLWithPath: "/models/qwen.gguf"), port: 17_999) == [
    "--server", "--host", "127.0.0.1", "--port", "17999",
    "--backend", "qwen3", "-m", "/models/qwen.gguf", "-np", "-nt",
    "-l", "auto", "--lid-backend", "off", "--ws-port", "-1", "--wyoming-port", "-1",
  ]
)
let serverTranscript = try qwenServerTranscript(#"{"text":"  预热后更快。\n"}"#)
assert(serverTranscript == "预热后更快。")

do {
  _ = try processOutput(
    executableURL: URL(fileURLWithPath: "/bin/sleep"),
    arguments: ["1"],
    timeout: 0.01
  )
  assertionFailure("Timed-out recognition process should fail")
} catch {
  assert(error.localizedDescription == "sleep timed out.")
}

private struct DictationCase {
  let name: String
  let input: String
  let expected: String
}

private let commonDictationCases = [
  DictationCase(
    name: "普通陈述",
    input: "今天下午三点我们在会议室讨论发布计划",
    expected: "今天下午三点我们在会议室讨论发布计划。"
  ),
  DictationCase(
    name: "短问句",
    input: "这个版本今天能发布吗",
    expected: "这个版本今天能发布吗？"
  ),
  DictationCase(
    name: "三段落",
    input: "当前先完成配置和本地测试 后续的话 再进行录音验证和发布检查 最后整理结果并确认功能稳定",
    expected: "当前先完成配置和本地测试。\n\n后续的话，再进行录音验证和发布检查。\n\n最后整理结果并确认功能稳定。"
  ),
  DictationCase(
    name: "阿拉伯数字分点",
    input: "支持三个环境：1开发，2测试，3生产。",
    expected: "支持三个环境：\n1. 开发\n2. 测试\n3. 生产"
  ),
  DictationCase(
    name: "中文数字分点",
    input: "可以吃三种食物 一苹果 二香蕉 三西瓜",
    expected: "可以吃三种食物：\n1. 苹果\n2. 香蕉\n3. 西瓜"
  ),
  DictationCase(
    name: "口述顺序分点",
    input: "我下面说三点：第一点是延迟；第二点是准确率；第三点是稳定性。",
    expected: "我下面说三点：\n1. 延迟\n2. 准确率\n3. 稳定性"
  ),
  DictationCase(
    name: "紧凑口述分点",
    input: "二三下面有3.1苹果二头三西瓜。",
    expected: "二三下面有3：\n1. 苹果\n2. 头\n3. 西瓜"
  ),
  DictationCase(
    name: "技术内容保护",
    input: "请在 DEV/2.5.1 分支检查 src-tauri/src/lib.rs 然后连接 127.0.0.1 端口",
    expected: "请在 DEV/2.5.1 分支检查 src-tauri/src/lib.rs，然后连接 127.0.0.1 端口。"
  ),
  DictationCase(
    name: "分点误判保护",
    input: "我有三只猫 今天天气很好",
    expected: "我有三只猫 今天天气很好。"
  ),
  DictationCase(
    name: "小数误判保护",
    input: "房间有3.1米宽二米高三米长。",
    expected: "房间有3.1米宽二米高三米长。"
  ),
  DictationCase(
    name: "同字开头分点",
    input: "下面有3.1苹果二苹果汁三苹果酱。",
    expected: "下面有3：\n1. 苹果\n2. 苹果汁\n3. 苹果酱"
  ),
]

for testCase in commonDictationCases {
  let actual = formattedTranscript(testCase.input)
  guard actual == testCase.expected else {
    fputs("FAILED: \(testCase.name)\nexpected: \(testCase.expected)\nactual:   \(actual)\n", stderr)
    exit(1)
  }
  print("PASS: \(testCase.name)")
}

assert(cleanedTranscript("  hello\n\nworld  ") == "hello world")
assert(cleanedTranscript("Linea   Lite") == "Linea Lite")
assert(cleanedTranscript("") == "")
assert(formattedTranscript("这个功能现在能用吗，") == "这个功能现在能用吗？")
assert(formattedTranscript("西红柿") == "西红柿")
assert(
  formattedTranscript("当前先完成配置和本地测试 后续的话 再进行真实录音验证和发布检查")
    == "当前先完成配置和本地测试。\n\n后续的话，再进行真实录音验证和发布检查。"
)
assert(
  formattedTranscript("当前先完成配置和本地测试， 后续的话，再进行真实录音验证和发布检查。")
    == "当前先完成配置和本地测试。\n\n后续的话，再进行真实录音验证和发布检查。"
)
assert(
  formattedTranscript(
    "当前先完成配置和本地测试 后续的话 再进行真实录音验证和发布检查",
    paragraphBreaks: false
  ) == "当前先完成配置和本地测试。后续的话，再进行真实录音验证和发布检查。"
)
let longDictation = "第一部分主要说明当前项目的背景、目标和限制，并确认所有内容都在本地处理。"
  + "第二部分会检查语音识别、自动标点和历史记录在完整流程中是否保持一致。"
  + "第三部分开始验证较长文本在不同工作应用中的段落结构、阅读节奏和内容保护。"
  + "第四部分继续确认技术名词、版本号和文件路径不会因为格式处理发生变化。"
  + "最后一部分整理测试结果，并在确认没有内容被改写之后完成本地发布。"
let formattedLongDictation = formattedTranscript(longDictation)
assert(
  formattedLongDictation
    == "第一部分主要说明当前项目的背景、目标和限制，并确认所有内容都在本地处理。"
      + "第二部分会检查语音识别、自动标点和历史记录在完整流程中是否保持一致。\n\n"
      + "第三部分开始验证较长文本在不同工作应用中的段落结构、阅读节奏和内容保护。"
      + "第四部分继续确认技术名词、版本号和文件路径不会因为格式处理发生变化。\n\n"
      + "最后一部分整理测试结果，并在确认没有内容被改写之后完成本地发布。"
)
assert(!paragraphFormattingAllowed(appName: "Terminal"))
assert(!paragraphFormattingAllowed(appName: "iTerm2"))
assert(paragraphFormattingAllowed(appName: "TextEdit"))

var pushToTalk = PushToTalkState()
assert(pushToTalk.transition(to: true) == .pressed)
assert(pushToTalk.isPressed)
assert(pushToTalk.transition(to: true) == nil)
assert(pushToTalk.transition(to: false) == .released)
assert(!pushToTalk.isPressed)

assert(rightOptionPressed(keyCode: 58, optionPressed: true) == nil)
assert(rightOptionPressed(keyCode: 61, optionPressed: true) == true)
assert(rightOptionPressed(keyCode: 61, optionPressed: false) == false)

var tapShortcut = DictationShortcutState()
assert(tapShortcut.press(at: 0) == .start)
assert(tapShortcut.wantsRecording)
assert(tapShortcut.release(at: 0.1) == .continueRecording)
assert(tapShortcut.isLatched)
assert(tapShortcut.press(at: 1) == .stop)
assert(!tapShortcut.wantsRecording)
assert(tapShortcut.release(at: 1.1) == nil)

var holdShortcut = DictationShortcutState()
assert(holdShortcut.press(at: 0) == .start)
assert(holdShortcut.release(at: 0.5) == .stop)
assert(!holdShortcut.wantsRecording)

assert(captureAudioLevel(decibels: -160) == 0)
assert((0.50...0.55).contains(captureAudioLevel(decibels: -20)))
assert(captureAudioLevel(decibels: 0) == 1)

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(secondsFromGMT: 0)!
let now = Date(timeIntervalSince1970: 1_700_000_000)
let history = [
  HistoryEntry(id: "today", createdAt: now, text: "测试", duration: 2, appName: "TextEdit"),
  HistoryEntry(
    id: "yesterday",
    createdAt: calendar.date(byAdding: .day, value: -1, to: now)!,
    text: "hello",
    duration: 3,
    appName: "Notes"
  ),
]
let activity = historyActivity(entries: history, endingAt: now, days: 3, calendar: calendar)
assert(activity.map(\.count) == [0, 1, 1])
assert(activity.map(\.characters) == [0, 5, 2])
assert(historyActivityLevel(characters: 0, maximum: 10) == 0)
assert(historyActivityLevel(characters: 1, maximum: 10) == 1)
assert(historyActivityLevel(characters: 10, maximum: 10) == 4)

let workspaceURL = FileManager.default.temporaryDirectory
  .appendingPathComponent("linea-lite-workspace-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
try #"{"name":"@linea/desktop-lite","dependencies":{"swift-argument-parser":"1.5.0"}}"#
  .write(to: workspaceURL.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
try #"{"terms":[{"canonical":"Typeless","aliases":["Tablas"]},{"canonical":"Qwen3-ASR","aliases":["千问三 ASR"]},{"canonical":"CER"}]}"#
  .write(
    to: workspaceURL.appendingPathComponent(".linea-vocabulary.json"),
    atomically: true,
    encoding: .utf8
  )
let workspaceVocabulary = try loadWorkspaceVocabulary(from: workspaceURL)
let workspaceTerms = Set(workspaceVocabulary.map(\.canonical))
assert(workspaceTerms.contains(workspaceURL.lastPathComponent))
assert(workspaceTerms.contains("@linea/desktop-lite"))
assert(workspaceTerms.contains("swift-argument-parser"))
assert(workspaceTerms.contains("CER"))
let workspaceCorrected = applyWorkspaceVocabulary(
  to: "最终目标是达到 Tablas，并使用千问三 ASR。",
  entries: workspaceVocabulary
)
assert(workspaceCorrected == "最终目标是达到 Typeless，并使用Qwen3-ASR。", workspaceCorrected)
try FileManager.default.removeItem(at: workspaceURL)

assert(qwenModelStatus(modelIsValid: false, partialBytes: nil, totalBytes: 100) == .missing)
assert(qwenModelStatus(modelIsValid: false, partialBytes: 48, totalBytes: 100) == .downloading(48))
assert(qwenModelStatus(modelIsValid: true, partialBytes: nil, totalBytes: 100) == .ready)

let historyURL = FileManager.default.temporaryDirectory
  .appendingPathComponent("linea-lite-tests-\(UUID().uuidString)/history.json")
let store = HistoryStore(url: historyURL, limit: 2)
assert(store.append(history[0]))
assert(store.append(history[1]))
assert(store.append(HistoryEntry(
  id: "oldest",
  createdAt: calendar.date(byAdding: .day, value: -2, to: now)!,
  text: "old",
  duration: 1,
  appName: nil
)))
assert(store.entries.map(\.id) == ["today", "yesterday"])
let reloaded = HistoryStore(url: historyURL, limit: 2)
assert(reloaded.entries == store.entries)
assert(reloaded.clear())
assert(HistoryStore(url: historyURL).entries.isEmpty)
try? FileManager.default.removeItem(at: historyURL.deletingLastPathComponent())

print("Tests ok")
