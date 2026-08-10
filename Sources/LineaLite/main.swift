import AppKit
import AVFoundation
import Speech

final class SpeechRecorder {
  private let audioEngine = AVAudioEngine()
  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?

  var onText: (String) -> Void = { _ in }
  var onStatus: (String) -> Void = { _ in }

  var isRecording: Bool {
    audioEngine.isRunning
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
    guard let recognizer, recognizer.isAvailable else {
      onStatus("Speech recognition is not available.")
      return
    }

    stop()

    guard recognizer.supportsOnDeviceRecognition else {
      onStatus("On-device speech recognition is not available for zh-CN.")
      return
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.requiresOnDeviceRecognition = true
    self.request = request

    let input = audioEngine.inputNode
    let format = input.outputFormat(forBus: 0)
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
      request?.append(buffer)
    }

    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      DispatchQueue.main.async {
        if let text = result?.bestTranscription.formattedString {
          self?.onText(cleanedTranscript(text))
        }
        if error != nil {
          self?.stop()
          self?.onStatus("Stopped.")
        }
      }
    }

    audioEngine.prepare()
    try audioEngine.start()
    onStatus("Listening...")
  }

  func stop() {
    if audioEngine.isRunning {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
    }
    request?.endAudio()
    task?.cancel()
    request = nil
    task = nil
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let recorder = SpeechRecorder()
  private let statusLabel = NSTextField(labelWithString: "Ready.")
  private let textView = NSTextView()
  private let recordButton = NSButton(title: "Start recording", target: nil, action: nil)
  private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
  private let clearButton = NSButton(title: "Clear", target: nil, action: nil)

  private var window: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    buildWindow()

    recorder.onText = { [weak self] text in
      self?.textView.string = text
    }
    recorder.onStatus = { [weak self] status in
      self?.statusLabel.stringValue = status
      self?.recordButton.title = self?.recorder.isRecording == true ? "Stop recording" : "Start recording"
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  private func buildWindow() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Linea Lite"
    window.center()

    let title = NSTextField(labelWithString: "Linea Lite")
    title.font = .systemFont(ofSize: 28, weight: .semibold)

    statusLabel.textColor = .secondaryLabelColor

    textView.font = .systemFont(ofSize: 18)
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.string = ""

    let scrollView = NSScrollView()
    scrollView.borderType = .bezelBorder
    scrollView.hasVerticalScroller = true
    scrollView.documentView = textView

    recordButton.bezelStyle = .rounded
    recordButton.target = self
    recordButton.action = #selector(toggleRecording)

    copyButton.bezelStyle = .rounded
    copyButton.target = self
    copyButton.action = #selector(copyTranscript)

    clearButton.bezelStyle = .rounded
    clearButton.target = self
    clearButton.action = #selector(clearTranscript)

    let controls = NSStackView(views: [recordButton, copyButton, clearButton])
    controls.orientation = .horizontal
    controls.spacing = 8

    let stack = NSStackView(views: [title, statusLabel, scrollView, controls])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 14
    stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
    stack.translatesAutoresizingMaskIntoConstraints = false

    window.contentView = NSView()
    window.contentView?.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
      stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
      stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
      scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
      scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
    ])

    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    self.window = window
  }

  @objc private func toggleRecording() {
    if recorder.isRecording {
      recorder.stop()
      statusLabel.stringValue = "Stopped."
      recordButton.title = "Start recording"
      return
    }

    statusLabel.stringValue = "Requesting permission..."
    recorder.requestAccess { [weak self] allowed in
      guard let self else { return }
      guard allowed else {
        self.statusLabel.stringValue = "Microphone or speech permission was denied."
        return
      }
      do {
        try self.recorder.start()
        self.recordButton.title = "Stop recording"
      } catch {
        self.statusLabel.stringValue = "Could not start recording: \(error.localizedDescription)"
      }
    }
  }

  @objc private func copyTranscript() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(cleanedTranscript(textView.string), forType: .string)
    statusLabel.stringValue = "Copied."
  }

  @objc private func clearTranscript() {
    textView.string = ""
    statusLabel.stringValue = "Ready."
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
