import AppKit

struct CustomShortcut: Codable, Equatable {
  let keyCode: UInt16
  let modifiers: UInt
  let keyLabel: String

  var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
  var title: String {
    [(NSEvent.ModifierFlags.control, "Ctrl"), (.option, "Option"), (.shift, "Shift"), (.command, "Cmd")]
      .filter { flags.contains($0.0) }.map(\.1).joined(separator: "+") + "+" + keyLabel
  }

  var isValid: Bool {
    let allowed: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    guard modifiers == flags.intersection(allowed).rawValue,
          !flags.intersection([.control, .option, .command]).isEmpty,
          keyCode < 128, ![53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode),
          !keyLabel.isEmpty, keyLabel.count <= 16,
          !keyLabel.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return false }
    // Common editing/system shortcuts must remain available in the target application.
    if flags == .command && [0, 6, 7, 8, 9, 12, 13, 48, 49].contains(keyCode) { return false }
    if flags == [.command, .shift] && [3, 4, 5].contains(keyCode) { return false }
    if flags == [.control, .command] && keyCode == 12 { return false }
    return true
  }
}

struct CustomShortcutState {
  private(set) var isPressed = false

  mutating func transition(
    keyCode: UInt16, type: NSEvent.EventType, flags: NSEvent.ModifierFlags,
    isRepeat: Bool, shortcut: CustomShortcut
  ) -> PushToTalkTransition? {
    let held = flags.intersection([.control, .option, .shift, .command])
    if isPressed && ((type == .keyUp && keyCode == shortcut.keyCode)
      || (type == .flagsChanged && !held.isSuperset(of: shortcut.flags))) {
      isPressed = false
      return .released
    }
    if !isPressed && type == .keyDown && !isRepeat && keyCode == shortcut.keyCode
      && held == shortcut.flags && shortcut.isValid {
      isPressed = true
      return .pressed
    }
    return nil
  }
}

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

  // Device-side masks from IOKit/IOLLEvent.h distinguish the two modifier keys.
  var deviceMask: UInt {
    switch self {
    case .rightOption: 0x40
    case .rightControl: 0x2000
    case .rightCommand: 0x10
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
