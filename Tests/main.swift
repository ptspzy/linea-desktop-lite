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

print("Tests ok")
