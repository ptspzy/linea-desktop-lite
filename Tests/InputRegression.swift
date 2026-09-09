import AppKit
import Foundation

func runInputRegressionTests() async throws {
  let shortcut = CustomShortcut(keyCode: 2, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue,
                                keyLabel: "D")
  precondition(shortcut.isValid)
  precondition(shortcut.title == "Ctrl+Option+D")
  precondition(applyWorkspaceVocabulary(to: "模型使用鲲三 A S R", entries: defaultDeveloperVocabulary) == "模型使用Qwen3-ASR")
  precondition(NSEvent.ModifierFlags.option.rawValue & PushToTalkShortcut.rightOption.deviceMask == 0)
  precondition((NSEvent.ModifierFlags.option.rawValue | 0x40) & PushToTalkShortcut.rightOption.deviceMask != 0)
  precondition(!CustomShortcut(keyCode: 9, modifiers: NSEvent.ModifierFlags.command.rawValue,
                              keyLabel: "V").isValid)
  precondition(!CustomShortcut(keyCode: 2, modifiers: 0, keyLabel: "D").isValid)
  precondition(!CustomShortcut(keyCode: 53, modifiers: shortcut.modifiers, keyLabel: "Escape").isValid)
  var state = CustomShortcutState()
  precondition(state.transition(keyCode: 2, type: .keyDown, flags: shortcut.flags,
                                isRepeat: false, shortcut: shortcut) == .pressed)
  precondition(state.transition(keyCode: 2, type: .keyDown, flags: shortcut.flags,
                                isRepeat: true, shortcut: shortcut) == nil)
  precondition(state.transition(keyCode: 58, type: .flagsChanged, flags: .control,
                                isRepeat: false, shortcut: shortcut) == .released)
  precondition(state.transition(keyCode: 2, type: .keyUp, flags: [],
                                isRepeat: false, shortcut: shortcut) == nil)
  precondition(state.transition(keyCode: 2, type: .keyDown, flags: [.control, .option, .shift],
                                isRepeat: false, shortcut: shortcut) == nil)
  precondition(state.transition(keyCode: 2, type: .keyDown, flags: shortcut.flags,
                                isRepeat: false, shortcut: shortcut) == .pressed)
  precondition(state.transition(keyCode: 2, type: .keyUp, flags: shortcut.flags,
                                isRepeat: false, shortcut: shortcut) == .released)
  precondition(canAutomaticallyPaste(targetIsFocused: true, modifiers: []))
  precondition(!canAutomaticallyPaste(targetIsFocused: false, modifiers: []))
  precondition(!canAutomaticallyPaste(targetIsFocused: true, modifiers: .option))

  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("retry.wav")
  let now = Date(timeIntervalSince1970: 1_000)
  let recovery = CaptureRecovery()
  precondition(recovery.available(at: now) == nil)
  try Data([1, 2, 3]).write(to: url)
  recovery.retain(url: url, duration: 32, now: now)
  precondition(recovery.available(at: now)?.duration == 32)
  let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
  precondition(permissions == 0o600)
  precondition(recovery.available(at: now.addingTimeInterval(599)) != nil)
  precondition(recovery.available(at: now.addingTimeInterval(600)) == nil)
  precondition(!FileManager.default.fileExists(atPath: url.path))
  try Data([1]).write(to: url)
  recovery.retain(url: url, duration: 1, now: now)
  recovery.discard(ifMatching: directory.appendingPathComponent("different.wav"))
  precondition(recovery.available(at: now) != nil)
  recovery.discard(ifMatching: url)
  precondition(recovery.available(at: now) == nil)
  let log = directory.appendingPathComponent("linea-lite-process-test.log.stderr")
  try Data([1]).write(to: log)
  try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-601)], ofItemAtPath: log.path)
  removeStaleCaptureFiles(in: directory, now: now)
  precondition(!FileManager.default.fileExists(atPath: log.path))
  let cancelStarted = ProcessInfo.processInfo.systemUptime
  let processTask = Task.detached {
    try processOutput(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 10)
  }
  try await Task.sleep(for: .milliseconds(50))
  processTask.cancel()
  do {
    _ = try await processTask.value
    preconditionFailure("Cancelled recognition process must not finish as a success")
  } catch is CancellationError {
    precondition(ProcessInfo.processInfo.systemUptime - cancelStarted < 2, "Cancellation must stop work promptly")
  }
  print("PASS: custom shortcuts, focus guard and private retry lifecycle")
}
