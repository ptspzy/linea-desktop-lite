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

print("Tests ok")
