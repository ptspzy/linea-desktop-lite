import Foundation

private let qwenModelName = "qwen3-asr-0.6b-q4_k.gguf"
private let qwenModelSHA256 = "f63771c02dfa486d9399d41ab6ab8cd2d8ca24e077cd32130ea1f67f4fd8dade"
private let qwenModelSize = 631_026_336
private let qwenModelDownloadURL = URL(
  string: "https://huggingface.co/cstr/qwen3-asr-0.6b-GGUF/resolve/79aa968855efd924b8dd6dde3deee949b9e7f052/\(qwenModelName)?download=true"
)!

private enum QwenRuntimeError: LocalizedError {
  case runtimeMissing
  case processFailed(String, Int32)
  case invalidModel
  case emptyTranscript

  var errorDescription: String? {
    switch self {
    case .runtimeMissing:
      "Qwen ASR runtime is missing."
    case .processFailed(let name, let status):
      "\(name) failed with status \(status)."
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

func cleanedQwenOutput(_ value: String) -> String {
  cleanedTranscript(value)
}

func transcribeWithQwen(audioURL: URL) throws -> String {
  guard let resourceURL = Bundle.main.resourceURL else {
    throw QwenRuntimeError.runtimeMissing
  }
  let runtimeURL = resourceURL.appendingPathComponent("bin/qwen-asr")
  guard FileManager.default.isExecutableFile(atPath: runtimeURL.path) else {
    throw QwenRuntimeError.runtimeMissing
  }

  let modelURL = try ensureQwenModel()
  let output = try processOutput(
    executableURL: runtimeURL,
    arguments: qwenCommandArguments(modelURL: modelURL, audioURL: audioURL)
  )
  let text = cleanedQwenOutput(output)
  guard !text.isEmpty else { throw QwenRuntimeError.emptyTranscript }
  return text
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

private func processOutput(executableURL: URL, arguments: [String]) throws -> String {
  let process = Process()
  let output = Pipe()
  process.executableURL = executableURL
  process.arguments = arguments
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  try process.run()
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    throw QwenRuntimeError.processFailed(executableURL.lastPathComponent, process.terminationStatus)
  }
  return String(decoding: data, as: UTF8.self)
}
