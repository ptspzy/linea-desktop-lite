import AppKit
import ApplicationServices
import AVFoundation
import Speech

private let pasteKeyCode: CGKeyCode = 9

private enum DictationError: LocalizedError {
  case busy
  case notAvailable
  case noOnDeviceRecognition
  case noAudio

  var errorDescription: String? {
    switch self {
    case .busy:
      "Still working."
    case .notAvailable:
      "Speech recognition is not available."
    case .noOnDeviceRecognition:
      "On-device zh-CN recognition is not available."
    case .noAudio:
      "No audio was recorded."
    }
  }
}

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
      self?.handle(event)
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      self?.handle(event)
      return event
    }
  }

  private func handle(_ event: NSEvent) {
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

  deinit {
    if let globalMonitor {
      NSEvent.removeMonitor(globalMonitor)
    }
    if let localMonitor {
      NSEvent.removeMonitor(localMonitor)
    }
  }
}

private final class DictationEngine {
  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
  private var recorder: AVAudioRecorder?
  private var task: SFSpeechRecognitionTask?
  private var startedAt: Date?
  private var audioURL: URL?
  private var isTranscribing = false

  var isRecording: Bool {
    recorder?.isRecording == true
  }

  var audioLevel: Double {
    guard let recorder, recorder.isRecording else { return 0 }
    recorder.updateMeters()
    return captureAudioLevel(decibels: recorder.averagePower(forChannel: 0))
  }

  func requestAccess(_ completion: @escaping (Bool) -> Void) {
    SFSpeechRecognizer.requestAuthorization { speechStatus in
      AVCaptureDevice.requestAccess(for: .audio) { microphoneAllowed in
        DispatchQueue.main.async {
          completion(speechStatus == .authorized && microphoneAllowed)
        }
      }
    }
  }

  func start() throws {
    guard !isTranscribing else {
      throw DictationError.busy
    }
    guard let recognizer, recognizer.isAvailable else {
      throw DictationError.notAvailable
    }
    guard recognizer.supportsOnDeviceRecognition else {
      throw DictationError.noOnDeviceRecognition
    }

    stopRecording()
    task?.cancel()

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("linea-lite-\(UUID().uuidString).m4a")
    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
      AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 1,
      AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]

    let recorder = try AVAudioRecorder(url: url, settings: settings)
    recorder.isMeteringEnabled = true
    recorder.prepareToRecord()
    recorder.record()

    self.recorder = recorder
    startedAt = Date()
    audioURL = url
  }

  func stopAndTranscribe(_ completion: @escaping (Result<(String, TimeInterval), Error>) -> Void) {
    guard let url = audioURL, let startedAt else {
      completion(.failure(DictationError.noAudio))
      return
    }

    let duration = Date().timeIntervalSince(startedAt)
    stopRecording()
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
    guard let recognizer else {
      completion(.failure(DictationError.notAvailable))
      return
    }

    isTranscribing = true
    var didFinish = false
    var transcripts = SpeechResultAccumulator()
    let request = SFSpeechURLRecognitionRequest(url: url)
    request.requiresOnDeviceRecognition = true
    request.addsPunctuation = true
    request.shouldReportPartialResults = true
    request.taskHint = .dictation

    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self, !didFinish else { return }

      if let result,
         let text = transcripts.accept(
           text: result.bestTranscription.formattedString,
           isFinal: result.isFinal
         ) {
        didFinish = true
        self.finish(url: url)
        completion(.success((text, duration)))
      } else if let error {
        didFinish = true
        self.finish(url: url)
        completion(.failure(error))
      }
    }
  }

  private func finish(url: URL) {
    isTranscribing = false
    task = nil
    audioURL = nil
    try? FileManager.default.removeItem(at: url)
  }
}

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
  private var status = "Hold Right Option to dictate"

  private let statusMenuItem = NSMenuItem()
  private let clearHistoryMenuItem = NSMenuItem(
    title: "Clear History...",
    action: #selector(clearHistory(_:)),
    keyEquivalent: ""
  )

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    buildMenu()

    hotKey = PushToTalkKey(
      onPress: { [weak self] in self?.startDictation() },
      onRelease: { [weak self] in self?.finishDictation() }
    )
    prepareAccessibility()
  }

  private func buildMenu() {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let historyMenuItem = NSMenuItem()
    historyView.frame.size = historyView.intrinsicContentSize
    historyMenuItem.view = historyView
    menu.addItem(historyMenuItem)
    menu.addItem(NSMenuItem.separator())
    statusMenuItem.isEnabled = false
    menu.addItem(statusMenuItem)
    let shortcutMenuItem = NSMenuItem(title: "Shortcut: hold Right Option", action: nil, keyEquivalent: "")
    shortcutMenuItem.isEnabled = false
    menu.addItem(shortcutMenuItem)
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

  private func startDictation() {
    guard !engine.isRecording, !isStarting else { return }
    isStarting = true
    targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName
    hud.showRecording()
    status = "Requesting permission..."
    refreshMenu()

    engine.requestAccess { [weak self] allowed in
      guard let self else { return }
      self.isStarting = false
      guard allowed else {
        self.targetAppName = nil
        self.status = "Microphone or speech permission denied"
        self.hud.showError()
        self.refreshMenu()
        return
      }
      guard self.hotKey?.isPressed == true else {
        self.targetAppName = nil
        self.status = "Hold Right Option to dictate"
        self.hud.hide()
        self.refreshMenu()
        return
      }

      do {
        try self.engine.start()
        self.status = "Recording..."
        self.startLevelUpdates()
      } catch {
        self.targetAppName = nil
        self.status = error.localizedDescription
        self.hud.showError()
      }
      self.refreshMenu()
    }
  }

  private func finishDictation() {
    guard engine.isRecording else {
      hud.hide()
      status = "Hold Right Option to dictate"
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
            transcript,
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
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)

    guard AXIsProcessTrusted() else {
      requestAccessibility()
      return false
    }

    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: pasteKeyCode, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: pasteKeyCode, keyDown: false)
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
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

  private func requestAccessibility() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
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
      self?.enableHotKey()
    }
  }

  private func enableHotKey() {
    accessibilityTimer = nil
    hotKey?.register()
    status = "Hold Right Option to dictate"
    refreshMenu()
  }

  private func startLevelUpdates() {
    stopLevelUpdates()
    let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.hud.setLevel(self.engine.audioLevel)
    }
    levelTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func stopLevelUpdates() {
    levelTimer?.invalidate()
    levelTimer = nil
  }

  private func refreshMenu() {
    statusItem.button?.title = hotKey?.isPressed == true ? "● Linea" : "Linea \(history.entries.count)"
    statusMenuItem.title = status
    clearHistoryMenuItem.isEnabled = !history.entries.isEmpty
    historyView.update(entries: history.entries)
  }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
