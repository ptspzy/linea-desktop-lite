enum PushToTalkTransition {
  case pressed
  case released
}

enum PushToTalkShortcut: String, CaseIterable {
  case rightOption
  case rightControl
  case rightCommand

  var title: String {
    switch self {
    case .rightOption: "Right Option"
    case .rightControl: "Right Control"
    case .rightCommand: "Right Command"
    }
  }

  var keyCode: UInt16 {
    switch self {
    case .rightOption: 61
    case .rightControl: 62
    case .rightCommand: 54
    }
  }
}

func modifierKeyPressed(
  keyCode: UInt16,
  isPressed: Bool,
  shortcut: PushToTalkShortcut
) -> Bool? {
  keyCode == shortcut.keyCode ? isPressed : nil
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
  private static let tapThreshold = 0.6
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
