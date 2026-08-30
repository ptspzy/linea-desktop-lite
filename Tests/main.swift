import AppKit
import Foundation

@inline(never)
private func expect(
  _ condition: @autoclosure () -> Bool,
  _ message: @autoclosure () -> String = "Expectation failed",
  file: StaticString = #filePath,
  line: UInt = #line
) {
  guard condition() else {
    fputs("FAIL: \(message()) (\(file):\(line))\n", stderr)
    exit(1)
  }
}

private func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) -> Never {
  fputs("FAIL: \(message) (\(file):\(line))\n", stderr)
  exit(1)
}

expect(
  qwenCommandArguments(
    modelURL: URL(fileURLWithPath: "/models/qwen.gguf"),
    audioURL: URL(fileURLWithPath: "/tmp/sample.wav")
  ) == [
    "--backend", "qwen3", "-m", "/models/qwen.gguf", "-f", "/tmp/sample.wav",
    "-np", "-nt", "-l", "auto", "--lid-backend", "off",
  ]
)
expect(cleanedQwenOutput("  最后一句没有缺少。\n") == "最后一句没有缺少。")
expect(
  qwenServerArguments(modelURL: URL(fileURLWithPath: "/models/qwen.gguf"), port: 17_999) == [
    "--server", "--host", "127.0.0.1", "--port", "17999",
    "--backend", "qwen3", "-m", "/models/qwen.gguf", "-np", "-nt",
    "-l", "auto", "--lid-backend", "off", "--ws-port", "-1", "--wyoming-port", "-1",
  ]
)
let serverTranscript = try qwenServerTranscript(#"{"text":"  预热后更快。\n"}"#)
expect(serverTranscript == "预热后更快。")

do {
  _ = try processOutput(
    executableURL: URL(fileURLWithPath: "/bin/sleep"),
    arguments: ["1"],
    timeout: 0.01
  )
  fail("Timed-out recognition process should fail")
} catch {
  expect(error.localizedDescription == "sleep timed out.")
}

let pasteboard = NSPasteboard(name: NSPasteboard.Name("linea-lite-tests-\(UUID().uuidString)"))
let customPasteboardType = NSPasteboard.PasteboardType("io.github.linea.test-data")
let originalPasteboardItem = NSPasteboardItem()
originalPasteboardItem.setString("original clipboard", forType: .string)
originalPasteboardItem.setData(Data([1, 2, 3]), forType: customPasteboardType)
pasteboard.clearContents()
expect(pasteboard.writeObjects([originalPasteboardItem]))

let pasteboardSnapshot = PasteboardSnapshot(pasteboard: pasteboard)
guard let dictationChangeCount = setPasteboardText("dictated text", on: pasteboard) else {
  fail("Dictation text should be written to pasteboard")
}
expect(pasteboard.string(forType: .string) == "dictated text")
expect(pasteboardSnapshot.restore(to: pasteboard, ifUnchangedSince: dictationChangeCount))
expect(pasteboard.string(forType: .string) == "original clipboard")
expect(pasteboard.data(forType: customPasteboardType) == Data([1, 2, 3]))

let secondSnapshot = PasteboardSnapshot(pasteboard: pasteboard)
guard let secondDictationChangeCount = setPasteboardText("second dictation", on: pasteboard) else {
  fail("Second dictation text should be written to pasteboard")
}
pasteboard.clearContents()
pasteboard.setString("new user clipboard", forType: .string)
expect(!secondSnapshot.restore(to: pasteboard, ifUnchangedSince: secondDictationChangeCount))
expect(pasteboard.string(forType: .string) == "new user clipboard")

let largeProcessOutput = try processOutput(
  executableURL: URL(fileURLWithPath: "/usr/bin/awk"),
  arguments: [#"BEGIN { for (i = 0; i < 262144; i++) printf "x" }"#],
  timeout: 2
)
expect(largeProcessOutput.count == 262_144)

do {
  _ = try processOutput(
    executableURL: URL(fileURLWithPath: "/bin/sh"),
    arguments: ["-c", "printf 'model details' >&2; exit 7"]
  )
  fail("Failed process should report stderr")
} catch {
  expect(error.localizedDescription.contains("model details"), error.localizedDescription)
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

expect(cleanedTranscript("  hello\n\nworld  ") == "hello world")
expect(cleanedTranscript("Linea   Lite") == "Linea Lite")
expect(cleanedTranscript("") == "")
expect(formattedTranscript("这个功能现在能用吗，") == "这个功能现在能用吗？")
expect(formattedTranscript("西红柿") == "西红柿")
expect(
  formattedTranscript("当前先完成配置和本地测试 后续的话 再进行真实录音验证和发布检查")
    == "当前先完成配置和本地测试。\n\n后续的话，再进行真实录音验证和发布检查。"
)
expect(
  formattedTranscript("当前先完成配置和本地测试， 后续的话，再进行真实录音验证和发布检查。")
    == "当前先完成配置和本地测试。\n\n后续的话，再进行真实录音验证和发布检查。"
)
expect(
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
expect(
  formattedLongDictation
    == "第一部分主要说明当前项目的背景、目标和限制，并确认所有内容都在本地处理。"
      + "第二部分会检查语音识别、自动标点和历史记录在完整流程中是否保持一致。\n\n"
      + "第三部分开始验证较长文本在不同工作应用中的段落结构、阅读节奏和内容保护。"
      + "第四部分继续确认技术名词、版本号和文件路径不会因为格式处理发生变化。\n\n"
      + "最后一部分整理测试结果，并在确认没有内容被改写之后完成本地发布。"
)
expect(!paragraphFormattingAllowed(appName: "Terminal"))
expect(!paragraphFormattingAllowed(appName: "iTerm2"))
expect(paragraphFormattingAllowed(appName: "TextEdit"))

var pushToTalk = PushToTalkState()
expect(pushToTalk.transition(to: true) == .pressed)
expect(pushToTalk.isPressed)
expect(pushToTalk.transition(to: true) == nil)
expect(pushToTalk.transition(to: false) == .released)
expect(!pushToTalk.isPressed)

expect(rightOptionPressed(keyCode: 58, optionPressed: true) == nil)
expect(rightOptionPressed(keyCode: 61, optionPressed: true) == true)
expect(rightOptionPressed(keyCode: 61, optionPressed: false) == false)

var tapShortcut = DictationShortcutState()
expect(tapShortcut.press(at: 0) == .start)
expect(tapShortcut.wantsRecording)
expect(tapShortcut.release(at: 0.1) == .continueRecording)
expect(tapShortcut.isLatched)
expect(tapShortcut.press(at: 1) == .stop)
expect(!tapShortcut.wantsRecording)
expect(tapShortcut.release(at: 1.1) == nil)

var holdShortcut = DictationShortcutState()
expect(holdShortcut.press(at: 0) == .start)
expect(holdShortcut.release(at: 0.5) == .stop)
expect(!holdShortcut.wantsRecording)

expect(captureAudioLevel(decibels: -160) == 0)
expect((0.50...0.55).contains(captureAudioLevel(decibels: -20)))
expect(captureAudioLevel(decibels: 0) == 1)
expect(!captureShouldAutomaticallyStop(duration: 599.9))
expect(captureShouldAutomaticallyStop(duration: 600))

let captureDirectory = FileManager.default.temporaryDirectory
  .appendingPathComponent("linea-lite-capture-cleanup-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
let oldCaptureURL = captureDirectory.appendingPathComponent("linea-lite-old.wav")
let recentCaptureURL = captureDirectory.appendingPathComponent("linea-lite-recent.wav")
let unrelatedCaptureURL = captureDirectory.appendingPathComponent("other.wav")
for url in [oldCaptureURL, recentCaptureURL, unrelatedCaptureURL] {
  try Data([1]).write(to: url)
}
let cleanupNow = Date(timeIntervalSince1970: 10_000)
try FileManager.default.setAttributes(
  [.modificationDate: cleanupNow.addingTimeInterval(-3_601)],
  ofItemAtPath: oldCaptureURL.path
)
try FileManager.default.setAttributes(
  [.modificationDate: cleanupNow.addingTimeInterval(-30)],
  ofItemAtPath: recentCaptureURL.path
)
try FileManager.default.setAttributes(
  [.modificationDate: cleanupNow.addingTimeInterval(-3_601)],
  ofItemAtPath: unrelatedCaptureURL.path
)
removeStaleCaptureFiles(in: captureDirectory, now: cleanupNow)
expect(!FileManager.default.fileExists(atPath: oldCaptureURL.path))
expect(FileManager.default.fileExists(atPath: recentCaptureURL.path))
expect(FileManager.default.fileExists(atPath: unrelatedCaptureURL.path))
try FileManager.default.removeItem(at: captureDirectory)

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
expect(activity.map(\.count) == [0, 1, 1])
expect(activity.map(\.characters) == [0, 5, 2])
expect(historyActivityLevel(characters: 0, maximum: 10) == 0)
expect(historyActivityLevel(characters: 1, maximum: 10) == 1)
expect(historyActivityLevel(characters: 10, maximum: 10) == 4)

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
expect(workspaceTerms.contains(workspaceURL.lastPathComponent))
expect(workspaceTerms.contains("@linea/desktop-lite"))
expect(workspaceTerms.contains("swift-argument-parser"))
expect(workspaceTerms.contains("CER"))
let workspaceCorrected = applyWorkspaceVocabulary(
  to: "最终目标是达到 Tablas，并使用千问三 ASR。",
  entries: workspaceVocabulary
)
expect(workspaceCorrected == "最终目标是达到 Typeless，并使用Qwen3-ASR。", workspaceCorrected)

let modelTermCorrected = applyWorkspaceVocabulary(
  to: "当前模型使用坤三 A S R零点六 B四 bit M L X balanced。",
  entries: defaultDeveloperVocabulary
)
for term in ["Qwen3-ASR", "0.6B", "4-bit", "MLX", "balanced"] {
  expect(modelTermCorrected.contains(term), modelTermCorrected)
}
try FileManager.default.removeItem(at: workspaceURL)

expect(qwenModelStatus(modelIsValid: false, partialBytes: nil, totalBytes: 100) == .missing)
expect(qwenModelStatus(modelIsValid: false, partialBytes: 48, totalBytes: 100) == .downloading(48))
expect(qwenModelStatus(modelIsValid: true, partialBytes: nil, totalBytes: 100) == .ready)

let historyURL = FileManager.default.temporaryDirectory
  .appendingPathComponent("linea-lite-tests-\(UUID().uuidString)/history.json")
let store = HistoryStore(url: historyURL, limit: 2)
expect(store.append(history[0]))
expect(store.append(history[1]))
expect(store.append(HistoryEntry(
  id: "oldest",
  createdAt: calendar.date(byAdding: .day, value: -2, to: now)!,
  text: "old",
  duration: 1,
  appName: nil
)))
expect(store.entries.map(\.id) == ["today", "yesterday"])
let reloaded = HistoryStore(url: historyURL, limit: 2)
expect(reloaded.entries == store.entries)
expect(reloaded.clear())
expect(HistoryStore(url: historyURL).entries.isEmpty)
try? FileManager.default.removeItem(at: historyURL.deletingLastPathComponent())

let corruptHistoryURL = FileManager.default.temporaryDirectory
  .appendingPathComponent("linea-lite-corrupt-history-\(UUID().uuidString)/history.json")
try FileManager.default.createDirectory(
  at: corruptHistoryURL.deletingLastPathComponent(),
  withIntermediateDirectories: true
)
let corruptHistoryData = Data("not valid json".utf8)
try corruptHistoryData.write(to: corruptHistoryURL)
let recoveredStore = HistoryStore(url: corruptHistoryURL)
expect(recoveredStore.entries.isEmpty)
guard let recoveredHistoryURL = recoveredStore.recoveredCorruptFileURL else {
  fail("Corrupt history should be preserved")
}
let recoveredHistoryData = try Data(contentsOf: recoveredHistoryURL)
expect(recoveredHistoryData == corruptHistoryData)
expect(!FileManager.default.fileExists(atPath: corruptHistoryURL.path))
expect(recoveredStore.append(history[0]))
expect(HistoryStore(url: corruptHistoryURL).entries == [history[0]])
try? FileManager.default.removeItem(at: corruptHistoryURL.deletingLastPathComponent())

print("Tests ok")
