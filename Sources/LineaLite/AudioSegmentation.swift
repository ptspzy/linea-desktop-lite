import AVFoundation

func silenceAwareSegmentRanges(
  samples: [Float],
  sampleRate: Double,
  targetDuration: TimeInterval = 45,
  maximumDuration: TimeInterval = 60,
  searchDuration: TimeInterval = 6,
  overlapDuration: TimeInterval = 0.4,
  silenceThreshold: Float = 0.02
) -> [Range<Int>] {
  guard !samples.isEmpty, sampleRate > 0 else { return [] }
  let maximumFrames = max(1, Int(maximumDuration * sampleRate))
  guard samples.count > maximumFrames else { return [0..<samples.count] }

  let targetFrames = min(maximumFrames, max(1, Int(targetDuration * sampleRate)))
  let searchFrames = max(1, Int(searchDuration * sampleRate))
  let overlapFrames = min(targetFrames / 2, max(0, Int(overlapDuration * sampleRate)))
  let windowFrames = max(1, Int(0.2 * sampleRate))
  let strideFrames = max(1, Int(0.1 * sampleRate))
  var ranges: [Range<Int>] = []
  var start = 0

  while samples.count - start > maximumFrames {
    let target = min(samples.count, start + targetFrames)
    let searchStart = max(start + 1, target - searchFrames)
    let searchEnd = min(samples.count, start + maximumFrames, target + searchFrames)
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
    bestBoundary = min(start + maximumFrames, max(start + overlapFrames + 1, bestBoundary))
    ranges.append(start..<bestBoundary)
    start = bestBoundary - overlapFrames
  }
  ranges.append(start..<samples.count)
  return ranges
}

func mergedTranscriptParts(_ parts: [String], maximumOverlap: Int = 80) -> String {
  guard var result = parts.first else { return "" }
  for part in parts.dropFirst() where !part.isEmpty {
    let overlapLimit = min(maximumOverlap, result.count, part.count)
    let overlap = stride(from: overlapLimit, through: 1, by: -1).first {
      result.suffix($0) == part.prefix($0)
    } ?? 0
    result += part.dropFirst(overlap)
  }
  return result
}

func recognitionAudioSegments(at audioURL: URL) throws -> [URL] {
  let input = try AVAudioFile(forReading: audioURL)
  guard input.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
  guard input.length <= Int64(UInt32.max) else { throw CocoaError(.fileReadTooLarge) }
  let buffer = AVAudioPCMBuffer(
    pcmFormat: input.processingFormat,
    frameCapacity: AVAudioFrameCount(input.length)
  )!
  try input.read(into: buffer)
  guard let channel = buffer.floatChannelData?[0] else { return [audioURL] }
  let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
  let ranges = silenceAwareSegmentRanges(
    samples: samples,
    sampleRate: input.processingFormat.sampleRate
  )
  guard ranges.count > 1 else { return [audioURL] }

  var urls: [URL] = []
  do {
    for range in ranges {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("linea-lite-segment-\(UUID().uuidString).wav")
      input.framePosition = Int64(range.lowerBound)
      let segment = AVAudioPCMBuffer(
        pcmFormat: input.processingFormat,
        frameCapacity: AVAudioFrameCount(range.count)
      )!
      try input.read(into: segment, frameCount: AVAudioFrameCount(range.count))
      let output = try AVAudioFile(
        forWriting: url,
        settings: input.fileFormat.settings,
        commonFormat: input.processingFormat.commonFormat,
        interleaved: input.processingFormat.isInterleaved
      )
      try output.write(from: segment)
      urls.append(url)
    }
    return urls
  } catch {
    for url in urls { try? FileManager.default.removeItem(at: url) }
    throw error
  }
}
