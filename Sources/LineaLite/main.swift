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

private struct DictationResult {
  let transcript: String
  let audioDuration: TimeInterval
  let recognitionDuration: TimeInterval
}

@MainActor
private final class PushToTalkKey {
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var state = PushToTalkState()
  private var shortcut: PushToTalkShortcut
  private let onPress: () -> Void
  private let onRelease: () -> Void

  var isPressed: Bool {
    state.isPressed
  }

  init(
    shortcut: PushToTalkShortcut,
    onPress: @escaping () -> Void,
    onRelease: @escaping () -> Void
  ) {
    self.shortcut = shortcut
    self.onPress = onPress
    self.onRelease = onRelease
  }

  func updateShortcut(_ shortcut: PushToTalkShortcut) {
    self.shortcut = shortcut
    state = PushToTalkState()
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
    let keyCode = event.keyCode
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    DispatchQueue.main.async { [weak self] in
      self?.handle(keyCode: keyCode, flags: flags)
    }
  }

  private func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
    let isPressed: Bool
    switch shortcut {
    case .rightOption: isPressed = flags.contains(.option)
    case .rightControl: isPressed = flags.contains(.control)
    case .rightCommand: isPressed = flags.contains(.command)
    }
    guard let pressed = modifierKeyPressed(
      keyCode: keyCode,
      isPressed: isPressed,
      shortcut: shortcut
    ) else { return }
    handle(pressed)
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

  var isBusy: Bool {
    isRecording || isTranscribing
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

  func stopAndTranscribe(_ completion: @escaping (Result<DictationResult, Error>) -> Void) {
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
    _ completion: @escaping (Result<DictationResult, Error>) -> Void
  ) {
    isTranscribing = true
    Task { [weak self] in
      guard let self else { return }
      do {
        let recognitionStartedAt = ProcessInfo.processInfo.systemUptime
        let text = try await Task.detached(priority: .userInitiated) {
          try transcribeWithQwen(audioURL: url)
        }.value
        let recognitionDuration = ProcessInfo.processInfo.systemUptime - recognitionStartedAt
        self.finish(url: url)
        completion(.success(DictationResult(
          transcript: text,
          audioDuration: duration,
          recognitionDuration: recognitionDuration
        )))
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
  private var shortcutChoice = PushToTalkShortcut(
    rawValue: UserDefaults.standard.string(forKey: "pushToTalkShortcut") ?? ""
  ) ?? .rightOption
  private var lastDiagnosticSummary = UserDefaults.standard.string(forKey: "lastDiagnostics")
    ?? "No dictation diagnostics yet."
  private var status = "Ready"

  private let statusMenuItem = NSMenuItem()
  private let shortcutMenuItem = NSMenuItem(title: "Shortcut", action: nil, keyEquivalent: "")
  private let modelMenuItem = NSMenuItem(
    title: "Choose ASR Model...",
    action: #selector(chooseModel(_:)),
    keyEquivalent: ""
  )
  private let revealModelMenuItem = NSMenuItem(
    title: "Show ASR Model in Finder",
    action: #selector(revealModel(_:)),
    keyEquivalent: ""
  )
  private let microphoneMenuItem = NSMenuItem(
    title: "Microphone",
    action: #selector(fixMicrophonePermission(_:)),
    keyEquivalent: ""
  )
  private let accessibilityMenuItem = NSMenuItem(
    title: "Accessibility",
    action: #selector(fixAccessibilityPermission(_:)),
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
  private let diagnosticsMenuItem = NSMenuItem(
    title: "Diagnostics...",
    action: #selector(showDiagnostics(_:)),
    keyEquivalent: ""
  )

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    removeStaleCaptureFiles()
    loadSavedWorkspace()
    buildMenu()

    hotKey = PushToTalkKey(
      shortcut: shortcutChoice,
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
    let shortcutMenu = NSMenu()
    shortcutMenu.autoenablesItems = false
    for choice in PushToTalkShortcut.allCases {
      let item = NSMenuItem(
        title: choice.title,
        action: #selector(selectShortcut(_:)),
        keyEquivalent: ""
      )
      item.target = self
      item.representedObject = choice.rawValue
      shortcutMenu.addItem(item)
    }
    shortcutMenuItem.submenu = shortcutMenu
    menu.addItem(shortcutMenuItem)
    menu.addItem(NSMenuItem.separator())
    modelMenuItem.target = self
    menu.addItem(modelMenuItem)
    revealModelMenuItem.target = self
    menu.addItem(revealModelMenuItem)
    menu.addItem(NSMenuItem.separator())
    microphoneMenuItem.target = self
    menu.addItem(microphoneMenuItem)
    accessibilityMenuItem.target = self
    menu.addItem(accessibilityMenuItem)
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
    diagnosticsMenuItem.target = self
    menu.addItem(diagnosticsMenuItem)
    menu.addItem(NSMenuItem(title: "Quit Linea Lite", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
    menu.delegate = self
    statusItem.menu = menu
    refreshMenu()
  }

  func menuWillOpen(_ menu: NSMenu) {
    refreshMenu()
  }

  private var idleStatus: String {
    "Tap or hold \(shortcutChoice.title) to dictate"
  }

  @objc private func selectShortcut(_ sender: NSMenuItem) {
    guard !engine.isBusy,
          let rawValue = sender.representedObject as? String,
          let choice = PushToTalkShortcut(rawValue: rawValue) else { return }
    shortcut.reset()
    shortcutChoice = choice
    hotKey?.updateShortcut(choice)
    UserDefaults.standard.set(choice.rawValue, forKey: "pushToTalkShortcut")
    status = idleStatus
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
        status = "Recording; tap \(shortcutChoice.title) to stop"
        refreshMenu()
      }
    case .stop:
      finishDictation()
    case .start, nil:
      break
    }
  }

  private func startDictation() {
    guard !engine.isBusy, !isStarting else { return }
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
        self.status = self.idleStatus
        self.hud.hide()
        self.refreshMenu()
        return
      }

      do {
        try self.engine.start()
        self.status = self.shortcut.isLatched
          ? "Recording; tap \(self.shortcutChoice.title) to stop"
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
      status = idleStatus
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
        case .success(let result):
          let postProcessingStartedAt = ProcessInfo.processInfo.systemUptime
          let text = formattedTranscript(
            applyWorkspaceVocabulary(
              to: result.transcript,
              entries: defaultDeveloperVocabulary + self.workspaceVocabulary
            ),
            paragraphBreaks: paragraphFormattingAllowed(appName: appName)
          )
          guard !text.isEmpty else {
            self.status = "No speech detected"
            self.hud.showError()
            self.saveDiagnostics(
              audioDuration: result.audioDuration,
              recognitionDuration: result.recognitionDuration,
              postProcessingDuration: ProcessInfo.processInfo.systemUptime - postProcessingStartedAt,
              outcome: "No speech"
            )
            self.refreshMenu()
            return
          }
          let inserted = self.insertAtCursor(text)
          let saved = self.history.append(HistoryEntry(
            text: text,
            duration: result.audioDuration,
            appName: appName
          ))
          if !saved {
            self.status = inserted ? "Inserted; history was not saved" : "Copied; history was not saved"
          } else {
            self.status = inserted ? "Inserted \(text.count) chars" : "Copied; enable Accessibility to auto-insert"
          }
          self.saveDiagnostics(
            audioDuration: result.audioDuration,
            recognitionDuration: result.recognitionDuration,
            postProcessingDuration: ProcessInfo.processInfo.systemUptime - postProcessingStartedAt,
            outcome: inserted ? "Inserted" : "Copied"
          )
          self.hud.showComplete()
        case .failure(let error):
          self.status = error.localizedDescription
          self.lastDiagnosticSummary = "Last dictation failed: \(error.localizedDescription)"
          UserDefaults.standard.set(self.lastDiagnosticSummary, forKey: "lastDiagnostics")
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
    guard !isImportingModel, !engine.isBusy else { return }
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

  @objc private func revealModel(_ sender: Any?) {
    guard let modelURL = installedQwenModelURL() else { return }
    NSWorkspace.shared.activateFileViewerSelecting([modelURL])
  }

  @objc private func fixMicrophonePermission(_ sender: Any?) {
    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
      engine.requestAccess { [weak self] allowed in
        self?.status = allowed ? "Microphone permission enabled" : "Microphone permission denied"
        self?.refreshMenu()
      }
      return
    }
    openPrivacySettings("Privacy_Microphone")
  }

  @objc private func fixAccessibilityPermission(_ sender: Any?) {
    guard !AXIsProcessTrusted() else { return }
    if accessibilityTimer == nil {
      prepareAccessibility()
    } else {
      requestAccessibility()
    }
    openPrivacySettings("Privacy_Accessibility")
  }

  private func openPrivacySettings(_ pane: String) {
    guard let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
    ) else { return }
    NSWorkspace.shared.open(url)
  }

  private func beginModelImport(from sourceURL: URL) {
    isImportingModel = true
    status = "Verifying local ASR model..."
    hud.showProcessing()
    refreshMenu()
    Task { [weak self] in
      let errorMessage = await Task.detached(priority: .utility) {
        do {
          stopQwen()
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
        ? idleStatus
        : "Model ready; enable Accessibility"
      hud.showComplete()
      alert.messageText = "Speech model is ready"
      alert.informativeText = "Tap or hold \(shortcutChoice.title) in any app to dictate."
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

  @objc private func showDiagnostics(_ sender: Any?) {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "development"
    #if arch(arm64)
      let architecture = "arm64"
    #elseif arch(x86_64)
      let architecture = "x86_64"
    #else
      let architecture = "unknown"
    #endif
    let modelStatus = currentQwenModelStatus() == .ready ? "Ready" : "Missing"
    let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
      ? "Allowed"
      : "Needs attention"
    let accessibilityStatus = AXIsProcessTrusted() ? "Allowed" : "Needs attention"
    let report = """
    Linea Lite \(version)
    Architecture: \(architecture)
    ASR model: \(modelStatus)
    Microphone: \(microphoneStatus)
    Accessibility: \(accessibilityStatus)
    Shortcut: \(shortcutChoice.title)

    \(lastDiagnosticSummary)

    No transcript or audio is included.
    """
    let alert = NSAlert()
    alert.messageText = "Local Diagnostics"
    alert.informativeText = report
    alert.addButton(withTitle: "Copy")
    alert.addButton(withTitle: "Close")
    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(report, forType: .string)
    }
  }

  private func saveDiagnostics(
    audioDuration: TimeInterval,
    recognitionDuration: TimeInterval,
    postProcessingDuration: TimeInterval,
    outcome: String
  ) {
    lastDiagnosticSummary = String(
      format: "Last dictation: audio %.1fs, recognition %.2fs, formatting and insertion %.2fs, %@.",
      audioDuration,
      recognitionDuration,
      postProcessingDuration,
      outcome
    )
    UserDefaults.standard.set(lastDiagnosticSummary, forKey: "lastDiagnostics")
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

    status = "Enable Accessibility to use \(shortcutChoice.title)"
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
    status = idleStatus
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
    shortcutMenuItem.title = "Shortcut: \(shortcutChoice.title)"
    shortcutMenuItem.isEnabled = !engine.isBusy && !isStarting
    for item in shortcutMenuItem.submenu?.items ?? [] {
      item.state = item.representedObject as? String == shortcutChoice.rawValue ? .on : .off
      item.isEnabled = shortcutMenuItem.isEnabled
    }
    switch currentQwenModelStatus() {
    case .ready:
      modelMenuItem.title = "Replace ASR Model..."
      modelMenuItem.isEnabled = !isImportingModel && !engine.isBusy
      revealModelMenuItem.isEnabled = true
    case .missing:
      modelMenuItem.title = isImportingModel ? "Verifying ASR Model..." : "Choose ASR Model..."
      modelMenuItem.isEnabled = !isImportingModel && !engine.isBusy
      revealModelMenuItem.isEnabled = false
    }
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      microphoneMenuItem.title = "Microphone: Allowed"
      microphoneMenuItem.isEnabled = false
    case .notDetermined:
      microphoneMenuItem.title = "Microphone: Allow..."
      microphoneMenuItem.isEnabled = true
    case .denied, .restricted:
      microphoneMenuItem.title = "Microphone: Open Settings..."
      microphoneMenuItem.isEnabled = true
    @unknown default:
      microphoneMenuItem.title = "Microphone: Open Settings..."
      microphoneMenuItem.isEnabled = true
    }
    accessibilityMenuItem.title = AXIsProcessTrusted()
      ? "Accessibility: Allowed"
      : "Accessibility: Open Settings..."
    accessibilityMenuItem.isEnabled = !AXIsProcessTrusted()
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
