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
