enum PushToTalkTransition {
  case pressed
  case released
}

func rightOptionPressed(keyCode: UInt16, optionPressed: Bool) -> Bool? {
  keyCode == 61 ? optionPressed : nil
}

struct PushToTalkState {
  private(set) var isPressed = false

  mutating func transition(to pressed: Bool) -> PushToTalkTransition? {
    guard pressed != isPressed else { return nil }
    isPressed = pressed
    return pressed ? .pressed : .released
  }
}

enum DictationShortcutAction {
  case start
  case continueRecording
  case stop
}

struct DictationShortcutState {
  private static let tapThreshold = 0.3
  private var pressedAt: Double?
  private(set) var isLatched = false

  var wantsRecording: Bool {
    pressedAt != nil || isLatched
  }

  mutating func press(at time: Double) -> DictationShortcutAction {
    if isLatched {
      isLatched = false
      pressedAt = nil
      return .stop
    }
    pressedAt = time
    return .start
  }

  mutating func release(at time: Double) -> DictationShortcutAction? {
    guard let pressedAt else { return nil }
    self.pressedAt = nil
    if max(0, time - pressedAt) < Self.tapThreshold {
      isLatched = true
      return .continueRecording
    }
    return .stop
  }

  mutating func reset() {
    pressedAt = nil
    isLatched = false
  }
}
