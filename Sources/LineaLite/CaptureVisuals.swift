import AVFoundation
import Foundation

private let maximumCaptureDuration: TimeInterval = 10 * 60

enum CapturePermissionAction: Equatable {
  case start
  case request
  case deny
}

func capturePermissionAction(for status: AVAuthorizationStatus) -> CapturePermissionAction {
  switch status {
  case .authorized:
    .start
  case .notDetermined:
    .request
  case .denied, .restricted:
    .deny
  @unknown default:
    .deny
  }
}

func captureAudioLevel(decibels: Float) -> Double {
  guard decibels > -60 else { return 0 }
  let amplitude = pow(10, Double(decibels) / 20)
  return pow(min(amplitude * 3.2, 1), 0.55)
}

func captureShouldAutomaticallyStop(duration: TimeInterval) -> Bool {
  duration >= maximumCaptureDuration
}

func removeStaleCaptureFiles(
  in directory: URL = FileManager.default.temporaryDirectory,
  now: Date = Date()
) {
  guard let files = try? FileManager.default.contentsOfDirectory(
    at: directory,
    includingPropertiesForKeys: [.contentModificationDateKey],
    options: .skipsHiddenFiles
  ) else { return }

  for file in files where file.lastPathComponent.hasPrefix("linea-lite-")
    && (["wav", "log"].contains(file.pathExtension) || file.lastPathComponent.hasSuffix(".log.stderr")) {
    guard let modifiedAt = try? file.resourceValues(
      forKeys: [.contentModificationDateKey]
    ).contentModificationDate,
      now.timeIntervalSince(modifiedAt) > CaptureRecovery.lifetime else { continue }
    try? FileManager.default.removeItem(at: file)
  }
}
