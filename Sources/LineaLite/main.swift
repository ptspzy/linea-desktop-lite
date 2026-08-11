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
  private var isPressed = false
  private let onPress: () -> Void
  private let onRelease: () -> Void

  init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
    self.onPress = onPress
    self.onRelease = onRelease
  }

  func register() {
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      self?.handle(event)
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      self?.handle(event)
      return event
    }
  }

  private func handle(_ event: NSEvent) {
    let pressed = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .contains(.control)
    guard pressed != isPressed else { return }

    isPressed = pressed
    if pressed {
      onPress()
    } else {
      onRelease()
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
    let request = SFSpeechURLRecognitionRequest(url: url)
    request.requiresOnDeviceRecognition = true

    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self, !didFinish else { return }

      if let result, result.isFinal {
        didFinish = true
        self.finish(url: url)
        completion(.success((cleanedTranscript(result.bestTranscription.formattedString), duration)))
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

private final class AppDelegate: NSObject, NSApplicationDelegate {
  private let engine = DictationEngine()
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private var hotKey: PushToTalkKey?
  private var status = "Hold Control to dictate"
  private var recordings = 0
  private var seconds: TimeInterval = 0
  private var characters = 0

  private let statusMenuItem = NSMenuItem()
  private let statsMenuItem = NSMenuItem()

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    buildMenu()
    requestAccessibility()

    hotKey = PushToTalkKey(
      onPress: { [weak self] in self?.startDictation() },
      onRelease: { [weak self] in self?.finishDictation() }
    )
    hotKey?.register()
    refreshMenu()
  }

  private func buildMenu() {
    let menu = NSMenu()
    statusMenuItem.isEnabled = false
    statsMenuItem.isEnabled = false
    menu.addItem(statusMenuItem)
    menu.addItem(statsMenuItem)
    menu.addItem(NSMenuItem.separator())
    menu.addItem(NSMenuItem(title: "Shortcut: hold Control", action: nil, keyEquivalent: ""))
    menu.addItem(NSMenuItem.separator())
    menu.addItem(NSMenuItem(title: "Quit Linea Lite", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
    statusItem.menu = menu
  }

  private func startDictation() {
    guard !engine.isRecording else { return }
    status = "Requesting permission..."
    refreshMenu()

    engine.requestAccess { [weak self] allowed in
      guard let self else { return }
      guard allowed else {
        self.status = "Microphone or speech permission denied"
        self.refreshMenu()
        return
      }

      do {
        try self.engine.start()
        self.status = "Recording..."
      } catch {
        self.status = error.localizedDescription
      }
      self.refreshMenu()
    }
  }

  private func finishDictation() {
    guard engine.isRecording else { return }
    status = "Transcribing..."
    refreshMenu()

    engine.stopAndTranscribe { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }

        switch result {
        case .success((let text, let duration)):
          guard !text.isEmpty else {
            self.status = "No speech detected"
            self.refreshMenu()
            return
          }
          self.recordings += 1
          self.seconds += duration
          self.characters += text.count
          self.insertAtCursor(text)
          self.status = "Inserted \(text.count) chars"
        case .failure(let error):
          self.status = error.localizedDescription
        }
        self.refreshMenu()
      }
    }
  }

  private func insertAtCursor(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)

    guard AXIsProcessTrusted() else {
      requestAccessibility()
      status = "Copied; enable Accessibility to auto-insert"
      return
    }

    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: pasteKeyCode, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: pasteKeyCode, keyDown: false)
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
  }

  private func requestAccessibility() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
  }

  private func refreshMenu() {
    statusItem.button?.title = engine.isRecording ? "● Linea" : "Linea \(recordings)"
    statusMenuItem.title = status
    statsMenuItem.title = "\(recordings) clips · \(Int(seconds))s · \(characters) chars"
  }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
