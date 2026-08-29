import Foundation

func cleanedTranscript(_ value: String) -> String {
  value
    .components(separatedBy: .whitespacesAndNewlines)
    .filter { !$0.isEmpty }
    .joined(separator: " ")
}

struct SpeechResultAccumulator {
  private var latestNonEmpty = ""

  mutating func accept(text: String, isFinal: Bool) -> String? {
    let cleaned = cleanedTranscript(text)
    if !cleaned.isEmpty {
      latestNonEmpty = cleaned
    }
    return isFinal ? latestNonEmpty : nil
  }
}
