import Foundation

assert(cleanedTranscript("  hello\n\nworld  ") == "hello world")
assert(cleanedTranscript("Linea   Lite") == "Linea Lite")
assert(cleanedTranscript("") == "")

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
