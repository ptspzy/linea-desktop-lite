import Foundation

final class CaptureRecovery {
  struct Recording {
    let url: URL
    let duration: TimeInterval
    let expiresAt: Date
  }

  private var recording: Recording?
  static let lifetime: TimeInterval = 10 * 60

  func available(at now: Date = Date()) -> Recording? {
    guard let recording else { return nil }
    guard recording.expiresAt > now, FileManager.default.fileExists(atPath: recording.url.path) else {
      discard()
      return nil
    }
    return recording
  }

  func retain(url: URL, duration: TimeInterval, now: Date = Date()) {
    if recording?.url != url { discard() }
    try? FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: now], ofItemAtPath: url.path)
    recording = Recording(url: url, duration: duration, expiresAt: now.addingTimeInterval(Self.lifetime))
  }

  func discard() {
    if let recording { try? FileManager.default.removeItem(at: recording.url) }
    recording = nil
  }

  func discard(ifMatching url: URL) {
    if recording?.url == url { discard() }
  }
}
