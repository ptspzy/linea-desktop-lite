import AVFoundation
import Foundation

private func recognitionExpect(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: recognition regression: \(message)\n", stderr)
    exit(1)
  }
}

func runRecognitionRegressionTests() {
  var stage = "boundary merge"
  do {
    let merges: [([String], String)] = [
      (["第一句最后内容", "最后内容第二句", "第二句完成"], "第一句最后内容第二句完成"),
      (["请检查最后内容。", "最后，内容，接着处理"], "请检查最后内容。接着处理"),
      (["Please check the build.", "Check the BUILD, then ship."], "Please check the build. then ship."),
      (["hello", "world"], "hello world"),
      (["Hello.", "World."], "Hello. World."),
      (["cat", "at home"], "cat at home"),
      (["We need to go", "go now"], "We need to go go now"),
      (["你好", "你好"], "你好你好"),
      (["这个真的", "真的很好"], "这个真的真的很好"),
      (["Thank you.", "Thank you."], "Thank you. Thank you."),
      (["I said thank you thank you", "thank you thank you again"], "I said thank you thank you thank you thank you again"),
      (["Use version 3.1", "version 31 next"], "Use version 3.1 version 31 next"),
      (["Use the foo-bar", "the foo bar again"], "Use the foo-bar the foo bar again"),
      (["", "  first  ", "", "second"], "first second"),
      (["更新完成。", "继续检查。"], "更新完成。继续检查。"),
    ]
    for (parts, expected) in merges {
      let actual = mergedTranscriptParts(parts)
      recognitionExpect(actual == expected, "merge \(parts): \(actual), expected \(expected)")
    }
    recognitionExpect(mergedTranscriptParts(["one", "two"], maximumOverlap: -1) == "one two", "negative overlap")
    recognitionExpect(mergedTranscriptParts([]).isEmpty, "empty parts")
    recognitionExpect(hasPathologicalRepetition(String(repeating: "broken phrase ", count: 8).trimmingCharacters(in: .whitespaces)), "trimmed pathological phrase")
    let processTranscript = try processOutput(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "printf 'Only transcript'; printf 'backend diagnostics' >&2"], timeout: 2
    )
    recognitionExpect(processTranscript == "Only transcript", "CLI fallback cannot insert stderr diagnostics into speech")
    do {
      _ = try processOutput(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf 'backend failure' >&2; exit 7"], timeout: 2)
      recognitionExpect(false, "failed process must throw")
    } catch {
      recognitionExpect(error.localizedDescription.contains("backend failure"), "stderr remains available for failed processes")
    }

    let configuration = QwenRuntimeConfiguration(
      runtimeURL: URL(fileURLWithPath: "/tmp/runtime with spaces"),
      modelURL: URL(fileURLWithPath: "/tmp/model"), architecture: .x86_64
    )
    let command = configuration.command(arguments: ["--server"])
    recognitionExpect(command.executableURL.path == "/usr/bin/arch", "explicit runtime architecture launcher")
    recognitionExpect(command.arguments == ["-x86_64", "/tmp/runtime with spaces", "--server"], "architecture arguments remain separate")
    recognitionExpect(
      qwenAudioFormArgument(URL(fileURLWithPath: "/tmp/a,b;\"c.wav")) == "file=@\"/tmp/a,b;\\\"c.wav\"",
      "curl form quoting"
    )

    stage = "controlled voiced audio"
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent("linea-recognition-tests-\(UUID().uuidString)")
    try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: directory) }
    let audioURL = directory.appendingPathComponent("controlled.wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 840_000)!
    buffer.frameLength = buffer.frameCapacity
    for index in 0..<Int(buffer.frameLength) {
      buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.17)) * 0.3
    }
    try autoreleasepool {
      let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
      try file.write(from: buffer)
    }
    let original = try Data(contentsOf: audioURL)
    let voicedIsSilent = try recognitionAudioIsNearSilent(at: audioURL)
    recognitionExpect(!voicedIsSilent, "voiced audio is never classified as silence")
    var segments: [URL] = []
    var attempts: [Int] = []
    var events: [QwenRuntimeDiagnostic] = []
    stage = "voiced middle retry"
    let recovered = try transcribeRecognitionSegments(audioURL: audioURL, diagnostics: { events.append($0) }) { url, attempt in
      if attempt == 0 { segments.append(url) }
      attempts.append(attempt)
      if segments.count == 2 && attempt == 0 { return " \n " }
      return ["Opening marker.", "Middle marker.", "Ending marker."][segments.count - 1]
    }
    recognitionExpect(recovered == "Opening marker. Middle marker. Ending marker.", "complete transcript after empty middle retry")
    recognitionExpect(attempts == [0, 0, 1, 0], "one bounded recovery attempt")
    recognitionExpect(segments.count == 3 && segments.allSatisfy { !manager.fileExists(atPath: $0.path) }, "success cleans generated segments")
    recognitionExpect(events.contains { if case .retry(segment: 2, total: 3, reason: _) = $0 { return true }; return false }, "retry diagnostic")

    stage = "voiced failure cleanup"
    for failureMode in 0..<3 {
      segments.removeAll()
      attempts.removeAll()
      do {
        _ = try transcribeRecognitionSegments(audioURL: audioURL) { url, attempt in
          if attempt == 0 { segments.append(url) }
          attempts.append(attempt)
          guard segments.count == 2 else { return "Opening marker." }
          if failureMode == 0 { return "" }
          if failureMode == 1 { return String(repeating: "broken phrase ", count: 8) }
          throw CocoaError(.fileReadUnknown)
        }
        recognitionExpect(false, "incomplete recognition must not succeed")
      } catch {
        recognitionExpect(error.localizedDescription.contains("segment 2 of 3 after 2 attempts"), "actionable partial failure: \(error)")
      }
      recognitionExpect(attempts == [0, 0, 1], "failure cannot skip ahead or retry indefinitely")
      recognitionExpect(segments.allSatisfy { !manager.fileExists(atPath: $0.path) }, "failure cleans generated segments")
      let remaining = try Data(contentsOf: audioURL)
      recognitionExpect(remaining == original, "original audio remains byte-identical on failure")
    }

    stage = "long silent pause"
    // Long pauses must use the same production segmenter, including overlap at each boundary.
    for index in 0..<Int(buffer.frameLength) {
      buffer.floatChannelData![0][index] = index < 8_000 || index >= 800_000 ? 0.1 : 0
    }
    let pausesURL = directory.appendingPathComponent("long-pauses.wav")
    try autoreleasepool {
      let file = try AVAudioFile(forWriting: pausesURL, settings: format.settings)
      try file.write(from: buffer)
    }
    var spokenSegments = 0
    var skippedSegments = 0
    var inferenceDurations: [Double] = []
    let withPauses = try transcribeRecognitionSegments(audioURL: pausesURL, diagnostics: { event in
      if case .silentSegmentSkipped = event { skippedSegments += 1 }
    }) { url, attempt in
      recognitionExpect(attempt == 0, "silent segments require no retry")
      let file = try AVAudioFile(forReading: url)
      inferenceDurations.append(Double(file.length) / file.processingFormat.sampleRate)
      spokenSegments += 1
      return spokenSegments == 1 ? "Opening marker." : "Ending marker."
    }
    recognitionExpect(withPauses == "Opening marker. Ending marker.", "long pause retains both voiced ends")
    recognitionExpect(spokenSegments == 2 && skippedSegments >= 1, "only positively silent production segments are skipped")
    recognitionExpect(inferenceDurations == [1.25, 5.25], "long pause is removed only from inference edges with 250ms context")

    stage = "quiet stereo"
    let quietFormat = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 2)!
    let quietBuffer = AVAudioPCMBuffer(pcmFormat: quietFormat, frameCapacity: 8_000)!
    quietBuffer.frameLength = 8_000
    for channel in 0..<2 { quietBuffer.floatChannelData![channel].update(repeating: 0, count: 8_000) }
    quietBuffer.floatChannelData![1][7_999] = 0.0001
    let quietURL = directory.appendingPathComponent("quiet-stereo.wav")
    try autoreleasepool {
      let file = try AVAudioFile(forWriting: quietURL, settings: quietFormat.settings)
      try file.write(from: quietBuffer)
    }
    let quietIsSilent = try recognitionAudioIsNearSilent(at: quietURL)
    recognitionExpect(!quietIsSilent, "quiet speech in any channel is not skipped")
    var quietAttempts = 0
    do {
      _ = try transcribeRecognitionSegments(audioURL: quietURL) { _, _ in quietAttempts += 1; return "" }
      recognitionExpect(false, "quiet voiced-empty result must fail")
    } catch {
      recognitionExpect(quietAttempts == 2, "quiet voiced-empty gets bounded retry")
    }

    stage = "edge silence trimming"
    let edgeBuffer = AVAudioPCMBuffer(pcmFormat: quietFormat, frameCapacity: 80_000)!
    edgeBuffer.frameLength = edgeBuffer.frameCapacity
    for channel in 0..<2 { edgeBuffer.floatChannelData![channel].update(repeating: 0, count: 80_000) }
    edgeBuffer.floatChannelData![1][16_000] = 0.0001
    edgeBuffer.floatChannelData![0][63_999] = -0.0001
    // Interior audio, even below the silence threshold, must be retained without alteration.
    for frame in 24_000..<56_000 { edgeBuffer.floatChannelData![1][frame] = 0.000001 }
    let edgeURL = directory.appendingPathComponent("silent-edges.wav")
    try autoreleasepool {
      let file = try AVAudioFile(forWriting: edgeURL, settings: quietFormat.settings)
      try file.write(from: edgeBuffer)
    }
    let edgeOriginal = try Data(contentsOf: edgeURL)
    let contentRange = try recognitionAudioContentRange(at: edgeURL)
    recognitionExpect(contentRange == 14_000..<66_000, "all-channel quiet edges plus 250ms context")
    let trimmedURL = try recognitionAudioForInference(at: edgeURL)!
    let trimmedFile = try AVAudioFile(forReading: trimmedURL)
    let trimmed = try readRecognitionAudioFrames(trimmedFile, count: AVAudioFrameCount(trimmedFile.length))
    recognitionExpect(trimmed.frameLength == 52_000, "only outer silence is removed")
    for channel in 0..<2 {
      let retained = UnsafeBufferPointer(start: trimmed.floatChannelData![channel], count: 52_000)
      let expected = UnsafeBufferPointer(start: edgeBuffer.floatChannelData![channel] + 14_000, count: 52_000)
      recognitionExpect(retained.elementsEqual(expected), "retained audio is sample-identical, including quiet interior")
    }
    try manager.removeItem(at: trimmedURL)
    for shouldFail in [false, true] {
      var inferenceURLs: [URL] = []
      do {
        _ = try transcribeRecognitionSegments(audioURL: edgeURL) { url, _ in
          inferenceURLs.append(url)
          return shouldFail ? "" : "Retained quiet speech."
        }
        recognitionExpect(!shouldFail, "voiced trimmed audio cannot silently succeed empty")
      } catch {
        recognitionExpect(shouldFail && inferenceURLs.count == 2, "trimmed voiced-empty gets exactly two attempts")
      }
      recognitionExpect(inferenceURLs.allSatisfy { $0 != edgeURL && !manager.fileExists(atPath: $0.path) }, "trimmed inference copies are cleaned on success/failure")
      recognitionExpect((try? Data(contentsOf: edgeURL)) == edgeOriginal, "trimming never changes the caller's recording")
    }
    var cancelledURLs: [URL] = []
    var cancellationRetried = false
    do {
      _ = try transcribeRecognitionSegments(audioURL: edgeURL, diagnostics: { event in
        if case .retry = event { cancellationRetried = true }
      }) { url, _ in
        cancelledURLs.append(url)
        throw CancellationError()
      }
      recognitionExpect(false, "segment cancellation must propagate")
    } catch is CancellationError {
      recognitionExpect(cancelledURLs.count == 1 && !cancellationRetried, "cancellation is never retried")
      recognitionExpect(cancelledURLs.allSatisfy { !manager.fileExists(atPath: $0.path) }, "cancellation cleans trimmed copies")
      recognitionExpect((try? Data(contentsOf: edgeURL)) == edgeOriginal, "cancellation preserves original audio")
    }
    let untrimmedURL = try recognitionAudioForInference(at: audioURL)
    recognitionExpect(untrimmedURL == audioURL, "continuous audio is reused unchanged")

    stage = "atomic import"
    let modelSource = directory.appendingPathComponent("source.gguf")
    let installed = directory.appendingPathComponent("model.gguf")
    let receipt = directory.appendingPathComponent("verified.sha256")
    let digest = "9372c470eeadd5ecd9c3c74c2b3cb633f8e2f2fad799250a0f70d652b6b825e4"
    let oldData = Data("older".utf8)
    try oldData.write(to: installed)
    try "old receipt".write(to: receipt, atomically: true, encoding: .utf8)
    try Data("wrong".utf8).write(to: modelSource)
    do {
      try installVerifiedModel(from: modelSource, to: installed, receiptURL: receipt, expectedSize: 5, expectedSHA256: digest)
      recognitionExpect(false, "invalid replacement must fail")
    } catch {
      recognitionExpect(error.localizedDescription.contains("verification"), "invalid replacement error")
    }
    let oldInstalled = try Data(contentsOf: installed)
    let oldReceipt = try String(contentsOf: receipt, encoding: .utf8)
    recognitionExpect(oldInstalled == oldData && oldReceipt == "old receipt", "failed verification preserves installed model and receipt")
    recognitionExpect(manager.fileExists(atPath: modelSource.path), "failed import preserves source")

    let blockedDestination = directory.appendingPathComponent("blocked")
    try manager.createDirectory(at: blockedDestination, withIntermediateDirectories: true)
    try oldData.write(to: blockedDestination.appendingPathComponent("keep"))
    try Data("model".utf8).write(to: modelSource)
    do {
      try installVerifiedModel(from: modelSource, to: blockedDestination, receiptURL: receipt, expectedSize: 5, expectedSHA256: digest)
      recognitionExpect(false, "rename over a directory must fail")
    } catch {
      recognitionExpect(manager.fileExists(atPath: blockedDestination.appendingPathComponent("keep").path), "rename failure preserves destination")
      recognitionExpect(manager.fileExists(atPath: modelSource.path), "rename failure preserves source")
    }
    var progress: [QwenModelImportProgress] = []
    try installVerifiedModel(from: modelSource, to: installed, receiptURL: receipt, expectedSize: 5, expectedSHA256: digest) { stage in
      progress.append(stage)
      if stage == .installing {
        recognitionExpect((try? Data(contentsOf: installed)) == oldData, "old model exists until atomic commit")
      }
    }
    recognitionExpect(progress == [.copying, .verifying, .installing, .complete], "ordered import progress")
    recognitionExpect((try? Data(contentsOf: installed)) == Data("model".utf8), "replacement committed")
    recognitionExpect(!manager.fileExists(atPath: modelSource.path), "successful import maintains source move semantics")
    try installVerifiedModel(from: installed, to: installed, receiptURL: receipt, expectedSize: 5, expectedSHA256: digest)
    recognitionExpect((try? Data(contentsOf: installed)) == Data("model".utf8), "same-path import retains installed model")
    let files = try manager.contentsOfDirectory(atPath: directory.path)
    recognitionExpect(!files.contains { $0.hasSuffix(".staged") }, "import staging files are cleaned")
    print("PASS: recognition, boundary merge, and model replacement regressions")
  } catch {
    recognitionExpect(false, "\(stage): unexpected error: \(error)")
  }
}

func runRecognitionCancellationTests() async {
  do {
    let cancelledBeforeRun = Task.detached {
      while !Task.isCancelled { await Task.yield() }
      return try processOutput(executableURL: URL(fileURLWithPath: "/linea-cancelled-command-must-not-launch"), arguments: [])
    }
    cancelledBeforeRun.cancel()
    do {
      _ = try await cancelledBeforeRun.value
      recognitionExpect(false, "pre-cancelled process must not launch")
    } catch is CancellationError {}

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("linea-cancellation-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    for ignoresTermination in [false, true] {
      let marker = directory.appendingPathComponent(UUID().uuidString)
      let queue = DispatchQueue(label: "linea-cancellation-queue-test")
      let task = Task.detached {
        try queue.sync {
          try processOutput(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", (ignoresTermination ? "trap '' TERM; " : "") + #"printf '%s' "$$" > "$1"; exec /bin/sleep 20"#, "linea-test", marker.path],
            timeout: ignoresTermination ? 30 : nil
          )
        }
      }
      defer { task.cancel() }
      var pid: Int32?
      for _ in 0..<200 {
        if let text = try? String(contentsOf: marker, encoding: .utf8), let value = Int32(text) {
          pid = value
          break
        }
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      guard let pid else {
        task.cancel()
        _ = try? await task.value
        recognitionExpect(false, "cancellation child must start")
        return
      }
      let started = ProcessInfo.processInfo.systemUptime
      task.cancel()
      do {
        _ = try await task.value
        recognitionExpect(false, "queue.sync must preserve task cancellation")
      } catch is CancellationError {}
      let duration = ProcessInfo.processInfo.systemUptime - started
      recognitionExpect(duration < 2.5, "cancellation must terminate promptly, got \(duration)s")
      recognitionExpect(kill(pid, 0) == -1 && errno == ESRCH, "cancelled child must be reaped, including SIGTERM-resistant children")
      print(String(format: "PASS: process cancellation through queue.sync (ignore TERM=%@) %.3fs", ignoresTermination.description, duration))
    }
  } catch {
    recognitionExpect(false, "cancellation regression: \(error)")
  }
}

#if RECOGNITION_REGRESSION_STANDALONE
@main
private enum RecognitionRegressionMain {
  static func main() async {
    runRecognitionRegressionTests()
    await runRecognitionCancellationTests()
  }
}
#endif
