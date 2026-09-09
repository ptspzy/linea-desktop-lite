import Foundation
import CryptoKit
import CoreServices

enum AppUpdateError: LocalizedError, Equatable {
  case invalidURL
  case invalidVersion
  case invalidManifest
  case incompatibleSystem(String)
  case invalidResponse
  case tooLarge
  case verificationFailed
  case invalidDestination

  var errorDescription: String? {
    switch self {
    case .invalidURL: "Use an HTTPS URL on a DNS host, without credentials, a fragment, or an unsafe path."
    case .invalidVersion: "Versions must contain one to three numeric components, without leading zeros."
    case .invalidManifest: "The update manifest is invalid or uses an unsupported schema."
    case .incompatibleSystem(let version): "This update requires macOS \(version) or newer."
    case .invalidResponse: "The update server returned an invalid response or redirect."
    case .tooLarge: "The update exceeds the allowed size."
    case .verificationFailed: "The downloaded DMG did not pass size, format, or SHA-256 verification."
    case .invalidDestination: "Choose a new .dmg file in an existing local folder; existing files are not replaced."
    }
  }
}

struct AppUpdateVersion: Comparable, Sendable {
  private let components: [Int]

  init(_ value: String) throws {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count), parts.allSatisfy({ part in
      (1...9).contains(part.utf8.count)
        && part.utf8.allSatisfy { (48...57).contains($0) }
        && (part.count == 1 || part.first != "0")
    }) else { throw AppUpdateError.invalidVersion }
    components = parts.map { Int($0)! } + Array(repeating: 0, count: 3 - parts.count)
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.components.lexicographicallyPrecedes(rhs.components)
  }
}

struct AppUpdateManifest: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let version: String
  let minimumSystemVersion: String
  let downloadURL: URL
  let sha256: String
  let byteCount: Int64?

  fileprivate enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion, version, minimumSystemVersion, downloadURL, sha256, byteCount
  }

  func validate() throws {
    guard schemaVersion == 1 else { throw AppUpdateError.invalidManifest }
    _ = try AppUpdateVersion(version)
    _ = try AppUpdateVersion(minimumSystemVersion)
    _ = try AppUpdate.validatedHTTPSURL(downloadURL.absoluteString)
    guard downloadURL.pathExtension.lowercased() == "dmg", !downloadURL.hasDirectoryPath,
          sha256.utf8.count == 64,
          sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      throw AppUpdateError.invalidManifest
    }
    if let byteCount, !(512...AppUpdate.maximumDownloadBytes).contains(byteCount) {
      throw AppUpdateError.invalidManifest
    }
  }
}

struct AppUpdateProgress: Sendable {
  let receivedBytes: Int64
  let totalBytes: Int64?

  var fractionCompleted: Double? {
    totalBytes.flatMap { $0 > 0 ? min(1, Double(receivedBytes) / Double($0)) : nil }
  }
}

enum AppUpdate {
  static let maximumManifestBytes: Int64 = 64 * 1024
  static let maximumDownloadBytes: Int64 = 1024 * 1024 * 1024

  // This is a URL policy, not a DNS/IP firewall. Only configure a feed operator you trust.
  static func validatedHTTPSURL(_ value: String) throws -> URL {
    guard value.utf8.count <= 8192,
          value.utf8.allSatisfy({ (33...126).contains($0) && $0 != 92 }),
          let parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
          parts.user == nil, parts.password == nil, parts.fragment == nil,
          parts.port == nil || (1...65535).contains(parts.port!),
          let host = parts.host?.lowercased(), host.count <= 253,
          let path = parts.percentEncodedPath.removingPercentEncoding,
          !path.contains("\\"), !path.contains("%"),
          path.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
          !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
          let url = parts.url else { throw AppUpdateError.invalidURL }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    let localSuffixes = ["localhost", "local", "invalid"]
    guard labels.allSatisfy({ label in
            (1...63).contains(label.count) && label.first != "-" && label.last != "-"
              && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
          }),
          let suffix = labels.last,
          suffix.utf8.allSatisfy({ (97...122).contains($0) }),
          !localSuffixes.contains(String(suffix)) else { throw AppUpdateError.invalidURL }
    return url
  }

  static func permitsRedirect(from original: URL, to next: URL, sameOrigin: Bool) -> Bool {
    guard (try? validatedHTTPSURL(next.absoluteString)) != nil else { return false }
    return !sameOrigin || (next.host?.lowercased() == original.host?.lowercased()
      && (next.port ?? 443) == (original.port ?? 443))
  }

  static func parseManifest(_ data: Data) throws -> AppUpdateManifest {
    guard data.count <= maximumManifestBytes else { throw AppUpdateError.tooLarge }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(object.keys).isSubset(of: Set(AppUpdateManifest.CodingKeys.allCases.map(\.rawValue))),
          object["byteCount"] == nil || !(object["byteCount"] is NSNull),
          let manifest = try? JSONDecoder().decode(AppUpdateManifest.self, from: data) else {
      throw AppUpdateError.invalidManifest
    }
    try manifest.validate()
    return manifest
  }

  static func newerManifest(
    _ manifest: AppUpdateManifest,
    currentVersion: String,
    systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
  ) throws -> AppUpdateManifest? {
    try manifest.validate()
    guard try AppUpdateVersion(currentVersion) < AppUpdateVersion(manifest.version) else { return nil }
    try requireCompatibleSystem(manifest, systemVersion: systemVersion)
    return manifest
  }

  static func fetchNewer(
    from endpoint: URL,
    currentVersion: String,
    systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
    configuration: URLSessionConfiguration = .ephemeral
  ) async throws -> AppUpdateManifest? {
    _ = try AppUpdateVersion(currentVersion)
    let url = try validatedHTTPSURL(endpoint.absoluteString)
    let data = try await UpdateTransfer(
      url: url, maximumBytes: maximumManifestBytes, sameOriginRedirects: true
    ).run(configuration: configuration, resourceTimeout: 30)
    try Task.checkCancellation()
    return try newerManifest(parseManifest(data), currentVersion: currentVersion, systemVersion: systemVersion)
  }

  static func downloadVerified(
    _ manifest: AppUpdateManifest,
    to destination: URL? = nil,
    configuration: URLSessionConfiguration = .ephemeral,
    progress: @escaping @Sendable (AppUpdateProgress) -> Void = { _ in }
  ) async throws -> URL {
    try manifest.validate()
    try requireCompatibleSystem(manifest, systemVersion: ProcessInfo.processInfo.operatingSystemVersion)
    try Task.checkCancellation()
    let fileManager = FileManager.default
    let target: URL
    if let destination {
      target = try validatedDestination(destination)
    } else {
      let downloads = try fileManager.url(
        for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true
      )
      target = try validatedDestination(downloads.appendingPathComponent(
        "Linea-Lite-\(manifest.version)-\(UUID().uuidString).dmg"
      ))
    }
    let staging = target.deletingLastPathComponent()
      .appendingPathComponent(".linea-update-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(
      at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
    )
    defer { try? fileManager.removeItem(at: staging) }
    var file = staging.appendingPathComponent("installer.dmg")
    guard fileManager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
      throw AppUpdateError.invalidDestination
    }
    let output = try FileHandle(forWritingTo: file)
    defer { try? output.close() }
    _ = try await UpdateTransfer(
      url: manifest.downloadURL, maximumBytes: manifest.byteCount ?? maximumDownloadBytes,
      expectedBytes: manifest.byteCount, output: output, progress: progress
    ).run(configuration: configuration, resourceTimeout: 15 * 60)
    try output.close()
    try verifyDownloadedFile(at: file, manifest: manifest)
    var values = URLResourceValues()
    values.quarantineProperties = [
      kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
      kLSQuarantineDataURLKey as String: manifest.downloadURL,
    ]
    try file.setResourceValues(values)
    try Task.checkCancellation()
    // Same-volume move publishes only the verified, quarantined file and never replaces a target.
    try fileManager.moveItem(at: file, to: target)
    return target
  }

  static func validatedDestination(_ url: URL) throws -> URL {
    guard url.isFileURL, url.host == nil || url.host == "",
          url.query == nil, url.fragment == nil,
          url.pathExtension.lowercased() == "dmg", !url.hasDirectoryPath,
          !url.path.contains("\\"), !url.path.contains("\0"),
          !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
      throw AppUpdateError.invalidDestination
    }
    let directory = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
    let target = directory.appendingPathComponent(url.lastPathComponent)
    guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
          !FileManager.default.fileExists(atPath: target.path),
          (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) == nil else {
      throw AppUpdateError.invalidDestination
    }
    return target
  }

  static func verifyDownloadedFile(at url: URL, manifest: AppUpdateManifest) throws {
    try manifest.validate()
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
          let size = values.fileSize, (512...Int(maximumDownloadBytes)).contains(size),
          manifest.byteCount == nil || manifest.byteCount == Int64(size) else {
      throw AppUpdateError.verificationFailed
    }
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }
    var hash = SHA256()
    var count: Int64 = 0
    while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
      try Task.checkCancellation()
      count += Int64(data.count)
      guard count <= maximumDownloadBytes else { throw AppUpdateError.tooLarge }
      hash.update(data: data)
    }
    guard count == Int64(size),
          hash.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.sha256 else {
      throw AppUpdateError.verificationFailed
    }
    // Packaged UDIF DMGs end with a 512-byte trailer whose signature is "koly".
    try input.seek(toOffset: UInt64(size - 512))
    guard try input.read(upToCount: 4) == Data("koly".utf8) else {
      throw AppUpdateError.verificationFailed
    }
  }

  private static func requireCompatibleSystem(
    _ manifest: AppUpdateManifest, systemVersion: OperatingSystemVersion
  ) throws {
    let system = "\(systemVersion.majorVersion).\(systemVersion.minorVersion).\(systemVersion.patchVersion)"
    guard try AppUpdateVersion(system) >= AppUpdateVersion(manifest.minimumSystemVersion) else {
      throw AppUpdateError.incompatibleSystem(manifest.minimumSystemVersion)
    }
  }
}

// One transfer per instance. All mutable state is locked; progress runs outside the lock.
private final class UpdateTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let url: URL
  private let maximumBytes: Int64
  private let expectedBytes: Int64?
  private let sameOriginRedirects: Bool
  private let output: FileHandle?
  private let progress: @Sendable (AppUpdateProgress) -> Void
  private let lock = NSLock()
  private var task: URLSessionDataTask?
  private var continuation: CheckedContinuation<Data, Error>?
  private var cancelled = false
  private var failure: Error?
  private var data = Data()
  private var received: Int64 = 0
  private var declaredBytes: Int64?
  private var reported: Int64 = 0
  private var redirects = 0

  init(
    url: URL, maximumBytes: Int64, expectedBytes: Int64? = nil,
    sameOriginRedirects: Bool = false, output: FileHandle? = nil,
    progress: @escaping @Sendable (AppUpdateProgress) -> Void = { _ in }
  ) {
    self.url = url
    self.maximumBytes = maximumBytes
    self.expectedBytes = expectedBytes
    self.sameOriginRedirects = sameOriginRedirects
    self.output = output
    self.progress = progress
  }

  func run(configuration: URLSessionConfiguration, resourceTimeout: TimeInterval) async throws -> Data {
    let config = configuration.copy() as! URLSessionConfiguration
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = resourceTimeout
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCredentialStorage = nil
    config.urlCache = nil
    config.httpAdditionalHeaders = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.withLock {
          guard !cancelled else {
            continuation.resume(throwing: CancellationError())
            return
          }
          self.continuation = continuation
          let task = session.dataTask(with: request(for: url))
          self.task = task
          task.resume()
        }
      }
    } onCancel: {
      self.lock.withLock {
        self.cancelled = true
        self.task?.cancel()
      }
    }
  }

  private func request(for url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    return request
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    let next: URLRequest? = lock.withLock {
      redirects += 1
      guard redirects <= 5, let nextURL = newRequest.url,
            AppUpdate.permitsRedirect(from: url, to: nextURL, sameOrigin: sameOriginRedirects) else {
        failure = AppUpdateError.invalidResponse
        return nil
      }
      return request(for: nextURL)
    }
    completionHandler(next)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    let disposition: URLSession.ResponseDisposition = lock.withLock {
      guard let http = response as? HTTPURLResponse, http.statusCode == 200,
            let finalURL = http.url,
            AppUpdate.permitsRedirect(from: url, to: finalURL, sameOrigin: sameOriginRedirects),
            http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased() ?? "identity" == "identity" else {
        failure = AppUpdateError.invalidResponse
        return .cancel
      }
      declaredBytes = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
      if let declaredBytes, declaredBytes > maximumBytes {
        failure = AppUpdateError.tooLarge
        return .cancel
      }
      if let expectedBytes, let declaredBytes, expectedBytes != declaredBytes {
        failure = AppUpdateError.verificationFailed
        return .cancel
      }
      return .allow
    }
    completionHandler(disposition)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
    let update: AppUpdateProgress? = lock.withLock {
      guard failure == nil, !cancelled else { return nil }
      guard Int64(chunk.count) <= maximumBytes - received else {
        failure = AppUpdateError.tooLarge
        dataTask.cancel()
        return nil
      }
      do {
        if let output { try output.write(contentsOf: chunk) } else { data.append(chunk) }
      } catch {
        failure = error
        dataTask.cancel()
        return nil
      }
      received += Int64(chunk.count)
      let total = expectedBytes ?? declaredBytes
      guard received - reported >= 256 * 1024 || received == total else { return nil }
      reported = received
      return AppUpdateProgress(receivedBytes: received, totalBytes: total)
    }
    if let update { progress(update) }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let result: (CheckedContinuation<Data, Error>?, Result<Data, Error>, AppUpdateProgress) = lock.withLock {
      let continuation = self.continuation
      self.continuation = nil
      self.task = nil
      let error = cancelled ? CancellationError() : (failure ?? error)
      let countsMatch = (expectedBytes == nil || expectedBytes == received)
        && (declaredBytes == nil || declaredBytes == received)
      let result: Result<Data, Error> = error.map { .failure($0) }
        ?? (countsMatch ? .success(data) : .failure(AppUpdateError.verificationFailed))
      return (continuation, result, AppUpdateProgress(receivedBytes: received, totalBytes: expectedBytes ?? declaredBytes))
    }
    if case .success = result.1 { progress(result.2) }
    result.0?.resume(with: result.1)
  }
}
