import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import UniformTypeIdentifiers

private let pasteKeyCode: CGKeyCode = 9

#if LINEA_UI_TEST
private func testArgument(_ name: String) -> String? {
  guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
  return CommandLine.arguments[index + 1]
}
private let uiTestDirectory = URL(fileURLWithPath: testArgument("--ui-test-directory")!)
private let appDefaults = UserDefaults(suiteName: "io.github.linea.ui-tests")!
private let personalVocabularyURL = uiTestDirectory.appendingPathComponent("personal-vocabulary.json")
#else
private let appDefaults = UserDefaults.standard
private let personalVocabularyURL = defaultPersonalVocabularyURL
#endif

private enum DictationError: LocalizedError {
  case busy
  case noAudio
  case cancelled

  var errorDescription: String? {
    switch self {
    case .busy:
      "Still working."
    case .noAudio:
      "No audio was recorded."
    case .cancelled:
      "已取消"
    }
  }
}

private struct DictationResult {
  let transcript: String
  let audioDuration: TimeInterval
  let recognitionDuration: TimeInterval
  let runtimeSummary: String
}

// Ownership moves from the startup task to the main actor without concurrent access.
private final class StartedRecording: @unchecked Sendable {
  let recorder: AVAudioRecorder
  let url: URL
  let startedAt: Date

  init(recorder: AVAudioRecorder, url: URL, startedAt: Date) {
    self.recorder = recorder
    self.url = url
    self.startedAt = startedAt
  }
}

private struct RecordingStartFailure: LocalizedError, Sendable {
  let message: String

  var errorDescription: String? { message }
}

@MainActor
private final class PushToTalkKey {
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var state = PushToTalkState()
  private var customState = CustomShortcutState()
  private var shortcut: PushToTalkShortcut
  private var customShortcut: CustomShortcut?
  private var registeredHotKey: EventHotKeyRef?
  private var hotKeyHandler: EventHandlerRef?
  private let onPress: () -> Void
  private let onRelease: () -> Void
  private let onCancel: () -> Void
  var isSuspended = false

  var isPressed: Bool {
    state.isPressed || customState.isPressed
  }

  init(
    shortcut: PushToTalkShortcut,
    customShortcut: CustomShortcut?,
    onPress: @escaping () -> Void,
    onRelease: @escaping () -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.shortcut = shortcut
    self.customShortcut = customShortcut
    self.onPress = onPress
    self.onRelease = onRelease
    self.onCancel = onCancel
  }

  @discardableResult
  func updateShortcut(_ shortcut: PushToTalkShortcut, custom: CustomShortcut? = nil) -> Bool {
    if custom != customShortcut || (custom != nil && registeredHotKey == nil) {
      var replacement: EventHotKeyRef?
      if let custom {
        guard installHotKeyHandler() else { return false }
        let flags = custom.flags
        let modifiers = (flags.contains(.control) ? controlKey : 0)
          | (flags.contains(.option) ? optionKey : 0)
          | (flags.contains(.command) ? cmdKey : 0)
          | (flags.contains(.shift) ? shiftKey : 0)
        guard RegisterEventHotKey(UInt32(custom.keyCode), UInt32(modifiers),
                                  EventHotKeyID(signature: 0x4C494E41, id: 1),
                                  GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive),
                                  &replacement) == noErr else { return false }
      }
      if let registeredHotKey { UnregisterEventHotKey(registeredHotKey) }
      registeredHotKey = replacement
    }
    self.shortcut = shortcut
    customShortcut = custom
    state = PushToTalkState()
    customState = CustomShortcutState()
    return true
  }

  @discardableResult
  func register() -> Bool {
    let bindingReady = updateShortcut(shortcut, custom: customShortcut)
    guard globalMonitor == nil, localMonitor == nil else { return bindingReady }
    let events: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
      self?.enqueue(event)
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
      self?.enqueue(event)
      return event
    }
    return bindingReady
  }

  private func installHotKeyHandler() -> Bool {
    guard hotKeyHandler == nil else { return true }
    var types = [
      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]
    return InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
      guard let event, let context else { return OSStatus(eventNotHandledErr) }
      let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
      let monitor = Unmanaged<PushToTalkKey>.fromOpaque(context).takeUnretainedValue()
      MainActor.assumeIsolated { monitor.handleCustomHotKey(pressed: pressed) }
      return noErr
    }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler) == noErr
  }

  private func handleCustomHotKey(pressed: Bool) {
    guard !isSuspended, let customShortcut else { return }
    switch customState.transition(keyCode: customShortcut.keyCode, type: pressed ? .keyDown : .keyUp,
                                  flags: customShortcut.flags, isRepeat: false, shortcut: customShortcut) {
    case .pressed: onPress()
    case .released: onRelease()
    case nil: break
    }
  }

  nonisolated private func enqueue(_ event: NSEvent) {
    let keyCode = event.keyCode
    let flags = event.modifierFlags
    let type = event.type
    let isRepeat = type == .keyDown && event.isARepeat
    DispatchQueue.main.async { [weak self] in
      self?.handle(keyCode: keyCode, flags: flags, type: type, isRepeat: isRepeat)
    }
  }

  private func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags, type: NSEvent.EventType, isRepeat: Bool) {
    guard !isSuspended else { return }
    if type == .keyDown && keyCode == 53 {
      onCancel()
      state = PushToTalkState()
      customState = CustomShortcutState()
      return
    }
    guard customShortcut == nil else { return }
    guard type == .flagsChanged else { return }
    let isPressed = flags.rawValue & shortcut.deviceMask != 0
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
  private var startID: UUID?
  private var cancelled = false
  private var warmupSummary = ""
  private var warmupTask: Task<Void, Never>?
  private var recognitionTask: Task<(String, String), Error>?
  let recovery = CaptureRecovery()
  #if LINEA_UI_TEST
  private var injectedRecording = false
  #endif

  var isRecording: Bool {
    #if LINEA_UI_TEST
    if injectedRecording { return true }
    #endif
    return recorder?.isRecording == true
  }

  var isBusy: Bool {
    isRecording || isTranscribing || startID != nil
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

  func start(
    _ completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
  ) {
    guard !isTranscribing else {
      completion(.failure(DictationError.busy))
      return
    }

    stopRecording()
    #if LINEA_UI_TEST
    if let path = testArgument("--ui-test-audio") {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("linea-lite-test-\(UUID().uuidString).wav")
      do {
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
        audioURL = url
        startedAt = Date()
        injectedRecording = true
        completion(.success(()))
      } catch { completion(.failure(error)) }
      return
    }
    #endif
    let id = UUID()
    startID = id
    Task.detached(priority: .userInitiated) { [weak self] in
      do {
        let recording = try Self.makeStartedRecording()
        guard let self else {
          recording.recorder.stop()
          try? FileManager.default.removeItem(at: recording.url)
          return
        }
        guard await self.accept(recording, id: id) else {
          await completion(.failure(DictationError.cancelled))
          return
        }
        await completion(.success(()))
      } catch {
        await self?.clearStart(id: id)
        await completion(.failure(RecordingStartFailure(message: error.localizedDescription)))
      }
    }
  }

  nonisolated private static func makeStartedRecording() throws -> StartedRecording {
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
    guard recorder.prepareToRecord() else {
      try? FileManager.default.removeItem(at: url)
      throw DictationError.noAudio
    }
    guard recorder.record() else {
      try? FileManager.default.removeItem(at: url)
      throw DictationError.noAudio
    }
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return StartedRecording(
      recorder: recorder,
      url: url,
      startedAt: Date()
    )
  }

  private func clearStart(id: UUID) {
    if startID == id { startID = nil }
  }

  private func accept(_ recording: StartedRecording, id: UUID) -> Bool {
    guard startID == id else {
      recording.recorder.stop()
      try? FileManager.default.removeItem(at: recording.url)
      return false
    }
    startID = nil
    recorder = recording.recorder
    startedAt = recording.startedAt
    audioURL = recording.url
    warmupTask = Task.detached(priority: .utility) { [weak self] in
      prepareQwen { event in
        if case .serverReady(let cold, let seconds) = event {
          let summary = String(format: "Model %@ %.2fs", cold ? "cold start" : "warm", seconds)
          Task { @MainActor [weak self] in self?.warmupSummary = summary }
        }
      }
    }
    return true
  }

  func cancelRecording() {
    startID = nil
    if isTranscribing {
      cancelled = true
      recognitionTask?.cancel()
      Task.detached(priority: .utility) { stopQwen() }
      return
    }
    warmupTask?.cancel()
    let url = audioURL
    stopRecording()
    audioURL = nil
    if let url { try? FileManager.default.removeItem(at: url) }
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
    #if LINEA_UI_TEST
    injectedRecording = false
    #endif
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
    cancelled = false
    Task { [weak self] in
      guard let self else { return }
      defer { self.recognitionTask = nil }
      do {
        let recognitionStartedAt = ProcessInfo.processInfo.systemUptime
        let task = Task.detached(priority: .userInitiated) {
          #if LINEA_UI_TEST
          try await Task.sleep(for: .seconds(5))
          let failure = uiTestDirectory.appendingPathComponent("fail-next-recognition")
          if FileManager.default.fileExists(atPath: failure.path) {
            try FileManager.default.removeItem(at: failure)
            throw DictationError.noAudio
          }
          #endif
          var segments = 0
          var retries = 0
          var serverSeconds: TimeInterval = 0
          let text = try transcribeWithQwen(audioURL: url) { event in
            switch event {
            case .serverReady(_, let seconds): serverSeconds += seconds
            case .retry: retries += 1
            case .segmentCompleted(_, let total, _, _): segments = total
            case .silentSegmentSkipped(_, let total): segments = total
            case .completed: break
            }
          }
          return (text, String(format: "%d segments, %d retries, server ready %.2fs", segments, retries, serverSeconds))
        }
        self.recognitionTask = task
        if self.cancelled { task.cancel() }
        let (text, segmentSummary) = try await task.value
        guard !self.cancelled else {
          self.finish(url: url)
          completion(.failure(DictationError.cancelled))
          return
        }
        let recognitionDuration = ProcessInfo.processInfo.systemUptime - recognitionStartedAt
        self.finish(url: url)
        completion(.success(DictationResult(
          transcript: text,
          audioDuration: duration,
          recognitionDuration: recognitionDuration,
          runtimeSummary: "\(self.warmupSummary); \(segmentSummary)"
        )))
      } catch {
        if self.cancelled {
          self.finish(url: url)
          completion(.failure(DictationError.cancelled))
        } else {
          self.isTranscribing = false
          self.audioURL = nil
          self.recovery.retain(url: url, duration: duration)
          completion(.failure(error))
        }
      }
    }
  }

  private func finish(url: URL) {
    isTranscribing = false
    audioURL = nil
    recovery.discard(ifMatching: url)
    try? FileManager.default.removeItem(at: url)
  }

  func retry(_ completion: @escaping (Result<DictationResult, Error>) -> Void) {
    guard !isBusy, let recording = recovery.available() else {
      completion(.failure(DictationError.noAudio))
      return
    }
    audioURL = recording.url
    transcribe(url: recording.url, duration: recording.duration, completion)
  }

  func shutdown() {
    recognitionTask?.cancel()
    warmupTask?.cancel()
    startID = nil
    recovery.discard()
    let activeURL = audioURL
    stopRecording()
    audioURL = nil
    if let activeURL { try? FileManager.default.removeItem(at: activeURL) }
  }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let engine = DictationEngine()
  #if LINEA_UI_TEST
  private let history = HistoryStore(url: uiTestDirectory.appendingPathComponent("history.json"))
  private var testWindow: NSWindow?
  private let testStatus = NSTextField(labelWithString: "")
  #else
  private let history = HistoryStore()
  #endif
  private let historyView = HistoryMenuView()
  private lazy var hud = CaptureHUD()
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private var hotKey: PushToTalkKey?
  private var accessibilityTimer: Timer?
  private var levelTimer: Timer?
  private var targetAppName: String?
  private var insertionTarget: DictationTarget?
  private var captureID = UUID()
  private var captureRequestedAt: TimeInterval = 0
  private var captureReadyDelay: TimeInterval = 0
  private var recoveryTimer: Timer?
  private var personalVocabulary: [WorkspaceVocabularyEntry] = []
  private var isStarting = false
  private var isDelivering = false
  private var isImportingModel = false
  private var hasPromptedForModel = false
  private var workspaceURL: URL?
  private var workspaceVocabulary: [WorkspaceVocabularyEntry] = []
  private var shortcut = DictationShortcutState()
  private var shortcutChoice = PushToTalkShortcut(
    rawValue: appDefaults.string(forKey: "pushToTalkShortcut") ?? ""
  ) ?? .rightOption
  private var customShortcut: CustomShortcut? = {
    guard let data = appDefaults.data(forKey: "customShortcut"),
          let value = try? JSONDecoder().decode(CustomShortcut.self, from: data), value.isValid else { return nil }
    return value
  }()
  private var shortcutTitle: String { customShortcut?.title ?? shortcutChoice.title }
  private var diagnosticSummaries = appDefaults.stringArray(forKey: "diagnosticsV2") ?? []
  private var status = "就绪"
  private var downloadTask: Task<Void, Never>?
  private var lastDownloadPercent: Int?
  private let captureMenuItem = NSMenuItem(title: "开始录音", action: #selector(toggleCapture(_:)), keyEquivalent: "")
  private let retryMenuItem = NSMenuItem(title: "重试上次录音", action: #selector(retryDictation(_:)), keyEquivalent: "")
  private let discardRecordingMenuItem = NSMenuItem(title: "删除暂存录音", action: #selector(discardFailedRecording(_:)), keyEquivalent: "")
  private let retentionMenuItem = NSMenuItem(title: "历史保存期限", action: nil, keyEquivalent: "")
  private let updateMenuItem = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
  private let cancelUpdateMenuItem = NSMenuItem(title: "取消更新下载", action: #selector(cancelUpdate(_:)), keyEquivalent: "")

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
    Task.detached(priority: .utility) { removeStaleCaptureFiles() }
    loadSavedWorkspace()
    personalVocabulary = (try? loadPersonalVocabulary(from: personalVocabularyURL)) ?? []
    buildMenu()
    #if LINEA_UI_TEST
    showTestControls()
    #endif

    hotKey = PushToTalkKey(
      shortcut: shortcutChoice,
      customShortcut: customShortcut,
      onPress: { [weak self] in self?.handleShortcutPress() },
      onRelease: { [weak self] in self?.handleShortcutRelease() },
      onCancel: { [weak self] in self?.cancelDictation() }
    )
    recoveryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !self.engine.isBusy else { return }
        _ = self.engine.recovery.available()
        if self.history.retention != .keep500 { _ = self.history.applyRetention() }
        self.refreshMenu()
      }
    }
    if currentQwenModelStatus() == .ready {
      preparePermissions()
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.promptForModelIfNeeded()
      }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    downloadTask?.cancel()
    recoveryTimer?.invalidate()
    engine.shutdown()
    stopQwen()
  }

  #if LINEA_UI_TEST
  private func showTestControls() {
    let window = NSWindow(contentRect: NSRect(x: 180, y: 160, width: 440, height: 140),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Linea UI Test"
    window.isReleasedWhenClosed = false
    testStatus.frame = NSRect(x: 20, y: 84, width: 400, height: 36)
    testStatus.maximumNumberOfLines = 2
    testStatus.stringValue = status
    window.contentView?.addSubview(testStatus)
    let button = NSButton(title: "打开菜单", target: self, action: #selector(showTestMenu(_:)))
    button.frame = NSRect(x: 20, y: 24, width: 110, height: 32)
    window.contentView?.addSubview(button)
    testWindow = window
    window.makeKeyAndOrderFront(nil)
  }

  @objc private func showTestMenu(_ sender: Any?) { statusItem.button?.performClick(sender) }
  #endif

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
    historyView.onDelete = { [weak self] entry in self?.deleteHistoryEntry(entry) }
    historyView.onCorrect = { [weak self] entry in self?.correctHistoryEntry(entry) }
    menu.addItem(NSMenuItem.separator())
    statusMenuItem.isEnabled = false
    menu.addItem(statusMenuItem)
    captureMenuItem.target = self
    menu.addItem(captureMenuItem)
    retryMenuItem.target = self
    menu.addItem(retryMenuItem)
    discardRecordingMenuItem.target = self
    menu.addItem(discardRecordingMenuItem)
    let settingsItem = NSMenuItem(title: "设置", action: nil, keyEquivalent: "")
    let settings = NSMenu()
    settings.autoenablesItems = false
    settingsItem.submenu = settings
    menu.addItem(settingsItem)
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
    shortcutMenu.addItem(.separator())
    let customItem = NSMenuItem(title: "自定义组合键…", action: #selector(recordCustomShortcut(_:)), keyEquivalent: "")
    customItem.target = self
    customItem.tag = 1
    shortcutMenu.addItem(customItem)
    shortcutMenuItem.submenu = shortcutMenu
    settings.addItem(shortcutMenuItem)
    settings.addItem(NSMenuItem.separator())
    modelMenuItem.target = self
    settings.addItem(modelMenuItem)
    revealModelMenuItem.target = self
    settings.addItem(revealModelMenuItem)
    settings.addItem(NSMenuItem.separator())
    microphoneMenuItem.target = self
    settings.addItem(microphoneMenuItem)
    accessibilityMenuItem.target = self
    settings.addItem(accessibilityMenuItem)
    settings.addItem(NSMenuItem.separator())
    workspaceStatusMenuItem.isEnabled = false
    settings.addItem(workspaceStatusMenuItem)
    chooseWorkspaceMenuItem.target = self
    chooseWorkspaceMenuItem.title = "选择工作区…"
    settings.addItem(chooseWorkspaceMenuItem)
    clearWorkspaceMenuItem.target = self
    clearWorkspaceMenuItem.title = "取消工作区关联"
    settings.addItem(clearWorkspaceMenuItem)
    settings.addItem(NSMenuItem.separator())
    let retention = NSMenu()
    retention.autoenablesItems = false
    for (days, title) in [(0, "最近 500 条（默认）"), (7, "7 天"), (30, "30 天"), (90, "90 天")] {
      let item = NSMenuItem(title: title, action: #selector(setHistoryRetention(_:)), keyEquivalent: "")
      item.target = self
      item.tag = days
      retention.addItem(item)
    }
    retentionMenuItem.submenu = retention
    settings.addItem(retentionMenuItem)
    clearHistoryMenuItem.target = self
    clearHistoryMenuItem.title = "清空本地历史…"
    settings.addItem(clearHistoryMenuItem)
    settings.addItem(.separator())
    updateMenuItem.target = self
    settings.addItem(updateMenuItem)
    cancelUpdateMenuItem.target = self
    settings.addItem(cancelUpdateMenuItem)
    let feedItem = NSMenuItem(title: "设置更新地址…", action: #selector(configureUpdateSource(_:)), keyEquivalent: "")
    feedItem.target = self
    settings.addItem(feedItem)
    diagnosticsMenuItem.target = self
    diagnosticsMenuItem.title = "本地诊断…"
    settings.addItem(diagnosticsMenuItem)
    menu.addItem(NSMenuItem(title: "退出 Linea Lite", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
    menu.delegate = self
    statusItem.menu = menu
    refreshMenu()
  }

  func menuWillOpen(_ menu: NSMenu) {
    historyView.update(entries: history.entries)
    refreshMenu()
  }

  private var idleStatus: String {
    guard currentQwenModelStatus() == .ready else {
      return "请先导入语音模型"
    }
    guard capturePermissionAction(
      for: AVCaptureDevice.authorizationStatus(for: .audio)
    ) == .start else {
      return "请先允许麦克风权限"
    }
    guard AXIsProcessTrusted() else {
      return "请先允许辅助功能权限"
    }
    return "就绪 · \(shortcutTitle)"
  }

  @objc private func selectShortcut(_ sender: NSMenuItem) {
    guard !engine.isBusy, !isStarting, !isDelivering,
          let rawValue = sender.representedObject as? String,
          let choice = PushToTalkShortcut(rawValue: rawValue) else { return }
    shortcut.reset()
    shortcutChoice = choice
    customShortcut = nil
    appDefaults.removeObject(forKey: "customShortcut")
    hotKey?.updateShortcut(choice)
    appDefaults.set(choice.rawValue, forKey: "pushToTalkShortcut")
    status = idleStatus
    refreshMenu()
  }

  private func handleShortcutPress() {
    guard hotKey?.isSuspended != true else { return }
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
        status = "持续录音中 · 再按一次结束"
        hud.showRecording(latched: true)
        refreshMenu()
      }
    case .stop:
      finishDictation()
    case .start, nil:
      break
    }
  }

  private func startDictation() {
    guard !engine.isBusy, !isStarting, !isImportingModel, !isDelivering else {
      shortcut.reset()
      status = "正在处理上一条录音"
      refreshMenu()
      return
    }
    guard currentQwenModelStatus() == .ready else {
      shortcut.reset()
      promptForModelIfNeeded(force: true)
      return
    }
    isStarting = true
    captureID = UUID()
    captureRequestedAt = ProcessInfo.processInfo.systemUptime
    targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName
    switch capturePermissionAction(for: AVCaptureDevice.authorizationStatus(for: .audio)) {
    case .start:
      hud.showStarting()
      status = "正在启动麦克风"
      refreshMenu()
      beginRecording()
    case .request:
      hud.showStarting()
      status = "等待麦克风授权"
      refreshMenu()
      engine.requestAccess { [weak self] allowed in
        guard let self else { return }
        allowed ? self.beginRecording() : self.finishMicrophoneDenied()
      }
    case .deny:
      finishMicrophoneDenied()
    }
  }

  private func beginRecording() {
    guard shortcut.wantsRecording else {
      isStarting = false
      targetAppName = nil
      status = idleStatus
      hud.hide()
      refreshMenu()
      return
    }

    let id = captureID
    engine.start { [weak self] result in
      guard let self, self.captureID == id else { return }
      self.isStarting = false
      switch result {
      case .success:
        guard self.shortcut.wantsRecording else {
          self.engine.cancelRecording()
          self.targetAppName = nil
          self.status = self.idleStatus
          self.hud.hide()
          self.refreshMenu()
          return
        }
        self.captureReadyDelay = max(0, ProcessInfo.processInfo.systemUptime - self.captureRequestedAt - self.engine.recordingDuration)
        self.hud.showRecording(latched: self.shortcut.isLatched)
        self.status = self.shortcut.isLatched ? "持续录音中 · 再按一次结束" : "录音中"
        self.startLevelUpdates()
      case .failure(let error):
        guard self.shortcut.wantsRecording else {
          self.targetAppName = nil
          self.status = self.idleStatus
          self.hud.hide()
          self.refreshMenu()
          return
        }
        self.shortcut.reset()
        self.targetAppName = nil
        self.status = error.localizedDescription
        self.hud.showError()
      }
      self.refreshMenu()
    }
    insertionTarget = DictationTarget.capture()
  }

  private func finishMicrophoneDenied() {
    isStarting = false
    shortcut.reset()
    targetAppName = nil
    status = "麦克风未授权"
    hud.showError()
    refreshMenu()
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
    status = "正在本地识别"

    engine.stopAndTranscribe { [weak self] result in
      self?.completeDictation(result, allowInsertion: true)
    }
    refreshMenu()
  }

  private func completeDictation(_ result: Result<DictationResult, Error>, allowInsertion: Bool) {
    isDelivering = true
    let id = captureID
    Task { @MainActor in
        defer {
          self.isDelivering = false
          self.refreshMenu()
        }
        let appName = self.targetAppName
        let target = self.insertionTarget
        self.targetAppName = nil
        self.insertionTarget = nil

        switch result {
        case .success(let result):
          let postProcessingStartedAt = ProcessInfo.processInfo.systemUptime
          let text = formattedTranscript(
            applyWorkspaceVocabulary(
              to: result.transcript,
              entries: defaultDeveloperVocabulary + self.workspaceVocabulary + self.personalVocabulary
            ),
            paragraphBreaks: paragraphFormattingAllowed(appName: appName)
          )
          guard !text.isEmpty else {
            self.status = "未检测到语音"
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
          let inserted = await self.insertAtCursor(text, target: allowInsertion ? target : nil, id: id)
          guard self.captureID == id else { return }
          let saved = self.history.append(HistoryEntry(
            text: text,
            duration: result.audioDuration,
            appName: appName
          ))
          if inserted == nil {
            self.status = saved ? "复制失败，请从历史重新复制" : "复制和历史保存均失败，请重试"
          } else if !saved {
            self.status = inserted == true ? "已发送粘贴，但历史保存失败" : "已复制，但历史保存失败"
          } else {
            self.status = inserted == true ? "已发送粘贴 · \(text.count) 字" : "已复制 · 焦点变化或无法确认，请手动粘贴"
          }
          self.saveDiagnostics(
            audioDuration: result.audioDuration,
            recognitionDuration: result.recognitionDuration,
            postProcessingDuration: ProcessInfo.processInfo.systemUptime - postProcessingStartedAt,
            outcome: (inserted == nil ? "Delivery failed" : inserted == true ? "Paste dispatched" : "Copied only") + "; " + result.runtimeSummary
          )
          if inserted == nil { self.hud.showError() } else { self.hud.showComplete() }
        case .failure(let error):
          if let error = error as? DictationError, case .cancelled = error {
            self.status = "已取消"
            self.hud.hide()
          } else {
            self.status = self.engine.recovery.available() == nil
              ? "识别失败，请重试" : "识别失败 · 录音暂存 10 分钟，可重试"
            self.appendDiagnostic("Recognition failed (details omitted for privacy).")
            self.hud.showError()
          }
        }
        self.refreshMenu()
    }
  }

  private func insertAtCursor(_ text: String, target: DictationTarget?, id: UUID) async -> Bool? {
    for _ in 0..<20 where !NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
      try? await Task.sleep(for: .milliseconds(50))
    }
    guard id == captureID else { return false }
    let pasteboard = NSPasteboard.general
    let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
    guard let dictationChangeCount = setPasteboardText(text, on: pasteboard) else {
      snapshot.restore(to: pasteboard, ifUnchangedSince: pasteboard.changeCount)
      return nil
    }

    guard AXIsProcessTrusted(),
          canAutomaticallyPaste(targetIsFocused: target?.stillFocused == true,
                                modifiers: NSEvent.modifierFlags) else {
      return false
    }

    let source = CGEventSource(stateID: .hidSystemState)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: pasteKeyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: pasteKeyCode, keyDown: false) else {
      return false
    }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      snapshot.restore(to: pasteboard, ifUnchangedSince: dictationChangeCount)
    }
    return true
  }

  @objc private func toggleCapture(_ sender: Any?) {
    if engine.isRecording || isStarting {
      finishDictation()
    } else if !engine.isBusy {
      _ = shortcut.press(at: ProcessInfo.processInfo.systemUptime)
      _ = shortcut.release(at: ProcessInfo.processInfo.systemUptime)
      startDictation()
    }
  }

  private func cancelDictation() {
    guard isStarting || engine.isBusy || isDelivering else { return }
    captureID = UUID()
    isStarting = false
    shortcut.reset()
    engine.cancelRecording()
    insertionTarget = nil
    targetAppName = nil
    stopLevelUpdates()
    hud.hide()
    status = engine.isBusy ? "已取消，等待本地识别结束" : "已取消"
    refreshMenu()
  }

  @objc private func retryDictation(_ sender: Any?) {
    guard !engine.isBusy, !isStarting, engine.recovery.available() != nil else { return }
    targetAppName = nil
    insertionTarget = nil
    captureReadyDelay = 0
    status = "正在重试上次录音"
    hud.showProcessing()
    engine.retry { [weak self] result in self?.completeDictation(result, allowInsertion: false) }
    refreshMenu()
  }

  @objc private func discardFailedRecording(_ sender: Any?) {
    guard !engine.isBusy else { return }
    engine.recovery.discard()
    status = "已删除暂存录音"
    refreshMenu()
  }

  @objc private func recordCustomShortcut(_ sender: Any?) {
    guard !engine.isBusy, !isStarting, !isDelivering else { return }
    let alert = NSAlert()
    alert.messageText = "自定义快捷键"
    alert.informativeText = "按下包含 Control、Option 或 Command 的组合键。常用编辑快捷键不可用。"
    let label = NSTextField(labelWithString: "等待按键")
    label.frame = NSRect(x: 0, y: 0, width: 320, height: 32)
    label.alignment = .center
    label.font = .systemFont(ofSize: 16, weight: .medium)
    alert.accessoryView = label
    alert.addButton(withTitle: "保存")
    alert.addButton(withTitle: "取消")
    alert.buttons[0].isEnabled = false
    var candidate: CustomShortcut?
    hotKey?.isSuspended = true
    let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard event.keyCode != 53 else { return event }
      let names: [UInt16: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete",
                                   123: "Left", 124: "Right", 125: "Down", 126: "Up"]
      let value = CustomShortcut(
        keyCode: event.keyCode,
        modifiers: event.modifierFlags.intersection([.control, .option, .command, .shift]).rawValue,
        keyLabel: names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
      )
      candidate = value.isValid ? value : nil
      label.stringValue = candidate?.title ?? "该组合键不可用，请换一个"
      alert.buttons[0].isEnabled = candidate != nil
      return nil
    }
    defer {
      if let monitor { NSEvent.removeMonitor(monitor) }
      hotKey?.isSuspended = false
    }
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn, let candidate,
          let data = try? JSONEncoder().encode(candidate) else { return }
    guard hotKey?.updateShortcut(shortcutChoice, custom: candidate) == true else {
      showMessage("快捷键不可用", detail: "该组合键已被系统或其他应用占用，请换一个。原快捷键保持不变。")
      return
    }
    customShortcut = candidate
    appDefaults.set(data, forKey: "customShortcut")
    shortcut.reset()
    status = idleStatus
    refreshMenu()
  }

  @objc private func clearHistory(_ sender: Any?) {
    let alert = NSAlert()
    alert.messageText = "清空本地历史？"
    alert.informativeText = "将永久删除语音文字、对应统计以及损坏历史的恢复备份。个人词库不受影响。"
    alert.addButton(withTitle: "清空")
    alert.addButton(withTitle: "取消")
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    status = history.clearAll() ? "历史已清空" : "清理未全部完成，请检查本地文件权限"
    refreshMenu()
  }

  private func deleteHistoryEntry(_ entry: HistoryEntry) {
    statusItem.menu?.cancelTracking()
    let alert = NSAlert()
    alert.messageText = "删除这条记录？"
    alert.informativeText = String(entry.text.prefix(120))
    alert.addButton(withTitle: "删除")
    alert.addButton(withTitle: "取消")
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    status = history.delete(id: entry.id) ? "记录已删除" : "删除失败，原记录已保留"
    refreshMenu()
  }

  @objc private func setHistoryRetention(_ sender: NSMenuItem) {
    guard let retention = HistoryRetention(rawValue: sender.tag), retention != history.retention else { return }
    let alert = NSAlert()
    alert.messageText = "更改历史保存期限？"
    alert.informativeText = "\(retention.title)。超出期限的现有记录将永久删除，对应统计也会更新。"
    alert.addButton(withTitle: "确认更改")
    alert.addButton(withTitle: "取消")
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    status = history.setRetention(retention) ? "历史保存期限已更新" : "修改失败，原设置已保留"
    refreshMenu()
  }

  private func correctHistoryEntry(_ entry: HistoryEntry) {
    statusItem.menu?.cancelTracking()
    let alert = NSAlert()
    alert.messageText = "修正记录"
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 194))
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 80, width: 360, height: 114))
    scroll.borderType = .bezelBorder
    scroll.hasVerticalScroller = true
    let editor = NSTextView(frame: scroll.bounds)
    editor.isRichText = false
    editor.font = .systemFont(ofSize: 13)
    editor.string = entry.text
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    scroll.documentView = editor
    content.addSubview(scroll)
    let learn = NSButton(checkboxWithTitle: "同时加入个人词库", target: nil, action: nil)
    learn.frame = NSRect(x: 0, y: 48, width: 360, height: 24)
    content.addSubview(learn)
    let wrong = NSTextField(frame: NSRect(x: 0, y: 8, width: 170, height: 26))
    wrong.placeholderString = "识别错词"
    wrong.setAccessibilityLabel("识别错词")
    let correct = NSTextField(frame: NSRect(x: 190, y: 8, width: 170, height: 26))
    correct.placeholderString = "正确词语"
    correct.setAccessibilityLabel("正确词语")
    content.addSubview(wrong)
    content.addSubview(correct)
    alert.accessoryView = content
    alert.addButton(withTitle: "保存")
    alert.addButton(withTitle: "取消")
    NSApp.activate(ignoringOtherApps: true)
    hotKey?.isSuspended = true
    defer { hotKey?.isSuspended = false }
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    guard !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      showMessage("未保存", detail: "记录不能为空。")
      return
    }
    do {
      if learn.state == .on {
        guard entry.text.localizedCaseInsensitiveContains(wrong.stringValue),
              !wrong.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else {
          showMessage("未保存", detail: "错词必须出现在原记录中。")
          return
        }
        personalVocabulary = try savePersonalVocabularyCorrection(alias: wrong.stringValue,
          canonical: correct.stringValue, to: personalVocabularyURL)
      }
      let corrected = learn.state == .on
        ? applyWorkspaceVocabulary(to: editor.string, entries: personalVocabulary) : editor.string
      status = history.update(id: entry.id, text: corrected)
        ? "记录已修正" : (learn.state == .on ? "词库已保存，但记录修改失败" : "修改失败，原记录已保留")
    } catch {
      showMessage("词库未保存", detail: error.localizedDescription)
    }
    refreshMenu()
  }

  private func showMessage(_ title: String, detail: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    alert.addButton(withTitle: "好")
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }

  @objc private func configureUpdateSource(_ sender: Any?) {
    guard downloadTask == nil else { return }
    let alert = NSAlert()
    alert.messageText = "更新地址"
    alert.informativeText = "仅填写你信任的 HTTPS 版本清单地址。留空可关闭网络更新；语音识别始终在本地完成。"
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
    field.stringValue = appDefaults.string(forKey: "updateManifestURL") ?? ""
    field.placeholderString = "https://…/update.json"
    alert.accessoryView = field
    alert.addButton(withTitle: "保存")
    alert.addButton(withTitle: "取消")
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      if value.isEmpty {
        appDefaults.removeObject(forKey: "updateManifestURL")
      } else {
        _ = try AppUpdate.validatedHTTPSURL(value)
        appDefaults.set(value, forKey: "updateManifestURL")
      }
      status = value.isEmpty ? "网络更新已关闭" : "更新地址已保存"
    } catch { showMessage("更新地址无效", detail: error.localizedDescription) }
    refreshMenu()
  }

  @objc private func checkForUpdates(_ sender: Any?) {
    guard downloadTask == nil else { return }
    guard let value = appDefaults.string(forKey: "updateManifestURL"),
          let endpoint = try? AppUpdate.validatedHTTPSURL(value) else {
      configureUpdateSource(nil)
      return
    }
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    status = "正在检查更新"
    downloadTask = Task { @MainActor in
      defer {
        self.downloadTask = nil
        self.refreshMenu()
      }
      do {
        guard let manifest = try await AppUpdate.fetchNewer(from: endpoint, currentVersion: version) else {
          self.status = "已是最新版本"
          self.showMessage("已是最新版本", detail: "Linea Lite \(version)")
          return
        }
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(manifest.version)"
        alert.informativeText = "下载并校验安装包后，由你确认安装。现有语音模型和本地历史不会被替换。"
        alert.addButton(withTitle: "下载")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Linea-Lite-\(manifest.version)-macos-universal.dmg"
        panel.allowedContentTypes = [.diskImage]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        self.status = "正在下载安装包"
        self.lastDownloadPercent = nil
        self.refreshMenu()
        let downloaded = try await AppUpdate.downloadVerified(manifest, to: destination) { progress in
          Task { @MainActor [weak self] in
            guard let self else { return }
            let percent = progress.fractionCompleted.map { Int($0 * 100) }
            guard percent != self.lastDownloadPercent else { return }
            self.lastDownloadPercent = percent
            self.status = percent.map { "正在下载更新 · \($0)%" } ?? "正在下载更新"
            self.statusMenuItem.title = self.status
            #if LINEA_UI_TEST
            self.testStatus.stringValue = self.status
            #endif
          }
        }
        self.status = "安装包已下载并通过校验"
        NSWorkspace.shared.activateFileViewerSelecting([downloaded])
      } catch is CancellationError {
        self.status = "更新下载已取消"
      } catch {
        self.status = "更新未完成"
        self.showMessage("更新未完成", detail: error.localizedDescription)
      }
    }
    refreshMenu()
  }

  @objc private func cancelUpdate(_ sender: Any?) {
    downloadTask?.cancel()
  }

  private func promptForModelIfNeeded(force: Bool = false) {
    guard currentQwenModelStatus() != .ready, force || !hasPromptedForModel else { return }
    hasPromptedForModel = true

    let alert = NSAlert()
    alert.messageText = "导入本地语音模型"
    alert.informativeText = "选择单独提供的 Qwen3-ASR 模型（约 602 MiB）。校验成功后会移入本机应用目录，语音不会上传。"
    alert.addButton(withTitle: "选择模型")
    alert.addButton(withTitle: "稍后")
    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn {
      chooseModel(nil)
    } else {
      preparePermissions()
    }
  }

  @objc private func chooseModel(_ sender: Any?) {
    guard !isImportingModel, !engine.isBusy, !isStarting, !isDelivering else { return }
    let panel = NSOpenPanel()
    panel.title = "选择 Qwen3-ASR 模型"
    panel.message = "选择 qwen3-asr-0.6b-q4_k.gguf，校验成功后会移入 Linea Lite。"
    panel.prompt = "导入"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    if let ggufType = UTType(filenameExtension: "gguf") {
      panel.allowedContentTypes = [ggufType]
    }
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK, let sourceURL = panel.url else {
      preparePermissions()
      return
    }
    beginModelImport(from: sourceURL)
  }

  @objc private func revealModel(_ sender: Any?) {
    guard let modelURL = installedQwenModelURL() else { return }
    NSWorkspace.shared.activateFileViewerSelecting([modelURL])
  }

  @objc private func fixMicrophonePermission(_ sender: Any?) {
    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
      engine.requestAccess { [weak self] allowed in
        self?.status = allowed ? "麦克风已授权" : "麦克风未授权"
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
    status = "正在校验本地模型"
    hud.showProcessing()
    refreshMenu()
    Task { [weak self] in
      let errorMessage = await Task.detached(priority: .utility) { [weak self] in
        do {
          stopQwen()
          try installQwenModel(from: sourceURL) { progress in
            Task { @MainActor [weak self] in
              guard let self else { return }
              switch progress {
              case .copying: self.status = "正在暂存模型"
              case .verifying: self.status = "正在校验模型 SHA-256"
              case .installing: self.status = "正在安装模型"
              case .complete: self.status = "模型已就绪"
              }
              self.refreshMenu()
            }
          }
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
    if let errorMessage {
      status = "语音模型导入失败"
      hud.showError()
      let alert = NSAlert()
      alert.messageText = "无法使用这个模型"
      alert.informativeText = errorMessage
      alert.addButton(withTitle: "好")
      refreshMenu()
      NSApp.activate(ignoringOtherApps: true)
      alert.runModal()
      return
    }

    status = "语音模型已就绪"
    hud.showComplete()
    refreshMenu()
    preparePermissions()
  }

  private func preparePermissions() {
    switch capturePermissionAction(for: AVCaptureDevice.authorizationStatus(for: .audio)) {
    case .request:
      status = "等待麦克风授权"
      refreshMenu()
      engine.requestAccess { [weak self] _ in
        self?.prepareAccessibility()
      }
    case .start, .deny:
      prepareAccessibility()
    }
  }

  @objc private func chooseWorkspace(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.message = "选择包含项目术语或 .linea-vocabulary.json 的工作区。"
    panel.prompt = "选择"
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
    appDefaults.removeObject(forKey: "workspacePath")
    status = "已取消工作区词库关联"
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
    macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
    Shortcut: \(shortcutTitle)

    \(diagnosticSummaries.isEmpty ? "No diagnostics yet." : diagnosticSummaries.joined(separator: "\n"))

    No transcript or audio is included.
    """
    let alert = NSAlert()
    alert.messageText = "本地诊断"
    alert.informativeText = report
    alert.addButton(withTitle: "复制")
    alert.addButton(withTitle: "关闭")
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
    appendDiagnostic(String(
      format: "Audio %.1fs; capture ready %.2fs; ASR %.2fs; format/paste dispatch %.2fs; %@.",
      audioDuration,
      captureReadyDelay,
      recognitionDuration,
      postProcessingDuration,
      outcome
    ))
  }

  private func appendDiagnostic(_ summary: String) {
    diagnosticSummaries.insert(summary, at: 0)
    diagnosticSummaries = Array(diagnosticSummaries.prefix(5))
    appDefaults.set(diagnosticSummaries, forKey: "diagnosticsV2")
  }

  private func loadSavedWorkspace() {
    guard let path = appDefaults.string(forKey: "workspacePath") else { return }
    setWorkspace(URL(fileURLWithPath: path), persist: false)
  }

  private func setWorkspace(_ url: URL, persist: Bool = true) {
    workspaceURL = url
    if persist { appDefaults.set(url.path, forKey: "workspacePath") }
    Task { @MainActor in
      let vocabulary = await Task.detached(priority: .utility) {
        try? loadWorkspaceVocabulary(from: url)
      }.value
      guard self.workspaceURL == url else { return }
      self.workspaceVocabulary = vocabulary ?? []
      if !self.engine.isBusy && !self.isStarting {
        self.status = vocabulary == nil ? "工作区词库读取失败" : "已加载 \(vocabulary!.count) 个工作区词条"
      }
      self.refreshMenu()
    }
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

    status = "请允许辅助功能权限"
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
    status = hotKey?.register() == true ? idleStatus : "快捷键注册失败，请在设置中更换"
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
    if shortcut.wantsRecording || engine.isRecording {
      statusItem.button?.title = "● Linea"
    } else if engine.isBusy || isStarting || isDelivering || isImportingModel {
      statusItem.button?.title = "… Linea"
    } else {
      let todayCount = history.entries.filter { Calendar.current.isDateInToday($0.createdAt) }.count
      statusItem.button?.title = "Linea \(todayCount)"
      statusItem.button?.toolTip = "Linea Lite · 今日 \(todayCount) 条"
    }
    statusMenuItem.title = status
    #if LINEA_UI_TEST
    testStatus.stringValue = status
    #endif
    statusMenuItem.toolTip = status
    captureMenuItem.title = engine.isRecording || isStarting ? "结束录音" : "开始录音"
    captureMenuItem.isEnabled = (!engine.isBusy || engine.isRecording) && !isImportingModel && !isDelivering
    let canRetry = !engine.isBusy && !isStarting && !isDelivering && engine.recovery.available() != nil
    retryMenuItem.isHidden = !canRetry
    discardRecordingMenuItem.isHidden = !canRetry
    shortcutMenuItem.title = "快捷键：\(shortcutTitle)"
    shortcutMenuItem.isEnabled = !engine.isBusy && !isStarting && !isDelivering
    for item in shortcutMenuItem.submenu?.items ?? [] {
      item.state = (item.tag == 1 ? customShortcut != nil
        : customShortcut == nil && item.representedObject as? String == shortcutChoice.rawValue) ? .on : .off
      item.isEnabled = shortcutMenuItem.isEnabled
    }
    switch currentQwenModelStatus() {
    case .ready:
      modelMenuItem.title = "更换语音模型…"
      modelMenuItem.isEnabled = !isImportingModel && !engine.isBusy && !isStarting && !isDelivering
      revealModelMenuItem.isEnabled = true
    case .missing:
      modelMenuItem.title = isImportingModel ? "正在校验语音模型…" : "导入语音模型…"
      modelMenuItem.isEnabled = !isImportingModel && !engine.isBusy && !isStarting && !isDelivering
      revealModelMenuItem.isEnabled = false
    }
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      microphoneMenuItem.title = "麦克风：已授权"
      microphoneMenuItem.isEnabled = false
    case .notDetermined:
      microphoneMenuItem.title = "允许麦克风权限…"
      microphoneMenuItem.isEnabled = true
    case .denied, .restricted:
      microphoneMenuItem.title = "麦克风：打开系统设置…"
      microphoneMenuItem.isEnabled = true
    @unknown default:
      microphoneMenuItem.title = "麦克风：打开系统设置…"
      microphoneMenuItem.isEnabled = true
    }
    accessibilityMenuItem.title = AXIsProcessTrusted()
      ? "辅助功能：已授权"
      : "辅助功能：打开系统设置…"
    accessibilityMenuItem.isEnabled = !AXIsProcessTrusted()
    workspaceStatusMenuItem.title = workspaceURL.map { "工作区：\($0.lastPathComponent)" }
      ?? "工作区：未选择"
    revealModelMenuItem.title = "在 Finder 中显示模型"
    clearWorkspaceMenuItem.isEnabled = workspaceURL != nil
    clearHistoryMenuItem.isEnabled = !history.entries.isEmpty
    for item in retentionMenuItem.submenu?.items ?? [] {
      item.state = item.tag == history.retention.rawValue ? .on : .off
    }
    updateMenuItem.isEnabled = downloadTask == nil
    cancelUpdateMenuItem.isHidden = downloadTask == nil
    historyView.update(entries: history.entries)
  }
}

MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.run()
}
