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

guard CommandLine.arguments.count >= 4 else {
  fputs("usage: quality-check RAW REFERENCE REQUIRED_TERM...\n", stderr)
  exit(2)
}

let rawInput = CommandLine.arguments[1]
let raw = (try? qwenServerTranscript(rawInput)) ?? rawInput
let reference = CommandLine.arguments[2]
let requiredTerms = CommandLine.arguments.dropFirst(3)
let finalText = formattedTranscript(
  applyWorkspaceVocabulary(to: raw, entries: defaultDeveloperVocabulary),
  paragraphBreaks: true
)
let missingTerms = requiredTerms.filter { !finalText.contains($0) }
let distance = editDistance(Array(finalText), Array(reference))
let cer = Double(distance) / Double(max(1, reference.count))

print(finalText)
fputs(String(format: "CER %.4f\n", cer), stderr)
guard missingTerms.isEmpty else {
  fputs("Missing terms: \(missingTerms.joined(separator: ", "))\n", stderr)
  exit(1)
}
guard cer <= 0.20 else {
  fputs(String(format: "CER %.4f exceeds 0.20\n", cer), stderr)
  exit(1)
}
