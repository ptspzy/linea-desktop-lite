import AppKit
import ApplicationServices
import AVFoundation
import UniformTypeIdentifiers

private let pasteKeyCode: CGKeyCode = 9

private enum DictationError: LocalizedError {
  case busy
  case noAudio

  var errorDescription: String? {
    switch self {
    case .busy:
      "Still working."
    case .noAudio:
      "No audio was recorded."
    }
  }
}

@MainActor
private final class PushToTalkKey {
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var state = PushToTalkState()
  private let onPress: () -> Void
  private let onRelease: () -> Void

  var isPressed: Bool {
    state.isPressed
  }

  init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
    self.onPress = onPress
    self.onRelease = onRelease
  }

  func register() {
    guard globalMonitor == nil, localMonitor == nil else { return }
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      self?.enqueue(event)
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      self?.enqueue(event)
      return event
    }
  }

  nonisolated private func enqueue(_ event: NSEvent) {
    guard let pressed = rightOptionPressed(
      keyCode: event.keyCode,
      optionPressed: event.modifierFlags
        .intersection(.deviceIndependentFlagsMask)
        .contains(.option)
    ) else { return }
    DispatchQueue.main.async { [weak self] in
      self?.handle(pressed)
    }
  }

  private func handle(_ pressed: Bool) {
    switch state.transition(to: pressed) {
    case .pressed:
      onPress()
    case .released:
      onRelease()
    case nil:
      break
    }
  }

}

@MainActor
private final class DictationEngine {
  private var recorder: AVAudioRecorder?
  private var startedAt: Date?
  private var audioURL: URL?
  private var isTranscribing = false

  var isRecording: Bool {
    recorder?.isRecording == true
  }

  var recordingDuration: TimeInterval {
    startedAt.map { Date().timeIntervalSince($0) } ?? 0
  }

  var audioLevel: Double {
    guard let recorder, recorder.isRecording else { return 0 }
    recorder.updateMeters()
    return captureAudioLevel(decibels: recorder.averagePower(forChannel: 0))
  }

  func requestAccess(_ completion: @escaping @Sendable @MainActor (Bool) -> Void) {
    AVCaptureDevice.requestAccess(for: .audio) { microphoneAllowed in
      DispatchQueue.main.async {
        completion(microphoneAllowed)
      }
    }
  }

  func start() throws {
    guard !isTranscribing else {
      throw DictationError.busy
    }

    stopRecording()

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("linea-lite-\(UUID().uuidString).wav")
    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatLinearPCM),
      AVSampleRateKey: 16_000,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
    ]

    let recorder = try AVAudioRecorder(url: url, settings: settings)
    recorder.isMeteringEnabled = true
    recorder.prepareToRecord()
    recorder.record()

    self.recorder = recorder
    startedAt = Date()
    audioURL = url
    Task.detached(priority: .utility) { prepareQwen() }
  }

  func stopAndTranscribe(_ completion: @escaping (Result<(String, TimeInterval), Error>) -> Void) {
    guard let url = audioURL, let startedAt else {
      completion(.failure(DictationError.noAudio))
      return
    }

    let duration = Date().timeIntervalSince(startedAt)
    stopRecording()
    guard let file = try? AVAudioFile(forReading: url), file.length > 0 else {
      Task.detached(priority: .utility) { stopQwen() }
      finish(url: url)
      completion(.failure(DictationError.noAudio))
      return
    }
    transcribe(url: url, duration: duration, completion)
  }

  private func stopRecording() {
    recorder?.stop()
    recorder = nil
    startedAt = nil
  }

  private func transcribe(
    url: URL,
    duration: TimeInterval,
    _ completion: @escaping (Result<(String, TimeInterval), Error>) -> Void
  ) {
    isTranscribing = true
    Task { [weak self] in
      guard let self else { return }
      do {
        let text = try await Task.detached(priority: .userInitiated) {
          try transcribeWithQwen(audioURL: url)
        }.value
        self.finish(url: url)
        completion(.success((text, duration)))
      } catch {
        self.finish(url: url)
        completion(.failure(error))
      }
    }
  }

  private func finish(url: URL) {
    isTranscribing = false
    audioURL = nil
    try? FileManager.default.removeItem(at: url)
  }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let engine = DictationEngine()
  private let history = HistoryStore()
  private let historyView = HistoryMenuView()
  private let hud = CaptureHUD()
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private var hotKey: PushToTalkKey?
  private var accessibilityTimer: Timer?
  private var levelTimer: Timer?
  private var targetAppName: String?
  private var isStarting = false
  private var isImportingModel = false
  private var hasPromptedForModel = false
  private var workspaceURL: URL?
  private var workspaceVocabulary: [WorkspaceVocabularyEntry] = []
  private var shortcut = DictationShortcutState()
  private var status = "Tap or hold Right Option to dictate"

  private let statusMenuItem = NSMenuItem()
  private let modelMenuItem = NSMenuItem(
    title: "Choose ASR Model...",
    action: #selector(chooseModel(_:)),
    keyEquivalent: ""
  )
  private let workspaceStatusMenuItem = NSMenuItem()
  private let chooseWorkspaceMenuItem = NSMenuItem(
    title: "Choose Workspace...",
    action: #selector(chooseWorkspace(_:)),
    keyEquivalent: ""
  )
  private let clearWorkspaceMenuItem = NSMenuItem(
    title: "Clear Workspace",
    action: #selector(clearWorkspace(_:)),
    keyEquivalent: ""
  )
  private let clearHistoryMenuItem = NSMenuItem(
    title: "Clear History...",
    action: #selector(clearHistory(_:)),
    keyEquivalent: ""
  )

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    removeStaleCaptureFiles()
    loadSavedWorkspace()
    buildMenu()

    hotKey = PushToTalkKey(
      onPress: { [weak self] in self?.handleShortcutPress() },
      onRelease: { [weak self] in self?.handleShortcutRelease() }
    )
    prepareAccessibility()
    DispatchQueue.main.async { [weak self] in
      self?.promptForModelIfNeeded()
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    stopQwen()
  }

  private func buildMenu() {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let historyMenuItem = NSMenuItem()
    historyView.frame.size = historyView.intrinsicContentSize
    historyMenuItem.view = historyView
    menu.addItem(historyMenuItem)
    if let backupURL = history.recoveredCorruptFileURL {
      let recoveryItem = NSMenuItem(
        title: "Recovered history: \(backupURL.lastPathComponent)",
        action: nil,
        keyEquivalent: ""
      )
      recoveryItem.isEnabled = false
      menu.addItem(recoveryItem)
    }
    menu.addItem(NSMenuItem.separator())
    statusMenuItem.isEnabled = false
    menu.addItem(statusMenuItem)
    let shortcutMenuItem = NSMenuItem(title: "Right Option: tap or hold", action: nil, keyEquivalent: "")
    shortcutMenuItem.isEnabled = false
    menu.addItem(shortcutMenuItem)
    menu.addItem(NSMenuItem.separator())
    modelMenuItem.target = self
    menu.addItem(modelMenuItem)
    menu.addItem(NSMenuItem.separator())
    workspaceStatusMenuItem.isEnabled = false
    menu.addItem(workspaceStatusMenuItem)
    chooseWorkspaceMenuItem.target = self
    menu.addItem(chooseWorkspaceMenuItem)
    clearWorkspaceMenuItem.target = self
    menu.addItem(clearWorkspaceMenuItem)
    menu.addItem(NSMenuItem.separator())
    clearHistoryMenuItem.target = self
    menu.addItem(clearHistoryMenuItem)
    menu.addItem(NSMenuItem(title: "Quit Linea Lite", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
    menu.delegate = self
    statusItem.menu = menu
    refreshMenu()
  }

  func menuWillOpen(_ menu: NSMenu) {
    refreshMenu()
  }

  private func handleShortcutPress() {
    switch shortcut.press(at: ProcessInfo.processInfo.systemUptime) {
    case .start:
      startDictation()
    case .stop:
      finishDictation()
    case .continueRecording:
      break
    }
  }

  private func handleShortcutRelease() {
    switch shortcut.release(at: ProcessInfo.processInfo.systemUptime) {
    case .continueRecording:
      if engine.isRecording {
        status = "Recording; tap Right Option to stop"
        refreshMenu()
      }
    case .stop:
      finishDictation()
    case .start, nil:
      break
    }
  }

  private func startDictation() {
    guard !engine.isRecording, !isStarting else { return }
    guard currentQwenModelStatus() == .ready else {
      shortcut.reset()
      promptForModelIfNeeded(force: true)
      return
    }
    isStarting = true
    targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName
    hud.showRecording()
    status = "Requesting permission..."
    refreshMenu()

    engine.requestAccess { [weak self] allowed in
      guard let self else { return }
      self.isStarting = false
      guard allowed else {
        self.shortcut.reset()
        self.targetAppName = nil
        self.status = "Microphone permission denied"
        self.hud.showError()
        self.refreshMenu()
        return
      }
      guard self.shortcut.wantsRecording else {
        self.targetAppName = nil
        self.status = "Tap or hold Right Option to dictate"
        self.hud.hide()
        self.refreshMenu()
        return
      }

      do {
        try self.engine.start()
        self.status = self.shortcut.isLatched
          ? "Recording; tap Right Option to stop"
          : "Recording..."
        self.startLevelUpdates()
      } catch {
        self.shortcut.reset()
        self.targetAppName = nil
        self.status = error.localizedDescription
        self.hud.showError()
      }
      self.refreshMenu()
    }
  }

  private func finishDictation() {
    shortcut.reset()
    guard engine.isRecording else {
      hud.hide()
      status = "Tap or hold Right Option to dictate"
      refreshMenu()
      return
    }
    stopLevelUpdates()
    hud.showProcessing()
    status = "Transcribing..."
    refreshMenu()

    engine.stopAndTranscribe { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        let appName = self.targetAppName
        self.targetAppName = nil

        switch result {
        case .success((let transcript, let duration)):
          let text = formattedTranscript(
            applyWorkspaceVocabulary(
              to: transcript,
              entries: defaultDeveloperVocabulary + self.workspaceVocabulary
            ),
            paragraphBreaks: paragraphFormattingAllowed(appName: appName)
          )
          guard !text.isEmpty else {
            self.status = "No speech detected"
            self.hud.showError()
            self.refreshMenu()
            return
          }
          let inserted = self.insertAtCursor(text)
          let saved = self.history.append(HistoryEntry(
            text: text,
            duration: duration,
            appName: appName
          ))
          if !saved {
            self.status = inserted ? "Inserted; history was not saved" : "Copied; history was not saved"
          } else {
            self.status = inserted ? "Inserted \(text.count) chars" : "Copied; enable Accessibility to auto-insert"
          }
          self.hud.showComplete()
        case .failure(let error):
          self.status = error.localizedDescription
          self.hud.showError()
        }
        self.refreshMenu()
      }
    }
  }

  private func insertAtCursor(_ text: String) -> Bool {
    let pasteboard = NSPasteboard.general
    let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
    guard let dictationChangeCount = setPasteboardText(text, on: pasteboard) else {
      snapshot.restore(to: pasteboard, ifUnchangedSince: pasteboard.changeCount)
      return false
    }

    guard AXIsProcessTrusted() else {
      requestAccessibility()
      return false
    }

    let source = CGEventSource(stateID: .hidSystemState)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: pasteKeyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: pasteKeyCode, keyDown: false) else {
      snapshot.restore(to: pasteboard, ifUnchangedSince: dictationChangeCount)
      return false
    }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      snapshot.restore(to: pasteboard, ifUnchangedSince: dictationChangeCount)
    }
    return true
  }

  @objc private func clearHistory(_ sender: Any?) {
    let alert = NSAlert()
    alert.messageText = "Clear local history?"
    alert.informativeText = "This removes transcript text and activity statistics from this Mac."
    alert.addButton(withTitle: "Clear")
    alert.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    status = history.clear() ? "History cleared" : "Could not clear history"
    refreshMenu()
  }

  private func promptForModelIfNeeded(force: Bool = false) {
    guard currentQwenModelStatus() != .ready, force || !hasPromptedForModel else { return }
    hasPromptedForModel = true

    let alert = NSAlert()
    alert.messageText = "Choose the local speech model"
    alert.informativeText = "Select the supplied Qwen3-ASR model (about 602 MB). Linea verifies it, moves it into local app storage, and keeps speech recognition on this Mac."
    alert.addButton(withTitle: "Choose Model")
    alert.addButton(withTitle: "Later")
    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn {
      chooseModel(nil)
    }
  }

  @objc private func chooseModel(_ sender: Any?) {
    guard !isImportingModel else { return }
    let panel = NSOpenPanel()
    panel.title = "Choose Qwen3-ASR Model"
    panel.message = "Select qwen3-asr-0.6b-q4_k.gguf. It will be verified and moved into Linea Lite."
    panel.prompt = "Use Model"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    if let ggufType = UTType(filenameExtension: "gguf") {
      panel.allowedContentTypes = [ggufType]
    }
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
    beginModelImport(from: sourceURL)
  }

  private func beginModelImport(from sourceURL: URL) {
    isImportingModel = true
    status = "Verifying local ASR model..."
    hud.showProcessing()
    refreshMenu()
    Task { [weak self] in
      let errorMessage = await Task.detached(priority: .utility) {
        do {
          try installQwenModel(from: sourceURL)
          return nil as String?
        } catch {
          return error.localizedDescription
        }
      }.value
      self?.finishModelImport(errorMessage: errorMessage)
    }
  }

  private func finishModelImport(errorMessage: String?) {
    isImportingModel = false
    let alert = NSAlert()
    if let errorMessage {
      status = "ASR model import failed"
      hud.showError()
      alert.messageText = "Could not use this model"
      alert.informativeText = errorMessage
      alert.addButton(withTitle: "OK")
    } else {
      status = AXIsProcessTrusted()
        ? "Tap or hold Right Option to dictate"
        : "Model ready; enable Accessibility"
      hud.showComplete()
      alert.messageText = "Speech model is ready"
      alert.informativeText = "Tap or hold Right Option in any app to dictate."
      alert.addButton(withTitle: "Done")
    }
    refreshMenu()
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }

  @objc private func chooseWorkspace(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.message = "Choose the workspace whose local terms Linea should preserve."
    panel.prompt = "Choose"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    setWorkspace(url)
  }

  @objc private func clearWorkspace(_ sender: Any?) {
    workspaceURL = nil
    workspaceVocabulary = []
    UserDefaults.standard.removeObject(forKey: "workspacePath")
    status = "Workspace vocabulary cleared"
    refreshMenu()
  }

  private func loadSavedWorkspace() {
    guard let path = UserDefaults.standard.string(forKey: "workspacePath") else { return }
    setWorkspace(URL(fileURLWithPath: path), persist: false)
  }

  private func setWorkspace(_ url: URL, persist: Bool = true) {
    do {
      let vocabulary = try loadWorkspaceVocabulary(from: url)
      workspaceURL = url
      workspaceVocabulary = vocabulary
      if persist { UserDefaults.standard.set(url.path, forKey: "workspacePath") }
      status = "Loaded \(vocabulary.count) workspace terms"
    } catch {
      status = "Workspace vocabulary: \(error.localizedDescription)"
    }
    refreshMenu()
  }

  private func requestAccessibility() {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
  }

  private func prepareAccessibility() {
    guard !AXIsProcessTrusted() else {
      enableHotKey()
      return
    }

    status = "Enable Accessibility to use Right Option"
    refreshMenu()
    requestAccessibility()
    accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
      guard AXIsProcessTrusted() else { return }
      timer.invalidate()
      MainActor.assumeIsolated {
        self?.enableHotKey()
      }
    }
  }

  private func enableHotKey() {
    accessibilityTimer = nil
    hotKey?.register()
    status = "Tap or hold Right Option to dictate"
    refreshMenu()
  }

  private func startLevelUpdates() {
    stopLevelUpdates()
    let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        if captureShouldAutomaticallyStop(duration: self.engine.recordingDuration) {
          self.finishDictation()
          return
        }
        self.hud.setLevel(self.engine.audioLevel)
      }
    }
    levelTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func stopLevelUpdates() {
    levelTimer?.invalidate()
    levelTimer = nil
  }

  private func refreshMenu() {
    statusItem.button?.title = shortcut.wantsRecording || engine.isRecording
      ? "● Linea"
      : "Linea \(history.entries.count)"
    statusMenuItem.title = status
    switch currentQwenModelStatus() {
    case .ready:
      modelMenuItem.title = "ASR Model: Ready"
      modelMenuItem.isEnabled = false
    case .missing:
      modelMenuItem.title = isImportingModel ? "Verifying ASR Model..." : "Choose ASR Model..."
      modelMenuItem.isEnabled = !isImportingModel
    }
    workspaceStatusMenuItem.title = workspaceURL.map { "Workspace: \($0.lastPathComponent)" }
      ?? "Workspace: None"
    clearWorkspaceMenuItem.isEnabled = workspaceURL != nil
    clearHistoryMenuItem.isEnabled = !history.entries.isEmpty
    historyView.update(entries: history.entries)
  }
}

MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.run()
}
