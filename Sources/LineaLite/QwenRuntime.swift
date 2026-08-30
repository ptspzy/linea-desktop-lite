import Foundation
import Darwin

private let qwenModelName = "qwen3-asr-0.6b-q4_k.gguf"
private let qwenModelSHA256 = "f63771c02dfa486d9399d41ab6ab8cd2d8ca24e077cd32130ea1f67f4fd8dade"
private let qwenModelSize = 631_026_336
private let qwenModelDownloadURL = URL(
  string: "https://huggingface.co/cstr/qwen3-asr-0.6b-GGUF/resolve/79aa968855efd924b8dd6dde3deee949b9e7f052/\(qwenModelName)?download=true"
)!
private let qwenServer = QwenServer()

private enum QwenRuntimeError: LocalizedError {
  case runtimeMissing
  case processFailed(String, Int32)
  case processTimedOut(String)
  case serverUnavailable
  case invalidModel
  case emptyTranscript

  var errorDescription: String? {
    switch self {
    case .runtimeMissing:
      "Qwen ASR runtime is missing."
    case .processFailed(let name, let status):
      "\(name) failed with status \(status)."
    case .processTimedOut(let name):
      "\(name) timed out."
    case .serverUnavailable:
      "Qwen ASR server is unavailable."
    case .invalidModel:
      "The downloaded Qwen ASR model did not pass verification."
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

func transcribeWithQwen(audioURL: URL) throws -> String {
  do {
    return try qwenServer.transcribe(audioURL: audioURL)
  } catch QwenRuntimeError.emptyTranscript {
    throw QwenRuntimeError.emptyTranscript
  } catch {
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

private final class QwenServer {
  private let queue = DispatchQueue(label: "io.github.linea.qwen-server")
  private let port = 30_000 + Int(getpid() % 10_000)
  private var process: Process?

  func prepare() throws {
    try queue.sync {
      let (runtimeURL, modelURL) = try qwenRuntimeAndModel()
      try startIfNeeded(runtimeURL: runtimeURL, modelURL: modelURL)
    }
  }

  func transcribe(audioURL: URL) throws -> String {
    try queue.sync {
      defer { stopLocked() }
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

    for _ in 0..<100 {
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
}

private func ensureQwenModel() throws -> URL {
  let directory = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Linea Lite/models/qwen3-asr-0.6b-q4-k/\(qwenModelSHA256)")
  let modelURL = directory.appendingPathComponent(qwenModelName)
  let receiptURL = directory.appendingPathComponent("verified.sha256")
  let partialURL = directory.appendingPathComponent(qwenModelName + ".part")

  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  if validModel(at: modelURL, receiptURL: receiptURL) {
    try? qwenModelSHA256.write(to: receiptURL, atomically: true, encoding: .utf8)
    return modelURL
  }

  try? FileManager.default.removeItem(at: modelURL)
  try? FileManager.default.removeItem(at: receiptURL)
  if !validModel(at: partialURL, receiptURL: nil) {
    _ = try processOutput(
      executableURL: URL(fileURLWithPath: "/usr/bin/curl"),
      arguments: [
        "--location", "--fail", "--silent", "--show-error", "--continue-at", "-",
        "--output", partialURL.path, qwenModelDownloadURL.absoluteString,
      ]
    )
  }
  guard validModel(at: partialURL, receiptURL: nil) else {
    throw QwenRuntimeError.invalidModel
  }

  try FileManager.default.moveItem(at: partialURL, to: modelURL)
  try qwenModelSHA256.write(to: receiptURL, atomically: true, encoding: .utf8)
  return modelURL
}

private func validModel(at url: URL, receiptURL: URL?) -> Bool {
  guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
        size == qwenModelSize else { return false }
  if let receiptURL,
     (try? String(contentsOf: receiptURL, encoding: .utf8)) == qwenModelSHA256 {
    return true
  }
  guard let output = try? processOutput(
    executableURL: URL(fileURLWithPath: "/usr/bin/shasum"),
    arguments: ["-a", "256", url.path]
  ) else { return false }
  return output.hasPrefix(qwenModelSHA256)
}

func processOutput(
  executableURL: URL,
  arguments: [String],
  timeout: TimeInterval? = nil
) throws -> String {
  let process = Process()
  let output = Pipe()
  let finished = DispatchSemaphore(value: 0)
  process.executableURL = executableURL
  process.arguments = arguments
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  process.terminationHandler = { _ in finished.signal() }
  try process.run()

  if let timeout, finished.wait(timeout: .now() + timeout) == .timedOut {
    process.terminate()
    process.waitUntilExit()
    throw QwenRuntimeError.processTimedOut(executableURL.lastPathComponent)
  }
  if timeout == nil {
    finished.wait()
  }
  let data = output.fileHandleForReading.readDataToEndOfFile()
  guard process.terminationStatus == 0 else {
    throw QwenRuntimeError.processFailed(executableURL.lastPathComponent, process.terminationStatus)
  }
  return String(decoding: data, as: UTF8.self)
}
