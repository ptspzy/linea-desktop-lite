import AVFoundation

func silenceAwareSegmentRanges(
  samples: [Float],
  sampleRate: Double,
  targetDuration: TimeInterval = 40,
  maximumDuration: TimeInterval = 60,
  searchDuration: TimeInterval = 6,
  overlapDuration: TimeInterval = 0.4,
  minimumTailDuration: TimeInterval = 8,
  silenceThreshold: Float = 0.02
) -> [Range<Int>] {
  guard !samples.isEmpty, sampleRate > 0 else { return [] }
  let maximumFrames = max(1, Int(maximumDuration * sampleRate))
  let targetFrames = min(maximumFrames, max(1, Int(targetDuration * sampleRate)))
  let minimumTailFrames = max(1, Int(minimumTailDuration * sampleRate))
  guard samples.count > maximumFrames || samples.count > targetFrames + minimumTailFrames else {
    return [0..<samples.count]
  }
  let searchFrames = max(1, Int(searchDuration * sampleRate))
  let overlapFrames = min(targetFrames / 2, max(0, Int(overlapDuration * sampleRate)))
  let windowFrames = max(1, Int(0.2 * sampleRate))
  let strideFrames = max(1, Int(0.1 * sampleRate))
  var ranges: [Range<Int>] = []
  var start = 0

  while samples.count - start > maximumFrames
    || samples.count - start > targetFrames + minimumTailFrames {
    let latestBoundary = min(start + maximumFrames, samples.count - minimumTailFrames)
    let target = min(latestBoundary, start + targetFrames)
    let searchStart = max(start + 1, target - searchFrames)
    let searchEnd = min(latestBoundary, target + searchFrames)
    var bestBoundary = target
    var bestLevel = Float.greatestFiniteMagnitude
    var candidate = searchStart

    while candidate + windowFrames <= searchEnd {
      let level = samples[candidate..<(candidate + windowFrames)]
        .reduce(Float(0)) { $0 + abs($1) } / Float(windowFrames)
      if level < bestLevel {
        bestLevel = level
        bestBoundary = candidate + windowFrames / 2
      }
      candidate += strideFrames
    }
    if bestLevel > silenceThreshold { bestBoundary = target }
    bestBoundary = min(latestBoundary, max(start + overlapFrames + 1, bestBoundary))
    ranges.append(start..<bestBoundary)
    start = bestBoundary - overlapFrames
  }
  ranges.append(start..<samples.count)
  return ranges
}

private let boundaryTokenExpression = try! NSRegularExpression(
  pattern: #"\p{Han}|[\p{L}\p{M}\p{N}&&[^\p{Han}]]+(?:[.'’/_+\-][\p{L}\p{M}\p{N}&&[^\p{Han}]]+)*|[^\s，。！？；：、,.!?;:]"#
)

private func boundaryTokens(_ text: String) -> [(text: String, range: Range<String.Index>)] {
  boundaryTokenExpression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
    guard let range = Range($0.range, in: text) else { return nil }
    return (String(text[range]).lowercased(), range)
  }
}

private func isHanCharacter(_ character: Character) -> Bool {
  character.unicodeScalars.allSatisfy {
    (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
      || (0x20000...0x323AF).contains($0.value)
  }
}

func mergedTranscriptParts(_ parts: [String], maximumOverlap: Int = 80) -> String {
  var result = ""
  for rawPart in parts {
    let part = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !part.isEmpty else { continue }
    let left = boundaryTokens(result)
    let right = boundaryTokens(part)
    var remainder = part[...]
    // Text alone cannot prove an acoustic overlap. Keep short and whole-utterance repetition.
    // ponytail: conservative boundary heuristic; word timestamps are the upgrade for ambiguous repeats.
    let limit = min(left.count - 1, right.count - 1)
    if limit >= 2, maximumOverlap > 0 {
      for count in stride(from: limit, through: 2, by: -1) {
        let suffix = left.suffix(count)
        let prefix = right.prefix(count)
        guard result[suffix.first!.range.lowerBound...].count <= maximumOverlap,
              part[..<prefix.last!.range.upperBound].count <= maximumOverlap,
              suffix.map(\.text) == prefix.map(\.text) else { continue }
        let tokens = prefix.map(\.text)
        let characters = tokens.joined()
        guard Set(tokens).count >= 2,
              (characters.allSatisfy(isHanCharacter) ? count >= 3 : count >= 2 && characters.count >= 8)
        else { continue }
        // Do not collapse repeated phrases such as "thank you thank you".
        let repeated = (1...count / 2).contains { unit in
          count.isMultiple(of: unit) && tokens.indices.allSatisfy { tokens[$0] == tokens[$0 % unit] }
        }
        let repeatedBefore = left.count >= count * 2 && left.dropLast(count).suffix(count).map(\.text) == tokens
        let repeatedAfter = right.count >= count * 2 && right.dropFirst(count).prefix(count).map(\.text) == tokens
        guard !repeated, !repeatedBefore, !repeatedAfter else { continue }
        remainder = part[right[count].range.lowerBound...]
        break
      }
    }
    if let last = result.last, let first = remainder.first,
       !last.isWhitespace, !first.isWhitespace,
       first.isLetter || first.isNumber,
       !(isHanCharacter(last) && isHanCharacter(first)),
       last.isASCII || (!isHanCharacter(first) && (last.isLetter || last.isNumber)) {
      result += " "
    }
    result += remainder
  }
  return result
}

func recognitionAudioIsNearSilent(at audioURL: URL) throws -> Bool {
  try recognitionAudioContentRange(at: audioURL) == nil
}

func recognitionAudioContentRange(at audioURL: URL) throws -> Range<AVAudioFramePosition>? {
  let input = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
  guard input.length > 0,
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_384) else {
    throw CocoaError(.fileReadCorruptFile)
  }
  var first: AVAudioFramePosition?
  var last: AVAudioFramePosition = 0
  while input.framePosition < input.length {
    let offset = input.framePosition
    try input.read(into: buffer)
    guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
      throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Could not inspect decoded audio for silence."])
    }
    for frame in 0..<Int(buffer.frameLength) {
      let hasContent = (0..<Int(buffer.format.channelCount)).contains { channel in
        let sample = channels[channel][frame]
        // Below one 16-bit PCM step; this is proof of near-silence, not a speech/noise gate.
        return !sample.isFinite || abs(sample) > 0.00001
      }
      if hasContent {
        if first == nil { first = offset + AVAudioFramePosition(frame) }
        last = offset + AVAudioFramePosition(frame)
      }
    }
  }
  guard let first else { return nil }
  let context = AVAudioFramePosition(ceil(input.processingFormat.sampleRate * 0.25))
  return max(0, first - context)..<min(input.length, last + 1 + context)
}

// Trim only verified near-silent edges. The retained span includes all interior pauses/quiet speech.
func recognitionAudioForInference(at audioURL: URL) throws -> URL? {
  guard let range = try recognitionAudioContentRange(at: audioURL) else { return nil }
  let input = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
  guard range.count < input.length else { return audioURL }
  guard range.count <= UInt32.max else { throw CocoaError(.fileReadTooLarge) }
  input.framePosition = range.lowerBound
  let buffer = try readRecognitionAudioFrames(input, count: AVAudioFrameCount(range.count))
  return try writeRecognitionAudio(buffer, settings: input.fileFormat.settings)
}

func readRecognitionAudioFrames(_ input: AVAudioFile, count: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
  guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: count),
        buffer.stride == 1, let channels = buffer.floatChannelData else {
    throw CocoaError(.fileReadCorruptFile)
  }
  try input.read(into: buffer, frameCount: count)
  // AVAudioFile may return a successful short read before EOF (including a partial converter packet).
  while buffer.frameLength < count {
    let remaining = count - buffer.frameLength
    guard let tail = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: remaining),
          let tailChannels = tail.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
    try input.read(into: tail, frameCount: remaining)
    guard tail.frameLength > 0 else {
      throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Incomplete audio decode: \(buffer.frameLength) of \(count) frames."])
    }
    for channel in 0..<Int(buffer.format.channelCount) {
      channels[channel].advanced(by: Int(buffer.frameLength)).update(from: tailChannels[channel], count: Int(tail.frameLength))
    }
    buffer.frameLength += tail.frameLength
  }
  return buffer
}

func recognitionAudioSegments(at audioURL: URL) throws -> [URL] {
  let input = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
  guard input.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
  guard input.length <= Int64(UInt32.max) else { throw CocoaError(.fileReadTooLarge) }
  let buffer = try readRecognitionAudioFrames(input, count: AVAudioFrameCount(input.length))
  let channel = buffer.floatChannelData![0]
  let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
  let ranges = silenceAwareSegmentRanges(
    samples: samples,
    sampleRate: input.processingFormat.sampleRate
  )
  guard ranges.count > 1 else { return [audioURL] }

  var urls: [URL] = []
  do {
    for range in ranges {
      input.framePosition = Int64(range.lowerBound)
      let segment = try readRecognitionAudioFrames(input, count: AVAudioFrameCount(range.count))
      urls.append(try writeRecognitionAudio(segment, settings: input.fileFormat.settings))
    }
    return urls
  } catch {
    for url in urls { try? FileManager.default.removeItem(at: url) }
    throw error
  }
}

private func writeRecognitionAudio(_ buffer: AVAudioPCMBuffer, settings: [String: Any]) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("linea-lite-segment-\(UUID().uuidString).wav")
  do {
    // AVAudioFile.close() requires macOS 15; drain the writer to finalize PCM tails on macOS 13.
    try autoreleasepool {
      let output = try AVAudioFile(
        forWriting: url, settings: settings,
        commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved
      )
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      try output.write(from: buffer)
    }
    return url
  } catch {
    try? FileManager.default.removeItem(at: url)
    throw error
  }
}
