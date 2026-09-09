import Foundation
import Darwin

private let qwenModelName = "qwen3-asr-0.6b-q4_k.gguf"
private let qwenModelSHA256 = "f63771c02dfa486d9399d41ab6ab8cd2d8ca24e077cd32130ea1f67f4fd8dade"
private let qwenModelSize = 631_026_336
private let qwenIdleTimeout: TimeInterval = 300
private let qwenServer = QwenServer()

enum QwenModelStatus: Equatable {
  case missing
  case ready
}

enum QwenModelImportProgress: String, Sendable {
  case copying, verifying, installing, complete
}

struct QwenRuntimeConfiguration: Equatable, Sendable {
  enum Architecture: String, Sendable {
    case arm64, x86_64
  }

  let runtimeURL: URL
  let modelURL: URL
  var architecture: Architecture? = nil

  func command(arguments: [String]) -> (executableURL: URL, arguments: [String]) {
    guard let architecture else { return (runtimeURL, arguments) }
    return (URL(fileURLWithPath: "/usr/bin/arch"), ["-\(architecture.rawValue)", runtimeURL.path] + arguments)
  }
}

enum QwenRuntimeDiagnostic: Sendable {
  case serverReady(cold: Bool, seconds: TimeInterval)
  case retry(segment: Int, total: Int, reason: String)
  case silentSegmentSkipped(segment: Int, total: Int)
  case segmentCompleted(segment: Int, total: Int, attempts: Int, seconds: TimeInterval)
  case completed(seconds: TimeInterval)
}

private enum QwenRuntimeError: LocalizedError {
  case runtimeMissing
  case processFailed(String, Int32, String)
  case processTimedOut(String)
  case serverUnavailable
  case modelMissing
  case invalidModel
  case emptyTranscript
  case unstableTranscript
  case incompleteTranscript(Int, Int, String)

  var errorDescription: String? {
    switch self {
    case .runtimeMissing:
      "Qwen ASR runtime is missing."
    case .processFailed(let name, let status, let details):
      details.isEmpty
        ? "\(name) failed with status \(status)."
        : "\(name) failed with status \(status): \(details)"
    case .processTimedOut(let name):
      "\(name) timed out."
    case .serverUnavailable:
      "Qwen ASR server is unavailable."
    case .modelMissing:
      "Choose the Qwen3-ASR model before dictating."
    case .invalidModel:
      "The selected Qwen ASR model did not pass verification."
    case .emptyTranscript:
      "Qwen ASR returned no speech."
    case .unstableTranscript:
      "Recognition became unstable. Please try again."
    case .incompleteTranscript(let segment, let total, let reason):
      "Recognition failed for segment \(segment) of \(total) after 2 attempts. No partial transcript was returned. \(reason)"
    }
  }
}

func qwenCommandArguments(modelURL: URL, audioURL: URL) -> [String] {
  [
    "--backend", "qwen3", "-m", modelURL.path, "-f", audioURL.path,
    "-np", "-nt", "-l", "auto", "--lid-backend", "off",
  ]
}

func qwenServerArguments(modelURL: URL, port: Int) -> [String] {
  [
    "--server", "--host", "127.0.0.1", "--port", String(port),
    "--backend", "qwen3", "-m", modelURL.path, "-np", "-nt",
    "-l", "auto", "--lid-backend", "off", "--ws-port", "-1", "--wyoming-port", "-1",
  ]
}

func cleanedQwenOutput(_ value: String) -> String {
  cleanedTranscript(value)
}

func hasPathologicalRepetition(_ value: String) -> Bool {
  // Output cleanup trims the final word separator; include it when counting repeated phrases.
  let characters = Array(value + " ")
  guard characters.count >= 16 else { return false }

  for start in characters.indices {
    let maximumUnitLength = min(24, (characters.count - start) / 8)
    guard maximumUnitLength > 0 else { continue }
    for unitLength in 1...maximumUnitLength {
      let requiredRepeats = unitLength == 1 ? 20 : 8
      var repeats = 1
      var position = start + unitLength
      while position + unitLength <= characters.count,
            characters[start..<(start + unitLength)]
              .elementsEqual(characters[position..<(position + unitLength)]) {
        repeats += 1
        if repeats >= requiredRepeats { return true }
        position += unitLength
      }
    }
  }
  return false
}

private func validatedQwenOutput(_ value: String) throws -> String {
  let text = cleanedQwenOutput(value)
  guard !text.isEmpty else { throw QwenRuntimeError.emptyTranscript }
  guard !hasPathologicalRepetition(text) else { throw QwenRuntimeError.unstableTranscript }
  return text
}

func qwenServerTranscript(_ value: String) throws -> String {
  guard let data = value.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let rawText = json["text"] as? String else {
    throw QwenRuntimeError.serverUnavailable
  }
  return try validatedQwenOutput(rawText)
}

func prepareQwen(diagnostics: ((QwenRuntimeDiagnostic) -> Void)? = nil) {
  if let event = try? qwenServer.prepare(configuration: qwenRuntimeAndModel()) {
    diagnostics?(event)
  }
}

func stopQwen() {
  qwenServer.stop()
}

func currentQwenModelStatus() -> QwenModelStatus {
  let locations = qwenModelLocations()
  return validModel(at: locations.modelURL, receiptURL: locations.receiptURL)
    ? .ready
    : .missing
}

func installedQwenModelURL() -> URL? {
  let locations = qwenModelLocations()
  return validModel(at: locations.modelURL, receiptURL: locations.receiptURL)
    ? locations.modelURL
    : nil
}

func installQwenModel(
  from sourceURL: URL,
  progress: ((QwenModelImportProgress) -> Void)? = nil
) throws {
  let locations = qwenModelLocations()
  try installVerifiedModel(
    from: sourceURL,
    to: locations.modelURL,
    receiptURL: locations.receiptURL,
    expectedSize: qwenModelSize,
    expectedSHA256: qwenModelSHA256,
    progress: progress
  )
}

func transcribeWithQwen(
  audioURL: URL,
  runtime: QwenRuntimeConfiguration? = nil,
  diagnostics: ((QwenRuntimeDiagnostic) -> Void)? = nil
) throws -> String {
  try Task.checkCancellation()
  let configuration = try qwenRuntimeAndModel(runtime)
  return try transcribeRecognitionSegments(audioURL: audioURL, diagnostics: diagnostics) { url, attempt in
    if attempt == 0 {
      return try qwenServer.transcribe(audioURL: url, configuration: configuration, diagnostics: diagnostics)
    }
    // One independent CLI attempt also recovers empty/unstable responses from a live server.
    qwenServer.stop()
    let command = configuration.command(arguments: qwenCommandArguments(modelURL: configuration.modelURL, audioURL: url))
    return try processOutput(executableURL: command.executableURL, arguments: command.arguments, timeout: 180)
  }
}

// Own only the generated segments; the original recording always belongs to the caller.
func transcribeRecognitionSegments(
  audioURL: URL,
  diagnostics: ((QwenRuntimeDiagnostic) -> Void)? = nil,
  transcribe: (URL, Int) throws -> String
) throws -> String {
  try Task.checkCancellation()
  let started = ProcessInfo.processInfo.systemUptime
  let audioURLs = try recognitionAudioSegments(at: audioURL)
  defer {
    for url in audioURLs where url != audioURL {
      try? FileManager.default.removeItem(at: url)
    }
  }
  var parts: [String] = []
  for (index, url) in audioURLs.enumerated() {
    try Task.checkCancellation()
    let segmentStarted = ProcessInfo.processInfo.systemUptime
    guard let inferenceURL = try recognitionAudioForInference(at: url) else {
      diagnostics?(.silentSegmentSkipped(segment: index + 1, total: audioURLs.count))
      continue
    }
    defer {
      if inferenceURL != url { try? FileManager.default.removeItem(at: inferenceURL) }
    }
    for attempt in 0..<2 {
      do {
        try Task.checkCancellation()
        let text = try validatedQwenOutput(transcribe(inferenceURL, attempt))
        try Task.checkCancellation()
        parts.append(text)
        diagnostics?(.segmentCompleted(
          segment: index + 1, total: audioURLs.count, attempts: attempt + 1,
          seconds: ProcessInfo.processInfo.systemUptime - segmentStarted
        ))
        break
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        try Task.checkCancellation()
        guard attempt == 0 else {
          throw QwenRuntimeError.incompleteTranscript(index + 1, audioURLs.count, error.localizedDescription)
        }
        diagnostics?(.retry(segment: index + 1, total: audioURLs.count, reason: error.localizedDescription))
      }
    }
  }
  try Task.checkCancellation()
  let result = try validatedQwenOutput(mergedTranscriptParts(parts))
  diagnostics?(.completed(seconds: ProcessInfo.processInfo.systemUptime - started))
  return result
}

private func qwenRuntimeAndModel(_ override: QwenRuntimeConfiguration? = nil) throws -> QwenRuntimeConfiguration {
  if let override {
    guard FileManager.default.isExecutableFile(atPath: override.runtimeURL.path) else {
      throw QwenRuntimeError.runtimeMissing
    }
    let installed = qwenModelLocations()
    let receipt = override.modelURL.resolvingSymlinksInPath() == installed.modelURL.resolvingSymlinksInPath()
      ? installed.receiptURL : nil
    let verified = validModel(at: override.modelURL, receiptURL: receipt)
    try Task.checkCancellation()
    guard verified else { throw QwenRuntimeError.invalidModel }
    return override
  }
  guard let resourceURL = Bundle.main.resourceURL else {
    throw QwenRuntimeError.runtimeMissing
  }
  let runtimeURL = resourceURL.appendingPathComponent("bin/qwen-asr")
  guard FileManager.default.isExecutableFile(atPath: runtimeURL.path) else {
    throw QwenRuntimeError.runtimeMissing
  }
  return QwenRuntimeConfiguration(runtimeURL: runtimeURL, modelURL: try ensureQwenModel())
}

// Mutable process state is confined to queue.
private final class QwenServer: @unchecked Sendable {
  private let queue = DispatchQueue(label: "io.github.linea.qwen-server")
  private let port = 30_000 + Int(getpid() % 10_000)
  private var process: Process?
  private var configuration: QwenRuntimeConfiguration?
  private var idleStopWorkItem: DispatchWorkItem?

  func prepare(configuration: QwenRuntimeConfiguration) throws -> QwenRuntimeDiagnostic {
    try queue.sync {
      defer {
        if Task.isCancelled { stopLocked() } else { scheduleStopLocked() }
      }
      return try startIfNeeded(configuration: configuration)
    }
  }

  func transcribe(
    audioURL: URL,
    configuration: QwenRuntimeConfiguration,
    diagnostics: ((QwenRuntimeDiagnostic) -> Void)?
  ) throws -> String {
    var ready: QwenRuntimeDiagnostic?
    // Invoke caller code outside the server queue so diagnostics cannot deadlock stop/prepare.
    defer { if let ready { diagnostics?(ready) } }
    return try queue.sync {
      defer {
        if Task.isCancelled { stopLocked() } else { scheduleStopLocked() }
      }
      ready = try startIfNeeded(configuration: configuration)
      let output = try processOutput(
        executableURL: URL(fileURLWithPath: "/usr/bin/curl"),
        arguments: [
          "--fail", "--silent", "--show-error", "--noproxy", "*",
          "--connect-timeout", "2", "--max-time", "180",
          "--form", qwenAudioFormArgument(audioURL),
          "--form", "language=auto",
          "--form", "lid_backend=off",
          "--form", "no_timestamps=true",
          "http://127.0.0.1:\(port)/inference",
        ],
        timeout: 182
      )
      return try qwenServerTranscript(output)
    }
  }

  func stop() {
    queue.sync { stopLocked() }
  }

  private func startIfNeeded(configuration: QwenRuntimeConfiguration) throws -> QwenRuntimeDiagnostic {
    try Task.checkCancellation()
    let started = ProcessInfo.processInfo.systemUptime
    if let process, process.isRunning, self.configuration == configuration, serverReady() {
      try Task.checkCancellation()
      return .serverReady(cold: false, seconds: ProcessInfo.processInfo.systemUptime - started)
    }
    try Task.checkCancellation()
    stopLocked()

    let process = Process()
    let command = configuration.command(arguments: qwenServerArguments(modelURL: configuration.modelURL, port: port))
    process.executableURL = command.executableURL
    process.arguments = command.arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try Task.checkCancellation()
    try process.run()
    self.process = process
    self.configuration = configuration
    var becameReady = false
    defer { if !becameReady { stopLocked() } }

    let deadline = ProcessInfo.processInfo.systemUptime + 60
    while ProcessInfo.processInfo.systemUptime < deadline {
      try Task.checkCancellation()
      if process.isRunning, serverReady() {
        try Task.checkCancellation()
        becameReady = true
        return .serverReady(cold: true, seconds: ProcessInfo.processInfo.systemUptime - started)
      }
      if !process.isRunning {
        let status = process.terminationStatus
        throw QwenRuntimeError.processFailed("Qwen ASR server startup", status, "Exited before becoming healthy.")
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    try Task.checkCancellation()
    throw QwenRuntimeError.processTimedOut("Qwen ASR server startup (60s limit)")
  }

  private func serverReady() -> Bool {
    guard let response = try? processOutput(
      executableURL: URL(fileURLWithPath: "/usr/bin/curl"),
      arguments: [
        "--fail", "--silent", "--noproxy", "*", "--connect-timeout", "0.2", "--max-time", "0.5",
        "http://127.0.0.1:\(port)/health",
      ],
      timeout: 1
    ), let data = response.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return false
    }
    return json["status"] as? String == "ok" && json["backend"] as? String == "qwen3"
  }

  private func stopLocked() {
    idleStopWorkItem?.cancel()
    idleStopWorkItem = nil
    guard let process else { return }
    self.process = nil
    configuration = nil
    guard process.isRunning else {
      process.waitUntilExit()
      return
    }

    let pid = process.processIdentifier
    process.terminate()
    for _ in 0..<20 where process.isRunning {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning { kill(pid, SIGKILL) }
    process.waitUntilExit()
  }

  private func scheduleStopLocked() {
    idleStopWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in self?.stopLocked() }
    idleStopWorkItem = workItem
    queue.asyncAfter(deadline: .now() + qwenIdleTimeout, execute: workItem)
  }
}

func qwenAudioFormArgument(_ url: URL) -> String {
  let escaped = url.path.replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
  return "file=@\"\(escaped)\""
}

private func ensureQwenModel() throws -> URL {
  let locations = qwenModelLocations()
  let verified = validModel(at: locations.modelURL, receiptURL: locations.receiptURL)
  try Task.checkCancellation()
  if verified {
    try? qwenModelSHA256.write(to: locations.receiptURL, atomically: true, encoding: .utf8)
    return locations.modelURL
  }
  guard FileManager.default.fileExists(atPath: locations.modelURL.path) else {
    throw QwenRuntimeError.modelMissing
  }
  throw QwenRuntimeError.invalidModel
}

func installVerifiedModel(
  from sourceURL: URL,
  to destinationURL: URL,
  receiptURL: URL,
  expectedSize: Int,
  expectedSHA256: String,
  progress: ((QwenModelImportProgress) -> Void)? = nil
) throws {
  let fileManager = FileManager.default
  let sourceURL = sourceURL.resolvingSymlinksInPath().standardizedFileURL
  let destinationURL = destinationURL.resolvingSymlinksInPath().standardizedFileURL
  let directory = destinationURL.deletingLastPathComponent()
  try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
  let stagedURL = directory.appendingPathComponent(".model-\(UUID().uuidString).staged")
  defer { try? fileManager.removeItem(at: stagedURL) }

  progress?(.copying)
  try fileManager.copyItem(at: sourceURL, to: stagedURL)
  progress?(.verifying)
  guard validModel(at: stagedURL, receiptURL: nil, expectedSize: expectedSize, expectedSHA256: expectedSHA256) else {
    throw QwenRuntimeError.invalidModel
  }
  let stagedFile = try FileHandle(forWritingTo: stagedURL)
  defer { try? stagedFile.close() }
  try stagedFile.synchronize()
  progress?(.installing)
  // Same-directory POSIX rename replaces atomically, leaving the old model intact on failure.
  guard rename(stagedURL.path, destinationURL.path) == 0 else {
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
  try? expectedSHA256.write(to: receiptURL, atomically: true, encoding: .utf8)
  if sourceURL != destinationURL {
    try? fileManager.removeItem(at: sourceURL)
  }
  progress?(.complete)
}

private func qwenModelLocations() -> (modelURL: URL, receiptURL: URL) {
  let directory = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Linea Lite/models/qwen3-asr-0.6b-q4-k/\(qwenModelSHA256)")
  return (
    directory.appendingPathComponent(qwenModelName),
    directory.appendingPathComponent("verified.sha256")
  )
}

private func validModel(
  at url: URL,
  receiptURL: URL?,
  expectedSize: Int = qwenModelSize,
  expectedSHA256: String = qwenModelSHA256
) -> Bool {
  guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
        values.isRegularFile == true,
        values.fileSize == expectedSize else { return false }
  if let receiptURL,
     (try? String(contentsOf: receiptURL, encoding: .utf8)) == expectedSHA256 {
    return true
  }
  guard let output = try? processOutput(
    executableURL: URL(fileURLWithPath: "/usr/bin/shasum"),
    arguments: ["-a", "256", url.path]
  ) else { return false }
  return output.hasPrefix(expectedSHA256)
}

func processOutput(
  executableURL: URL,
  arguments: [String],
  timeout: TimeInterval? = nil
) throws -> String {
  try Task.checkCancellation()
  let process = Process()
  let outputURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("linea-lite-process-\(UUID().uuidString).log")
  let errorURL = outputURL.appendingPathExtension("stderr")
  var files: [FileHandle] = []
  defer {
    for file in files { try? file.close() }
    for url in [outputURL, errorURL] { try? FileManager.default.removeItem(at: url) }
  }
  for url in [outputURL, errorURL] {
    guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    files.append(try FileHandle(forWritingTo: url))
  }
  let finished = DispatchSemaphore(value: 0)
  process.executableURL = executableURL
  process.arguments = arguments
  process.standardOutput = files[0]
  process.standardError = files[1]
  process.terminationHandler = { _ in finished.signal() }
  try Task.checkCancellation()
  try process.run()
  defer {
    if process.isRunning {
      process.terminate()
      if finished.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        _ = finished.wait(timeout: .now() + 1)
      }
    }
  }
  let deadline = timeout.map { DispatchTime.now() + $0 } ?? .distantFuture
  while finished.wait(timeout: min(deadline, .now() + 0.05)) == .timedOut {
    try Task.checkCancellation()
    if DispatchTime.now() >= deadline {
      throw QwenRuntimeError.processTimedOut(executableURL.lastPathComponent)
    }
  }
  try Task.checkCancellation()
  for file in files { try file.synchronize() }
  let data = try Data(contentsOf: outputURL)
  guard process.terminationStatus == 0 else {
    let details = String(decoding: data + (try Data(contentsOf: errorURL)), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    throw QwenRuntimeError.processFailed(
      executableURL.lastPathComponent,
      process.terminationStatus,
      String(details.prefix(500))
    )
  }
  return String(decoding: data, as: UTF8.self)
}
