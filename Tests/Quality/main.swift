import AVFoundation
import Foundation

private func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
  var previous = Array(0...rhs.count)
  for (leftIndex, left) in lhs.enumerated() {
    var current = [leftIndex + 1]
    for (rightIndex, right) in rhs.enumerated() {
      current.append(min(
        current[rightIndex] + 1,
        previous[rightIndex + 1] + 1,
        previous[rightIndex] + (left == right ? 0 : 1)
      ))
    }
    previous = current
  }
  return previous[rhs.count]
}

private enum QualityError: LocalizedError {
  case failed(String)
  var errorDescription: String? {
    switch self { case .failed(let message): message }
  }
}

// Only use the checked-in synthetic fixture here, never a user's corpus recording.
private func writeLongFixture(from source: URL, to destination: URL) throws {
  let input = try AVAudioFile(forReading: source)
  let format = input.processingFormat
  guard input.length > 0, Double(input.length) / format.sampleRate < 20,
        let long = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate * 80) + AVAudioFrameCount(input.length))
  else { throw QualityError.failed("Long-fixture source must be a short synthetic recording.") }
  let clip = try readRecognitionAudioFrames(input, count: AVAudioFrameCount(input.length))
  long.frameLength = long.frameCapacity
  guard let sourceChannels = clip.floatChannelData, let channels = long.floatChannelData else {
    throw QualityError.failed("Long-fixture audio must decode to float PCM.")
  }
  for channel in 0..<Int(format.channelCount) {
    channels[channel].update(repeating: 0, count: Int(long.frameLength))
    for seconds in [0, 40, 80] {
      channels[channel].advanced(by: Int(format.sampleRate * Double(seconds)))
        .update(from: sourceChannels[channel], count: Int(clip.frameLength))
    }
  }
  try autoreleasepool {
    let file = try AVAudioFile(forWriting: destination, settings: format.settings)
    try file.write(from: long)
  }
}

private func checkQuality() throws {
  var arguments = Array(CommandLine.arguments.dropFirst())
  let longFixture = arguments.first == "--long-fixture"
  if longFixture { arguments.removeFirst() }
  guard arguments.count >= 2 else {
    throw QualityError.failed("usage: quality-check [--long-fixture] AUDIO REFERENCE [REQUIRED_TERM...]")
  }
  let environment = ProcessInfo.processInfo.environment
  guard let runtimePath = environment["LINEA_QWEN_RUNTIME"],
        let modelPath = environment["LINEA_MODEL_PATH"],
        let architecture = QwenRuntimeConfiguration.Architecture(rawValue: environment["LINEA_RUNTIME_ARCH"] ?? "")
  else { throw QualityError.failed("Set LINEA_QWEN_RUNTIME, LINEA_MODEL_PATH and LINEA_RUNTIME_ARCH (arm64 or x86_64).") }
  let runtime = QwenRuntimeConfiguration(
    runtimeURL: URL(fileURLWithPath: runtimePath), modelURL: URL(fileURLWithPath: modelPath), architecture: architecture
  )
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linea-quality-audio-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  defer {
    stopQwen()
    try? FileManager.default.removeItem(at: directory)
  }
  var audioURL = URL(fileURLWithPath: arguments[0])
  var reference = arguments[1]
  if longFixture {
    let longURL = directory.appendingPathComponent("controlled-long.wav")
    try writeLongFixture(from: audioURL, to: longURL)
    audioURL = longURL
    reference = Array(repeating: reference, count: 3).joined()
  }
  var completedSegments = 0
  let started = ProcessInfo.processInfo.systemUptime
  let raw = try transcribeWithQwen(audioURL: audioURL, runtime: runtime) { event in
    switch event {
    case .serverReady(let cold, let seconds):
      fputs(String(format: "Runtime %@ %.3fs (%@)\n", cold ? "cold" : "warm", seconds, architecture.rawValue), stderr)
    case .retry(let segment, let total, let reason):
      fputs("Retry segment \(segment)/\(total): \(reason)\n", stderr)
    case .silentSegmentSkipped(let segment, let total):
      fputs("Near-silent segment \(segment)/\(total) skipped\n", stderr)
    case .segmentCompleted(let segment, let total, let attempts, let seconds):
      completedSegments += 1
      fputs(String(format: "Segment %d/%d attempts=%d %.3fs\n", segment, total, attempts, seconds), stderr)
    case .completed(let seconds):
      fputs(String(format: "Pipeline %.3fs\n", seconds), stderr)
    }
  }
  fputs(String(format: "Total including model verification %.3fs\n", ProcessInfo.processInfo.systemUptime - started), stderr)
  guard !longFixture || completedSegments >= 3 else {
    throw QualityError.failed("Controlled long audio must traverse at least three production segments.")
  }
  let finalText = formattedTranscript(
    applyWorkspaceVocabulary(to: raw, entries: defaultDeveloperVocabulary), paragraphBreaks: true
  )
  let missingTerms = arguments.dropFirst(2).filter { !finalText.contains($0) }
  let distance = editDistance(Array(finalText), Array(reference))
  let cer = Double(distance) / Double(max(1, reference.count))
  let maximumCER = Double(environment["LINEA_MAX_CER"] ?? "") ?? 0.20
  guard maximumCER.isFinite, maximumCER >= 0 else { throw QualityError.failed("LINEA_MAX_CER must be finite and nonnegative.") }
  print(finalText)
  fputs(String(format: "CER %.4f\n", cer), stderr)
  guard missingTerms.isEmpty else { throw QualityError.failed("Missing terms: \(missingTerms.joined(separator: ", "))") }
  guard cer <= maximumCER else {
    throw QualityError.failed(String(format: "CER %.4f exceeds %.2f", cer, maximumCER))
  }
  if longFixture {
    let occurrences = finalText.components(separatedBy: "Qwen3-ASR").count - 1
    guard occurrences == 3 else { throw QualityError.failed("Long-audio completeness: expected all three synthetic utterances, got \(occurrences).") }
    print("PASS: controlled long-audio production pipeline (\(completedSegments) segments)")
  }
}

do {
  try checkQuality()
} catch {
  fputs("Quality check failed: \(error.localizedDescription)\n", stderr)
  exit(1)
}
