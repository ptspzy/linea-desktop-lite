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

private enum QwenRuntimeError: LocalizedError {
  case runtimeMissing
  case processFailed(String, Int32, String)
  case processTimedOut(String)
  case serverUnavailable
  case modelMissing
  case invalidModel
  case emptyTranscript

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

func qwenServerTranscript(_ value: String) throws -> String {
  guard let data = value.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let rawText = json["text"] as? String else {
    throw QwenRuntimeError.serverUnavailable
  }
  let text = cleanedQwenOutput(rawText)
  guard !text.isEmpty else { throw QwenRuntimeError.emptyTranscript }
  return text
}

func prepareQwen() {
  try? qwenServer.prepare()
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

func installQwenModel(from sourceURL: URL) throws {
  let locations = qwenModelLocations()
  try installVerifiedModel(
    from: sourceURL,
    to: locations.modelURL,
    receiptURL: locations.receiptURL,
    expectedSize: qwenModelSize,
    expectedSHA256: qwenModelSHA256
  )
}

func transcribeWithQwen(audioURL: URL) throws -> String {
  let audioURLs = try recognitionAudioSegments(at: audioURL)
  defer {
    for url in audioURLs where url != audioURL {
      try? FileManager.default.removeItem(at: url)
    }
  }
  var parts: [String] = []
  for url in audioURLs {
    do {
      parts.append(try transcribeSingleWithQwen(audioURL: url))
    } catch QwenRuntimeError.emptyTranscript {
      continue
    }
  }
  let text = cleanedQwenOutput(mergedTranscriptParts(parts))
  guard !text.isEmpty else { throw QwenRuntimeError.emptyTranscript }
  return text
}

private func transcribeSingleWithQwen(audioURL: URL) throws -> String {
  do {
    return try qwenServer.transcribe(audioURL: audioURL)
  } catch QwenRuntimeError.emptyTranscript {
    throw QwenRuntimeError.emptyTranscript
  } catch {
    qwenServer.stop()
    let (runtimeURL, modelURL) = try qwenRuntimeAndModel()
    let output = try processOutput(
      executableURL: runtimeURL,
      arguments: qwenCommandArguments(modelURL: modelURL, audioURL: audioURL),
      timeout: 180
    )
    let text = cleanedQwenOutput(output)
    guard !text.isEmpty else { throw QwenRuntimeError.emptyTranscript }
    return text
  }
}

private func qwenRuntimeAndModel() throws -> (URL, URL) {
  guard let resourceURL = Bundle.main.resourceURL else {
    throw QwenRuntimeError.runtimeMissing
  }
  let runtimeURL = resourceURL.appendingPathComponent("bin/qwen-asr")
  guard FileManager.default.isExecutableFile(atPath: runtimeURL.path) else {
    throw QwenRuntimeError.runtimeMissing
  }
  return (runtimeURL, try ensureQwenModel())
}

// Mutable process state is confined to queue.
private final class QwenServer: @unchecked Sendable {
  private let queue = DispatchQueue(label: "io.github.linea.qwen-server")
  private let port = 30_000 + Int(getpid() % 10_000)
  private var process: Process?
  private var idleStopWorkItem: DispatchWorkItem?

  func prepare() throws {
    try queue.sync {
      defer { scheduleStopLocked() }
      let (runtimeURL, modelURL) = try qwenRuntimeAndModel()
      try startIfNeeded(runtimeURL: runtimeURL, modelURL: modelURL)
    }
  }

  func transcribe(audioURL: URL) throws -> String {
    try queue.sync {
      defer { scheduleStopLocked() }
      let (runtimeURL, modelURL) = try qwenRuntimeAndModel()
      try startIfNeeded(runtimeURL: runtimeURL, modelURL: modelURL)
      let output = try processOutput(
        executableURL: URL(fileURLWithPath: "/usr/bin/curl"),
        arguments: [
          "--fail", "--silent", "--show-error", "--max-time", "180",
          "--form", "file=@\(audioURL.path)",
          "--form", "language=auto",
          "--form", "lid_backend=off",
          "--form", "no_timestamps=true",
          "http://127.0.0.1:\(port)/inference",
        ],
        timeout: 180
      )
      return try qwenServerTranscript(output)
    }
  }

  func stop() {
    queue.sync { stopLocked() }
  }

  private func startIfNeeded(runtimeURL: URL, modelURL: URL) throws {
    if let process, process.isRunning, serverReady() { return }
    stopLocked()

    let process = Process()
    process.executableURL = runtimeURL
    process.arguments = qwenServerArguments(modelURL: modelURL, port: port)
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    self.process = process

    for _ in 0..<300 {
      if process.isRunning, serverReady() { return }
      if !process.isRunning { break }
      Thread.sleep(forTimeInterval: 0.05)
    }
    stopLocked()
    throw QwenRuntimeError.serverUnavailable
  }

  private func serverReady() -> Bool {
    guard let url = URL(string: "http://127.0.0.1:\(port)/health"),
          let data = try? Data(contentsOf: url),
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

private func ensureQwenModel() throws -> URL {
  let locations = qwenModelLocations()
  if validModel(at: locations.modelURL, receiptURL: locations.receiptURL) {
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
  expectedSHA256: String
) throws {
  guard validModel(
    at: sourceURL,
    receiptURL: nil,
    expectedSize: expectedSize,
    expectedSHA256: expectedSHA256
  ) else {
    throw QwenRuntimeError.invalidModel
  }

  let fileManager = FileManager.default
  let sourceURL = sourceURL.standardizedFileURL
  let destinationURL = destinationURL.standardizedFileURL
  let directory = destinationURL.deletingLastPathComponent()
  try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

  if sourceURL != destinationURL {
    if fileManager.fileExists(atPath: destinationURL.path) {
      try fileManager.removeItem(at: destinationURL)
    }
    try fileManager.moveItem(at: sourceURL, to: destinationURL)
  }
  try? expectedSHA256.write(to: receiptURL, atomically: true, encoding: .utf8)
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
  let process = Process()
  let outputURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("linea-lite-process-\(UUID().uuidString).log")
  guard FileManager.default.createFile(
    atPath: outputURL.path,
    contents: nil,
    attributes: [.posixPermissions: 0o600]
  ) else {
    throw CocoaError(.fileWriteUnknown)
  }
  let output = try FileHandle(forWritingTo: outputURL)
  defer {
    try? output.close()
    try? FileManager.default.removeItem(at: outputURL)
  }
  let finished = DispatchSemaphore(value: 0)
  process.executableURL = executableURL
  process.arguments = arguments
  process.standardOutput = output
  process.standardError = output
  process.terminationHandler = { _ in finished.signal() }
  try process.run()

  if let timeout, finished.wait(timeout: .now() + timeout) == .timedOut {
    process.terminate()
    if finished.wait(timeout: .now() + 1) == .timedOut {
      kill(process.processIdentifier, SIGKILL)
      finished.wait()
    }
    throw QwenRuntimeError.processTimedOut(executableURL.lastPathComponent)
  }
  if timeout == nil {
    finished.wait()
  }
  try output.synchronize()
  let data = try Data(contentsOf: outputURL)
  guard process.terminationStatus == 0 else {
    let details = String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    throw QwenRuntimeError.processFailed(
      executableURL.lastPathComponent,
      process.terminationStatus,
      String(details.prefix(500))
    )
  }
  return String(decoding: data, as: UTF8.self)
}
