import Foundation

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
    input: "我有三点 第一点是速度 第二点是稳定性 第三点是兼容性",
    expected: "我有三点：\n1. 第一点是，速度\n2. 第二点是，稳定性\n3. 第三点是，兼容性"
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

assert(captureAudioLevel(decibels: -160) == 0)
assert((0.50...0.55).contains(captureAudioLevel(decibels: -20)))
assert(captureAudioLevel(decibels: 0) == 1)

var speechResults = SpeechResultAccumulator()
assert(speechResults.accept(text: "西红柿", isFinal: false) == nil)
assert(speechResults.accept(text: "", isFinal: true) == "西红柿")

var longSpeechResults = SpeechResultAccumulator()
let completePartial = "第一段记录项目背景和目标 第二段确认关键数字是二十五 第三段整理后续行动"
assert(longSpeechResults.accept(text: completePartial, isFinal: false) == nil)
assert(longSpeechResults.accept(text: "第三段整理后续行动", isFinal: true) == completePartial)

var segmentedSpeechResults = SpeechResultAccumulator()
let earlierPartial = "第一段记录项目背景和目标 第二段确认关键数字是二十五"
assert(segmentedSpeechResults.accept(text: earlierPartial, isFinal: false) == nil)
assert(
  segmentedSpeechResults.accept(text: "第三段整理后续行动", isFinal: true)
    == earlierPartial + " 第三段整理后续行动"
)

var overlappingSpeechResults = SpeechResultAccumulator()
assert(overlappingSpeechResults.accept(text: "第一段内容 第二段关键数字", isFinal: false) == nil)
assert(
  overlappingSpeechResults.accept(text: "关键数字是二十五 第三段内容", isFinal: true)
    == "第一段内容 第二段关键数字是二十五 第三段内容"
)

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
