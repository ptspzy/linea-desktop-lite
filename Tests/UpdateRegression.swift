import Foundation
import CryptoKit

private struct UpdateRegressionFailure: Error, CustomStringConvertible {
  let description: String
}

private func updateExpect(_ condition: Bool, _ message: String) throws {
  if !condition { throw UpdateRegressionFailure(description: message) }
}

private func updateRejects(_ body: () throws -> Void) throws {
  do { try body() } catch { return }
  throw UpdateRegressionFailure(description: "Expected update validation to reject input")
}

private func updateRejectsAsync(
  _ expected: AppUpdateError? = nil, _ body: () async throws -> Void
) async throws {
  do { try await body() } catch {
    if let expected { try updateExpect(error as? AppUpdateError == expected, "Unexpected failure: \(error)") }
    return
  }
  throw UpdateRegressionFailure(description: "Expected update operation to fail")
}

private let updateDMGFixture = Data(repeating: 42, count: 1024)
  + Data("koly".utf8) + Data(repeating: 0, count: 508)

private func updateFixtureManifest(path: String = "/installer.dmg", byteCount: Int64? = nil) -> AppUpdateManifest {
  AppUpdateManifest(
    schemaVersion: 1, version: "1.10.0", minimumSystemVersion: "13.0",
    downloadURL: URL(string: "https://cdn.example.com\(path)")!,
    sha256: SHA256.hash(data: updateDMGFixture).map { String(format: "%02x", $0) }.joined(),
    byteCount: byteCount ?? Int64(updateDMGFixture.count)
  )
}

// Every request is intercepted, including unexpected URLs; these tests cannot fall through to DNS/network.
private final class UpdateFixtureProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    let data: Data
    let headers: [String: String]
    let status: Int
    switch url.path {
    case "/manifest.json":
      data = try! JSONEncoder().encode(updateFixtureManifest())
      headers = ["Content-Length": String(data.count)]
      status = 200
    case "/oversized.json":
      data = Data(repeating: 32, count: Int(AppUpdate.maximumManifestBytes) + 1)
      headers = [:]
      status = 200
    case "/installer.dmg", "/cancel.dmg", "/chunked.dmg":
      data = updateDMGFixture
      headers = url.path == "/chunked.dmg" ? [:] : ["Content-Length": String(data.count)]
      status = 200
    case "/tampered.dmg":
      var changed = updateDMGFixture
      changed[0] ^= 1
      data = changed
      headers = ["Content-Length": String(data.count)]
      status = 200
    case "/truncated.dmg":
      data = updateDMGFixture.dropLast()
      headers = [:]
      status = 200
    case "/oversized.dmg":
      data = updateDMGFixture + Data([0])
      headers = [:]
      status = 200
    case "/huge.dmg":
      data = Data()
      headers = ["Content-Length": String(AppUpdate.maximumDownloadBytes + 1)]
      status = 200
    case "/encoded.dmg":
      data = updateDMGFixture
      headers = ["Content-Encoding": "gzip"]
      status = 200
    default:
      data = Data()
      headers = [:]
      status = 404
    }
    client?.urlProtocol(self, didReceive: HTTPURLResponse(
      url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
    )!, cacheStoragePolicy: .notAllowed)
    for start in stride(from: 0, to: data.count, by: 1024) {
      client?.urlProtocol(self, didLoad: data.subdata(in: start..<min(start + 1024, data.count)))
    }
    if url.path != "/cancel.dmg" { client?.urlProtocolDidFinishLoading(self) }
  }

  override func stopLoading() {}
}

private final class UpdateProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [AppUpdateProgress] = []

  func append(_ value: AppUpdateProgress) { lock.withLock { values.append(value) } }
  var snapshot: [AppUpdateProgress] { lock.withLock { values } }
}

func runUpdateRegressionTests() async throws {
  try updateExpect(try AppUpdateVersion("1.2") < AppUpdateVersion("1.10"), "Numeric version ordering")
  try updateExpect(try AppUpdateVersion("1") == AppUpdateVersion("1.0.0"), "Padded version equality")
  try updateExpect(try AppUpdateVersion("2.0") > AppUpdateVersion("1.99.99"), "Major version ordering")
  for value in ["", "v1", "1.", ".1", "1..2", "01.2", "1.-2", "1.2b", "1.2.3.4", "1.0+build", "1.0-beta", "1000000000", " 1"] {
    try updateRejects { _ = try AppUpdateVersion(value) }
  }
  let validURL = "https://updates.example.com/releases/Linea%20Lite.dmg?release=1"
  _ = try AppUpdate.validatedHTTPSURL(validURL)
  for value in ["https://updates.company.internal:8443/manifest.json", "https://releases:9443/app.dmg"] {
    _ = try AppUpdate.validatedHTTPSURL(value)
  }
  for value in [
    "http://updates.example.com/file.dmg", "file:///tmp/file.dmg", "https://localhost/file.dmg",
    "https://127.0.0.1/file.dmg", "https://[::1]/file.dmg", "https://2130706433/file.dmg",
    "https://app.local/file.dmg", "https://app.localhost/file.dmg",
    "https://user:password@updates.example.com/file.dmg", "https://updates.example.com/file.dmg#fragment",
    "https://updates.example.com:0/file.dmg", "https://updates.example.com:65536/file.dmg",
    "https://updates.example.com/../file.dmg",
    "https://updates.example.com/%2e%2e/file.dmg", "https://updates.example.com/%252e%252e/file.dmg",
    "https://updates.example.com/a%5cb.dmg", "https://updates.example.com/a%00b.dmg",
    "https://updates.example.com/a%0ab.dmg", "https://updates.example.com/a%7fb.dmg",
    "https://updates.example.com/file dmg", "https://updates.example.com./file.dmg",
  ] { try updateRejects { _ = try AppUpdate.validatedHTTPSURL(value) } }
  let enterpriseURL = URL(string: "https://releases.company.internal:8443/feed.json")!
  for (value, sameOrigin, permitted) in [
    ("https://releases.company.internal:8443/new.json", true, true),
    ("https://releases.company.internal/new.json", true, false),
    ("https://cdn.example.com/file.dmg", true, false),
    ("https://cdn.example.com/file.dmg", false, true),
    ("http://cdn.example.com/file.dmg", false, false),
    ("https://user@cdn.example.com/file.dmg", false, false),
    ("https://localhost/file.dmg", false, false),
  ] {
    try updateExpect(AppUpdate.permitsRedirect(from: enterpriseURL, to: URL(string: value)!, sameOrigin: sameOrigin) == permitted,
                     "HTTPS redirect policy")
  }

  let manifest = updateFixtureManifest()
  let encoded = try JSONEncoder().encode(manifest)
  try updateExpect(try AppUpdate.parseManifest(encoded) == manifest, "Manifest round trip")
  let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
  for missing in ["schemaVersion", "version", "minimumSystemVersion", "downloadURL", "sha256"] {
    var changed = object
    changed.removeValue(forKey: missing)
    try updateRejects { _ = try AppUpdate.parseManifest(JSONSerialization.data(withJSONObject: changed)) }
  }
  let invalidFields: [(String, Any)] = [
    ("schemaVersion", 2), ("schemaVersion", true), ("unknown", "field"),
    ("version", "1.0-beta"), ("version", 2), ("minimumSystemVersion", "13.x"),
    ("downloadURL", "https://cdn.example.com/installer.pkg"), ("downloadURL", "http://cdn.example.com/file.dmg"),
    ("downloadURL", "https://cdn.example.com/installer.dmg/"),
    ("sha256", ""), ("sha256", String(repeating: "a", count: 63)),
    ("sha256", String(repeating: "g", count: 64)), ("sha256", String(repeating: "A", count: 64)),
    ("byteCount", -1), ("byteCount", 0), ("byteCount", 1.5), ("byteCount", true),
    ("byteCount", NSNull()), ("byteCount", AppUpdate.maximumDownloadBytes + 1),
  ]
  for (key, value) in invalidFields {
    var changed = object
    changed[key] = value
    try updateRejects { _ = try AppUpdate.parseManifest(JSONSerialization.data(withJSONObject: changed)) }
  }
  var optionalSize = object
  optionalSize.removeValue(forKey: "byteCount")
  let noSize = try AppUpdate.parseManifest(JSONSerialization.data(withJSONObject: optionalSize))
  try updateExpect(noSize.byteCount == nil, "byteCount is optional")
  for data in [Data(), Data("[]".utf8), Data("{bad json}".utf8), Data(repeating: 32, count: 65_537)] {
    try updateRejects { _ = try AppUpdate.parseManifest(data) }
  }
  let macOS13 = OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)
  try updateExpect(try AppUpdate.newerManifest(manifest, currentVersion: "1.9", systemVersion: macOS13) == manifest, "New release")
  for current in ["1.10", "2"] {
    try updateExpect(try AppUpdate.newerManifest(manifest, currentVersion: current, systemVersion: macOS13) == nil, "No downgrade")
  }
  try updateRejects {
    _ = try AppUpdate.newerManifest(manifest, currentVersion: "1", systemVersion: OperatingSystemVersion(
      majorVersion: 12, minorVersion: 6, patchVersion: 0
    ))
  }

  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("linea-update-regression-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let source = directory.appendingPathComponent("source.dmg")
  try updateDMGFixture.write(to: source)
  try AppUpdate.verifyDownloadedFile(at: source, manifest: manifest)
  try AppUpdate.verifyDownloadedFile(at: source, manifest: noSize)
  let notDMG = directory.appendingPathComponent("not-a-dmg.dmg")
  let notDMGData = Data(repeating: 0, count: updateDMGFixture.count)
  try notDMGData.write(to: notDMG)
  let notDMGManifest = AppUpdateManifest(
    schemaVersion: 1, version: manifest.version, minimumSystemVersion: "13.0", downloadURL: manifest.downloadURL,
    sha256: SHA256.hash(data: notDMGData).map { String(format: "%02x", $0) }.joined(), byteCount: Int64(notDMGData.count)
  )
  try updateRejects { try AppUpdate.verifyDownloadedFile(at: notDMG, manifest: notDMGManifest) }
  try updateRejects { _ = try AppUpdate.validatedDestination(source) }
  for url in [
    directory.appendingPathComponent("bad.pkg"),
    URL(string: directory.absoluteString + "../escape.dmg")!,
    URL(string: directory.absoluteString + "%2e%2e/escape.dmg")!,
    URL(string: "https://updates.example.com/file.dmg")!,
    directory.appendingPathComponent("missing/file.dmg"),
  ] { try updateRejects { _ = try AppUpdate.validatedDestination(url) } }
  let symlink = directory.appendingPathComponent("link.dmg")
  try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
  try updateRejects { _ = try AppUpdate.validatedDestination(symlink) }
  try updateRejects { try AppUpdate.verifyDownloadedFile(at: symlink, manifest: manifest) }
  let dangling = directory.appendingPathComponent("dangling.dmg")
  try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: directory.appendingPathComponent("absent"))
  try updateRejects { _ = try AppUpdate.validatedDestination(dangling) }

  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [UpdateFixtureProtocol.self]
  let endpoint = URL(string: "https://updates.example.com/manifest.json")!
  let available = try await AppUpdate.fetchNewer(from: endpoint, currentVersion: "1.9", configuration: configuration)
  try updateExpect(available == manifest, "Offline feed check")
  let enterpriseAvailable = try await AppUpdate.fetchNewer(
    from: URL(string: "https://releases.company.internal:8443/manifest.json")!,
    currentVersion: "1.9", configuration: configuration
  )
  try updateExpect(enterpriseAvailable == manifest, "Company-internal HTTPS feed")
  let unchanged = try await AppUpdate.fetchNewer(from: endpoint, currentVersion: "1.10", configuration: configuration)
  try updateExpect(unchanged == nil, "Offline current release check")
  for path in ["oversized.json", "not-found.json"] {
    try await updateRejectsAsync {
      _ = try await AppUpdate.fetchNewer(from: endpoint.deletingLastPathComponent().appendingPathComponent(path),
                                       currentVersion: "1", configuration: configuration)
    }
  }
  let target = directory.appendingPathComponent("verified.dmg")
  let recorder = UpdateProgressRecorder()
  let result = try await AppUpdate.downloadVerified(manifest, to: target, configuration: configuration) {
    recorder.append($0)
  }
  try updateExpect(try Data(contentsOf: result) == updateDMGFixture, "Verified download bytes")
  try updateExpect(try result.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil, "Download quarantine retained")
  try updateExpect(recorder.snapshot.last?.receivedBytes == Int64(updateDMGFixture.count), "Download progress")
  try updateExpect(recorder.snapshot.last?.fractionCompleted == 1, "Progress fraction")
  try await updateRejectsAsync {
    _ = try await AppUpdate.downloadVerified(manifest, to: target, configuration: configuration)
  }
  try updateExpect(try Data(contentsOf: target) == updateDMGFixture, "Existing target preserved")
  let chunked = try await AppUpdate.downloadVerified(updateFixtureManifest(path: "/chunked.dmg"),
                                                    to: directory.appendingPathComponent("chunked.dmg"), configuration: configuration)
  try updateExpect(try Data(contentsOf: chunked) == updateDMGFixture, "Unknown content length")
  let unknownSize = AppUpdateManifest(
    schemaVersion: 1, version: manifest.version, minimumSystemVersion: "13.0",
    downloadURL: updateFixtureManifest(path: "/chunked.dmg").downloadURL, sha256: manifest.sha256, byteCount: nil
  )
  let unknownProgress = UpdateProgressRecorder()
  _ = try await AppUpdate.downloadVerified(unknownSize, to: directory.appendingPathComponent("unknown-size.dmg"), configuration: configuration) {
    unknownProgress.append($0)
  }
  try updateExpect(unknownProgress.snapshot.last?.totalBytes == nil, "Unknown size progress remains indeterminate")
  for (path, expected) in [
    ("tampered", AppUpdateError.verificationFailed), ("truncated", .verificationFailed),
    ("oversized", .tooLarge), ("huge", .tooLarge), ("encoded", .invalidResponse), ("missing", .invalidResponse),
  ] {
    let rejected = directory.appendingPathComponent("\(path).dmg")
    try await updateRejectsAsync(expected) {
      _ = try await AppUpdate.downloadVerified(updateFixtureManifest(path: "/\(path).dmg"),
                                               to: rejected, configuration: configuration)
    }
    try updateExpect(!FileManager.default.fileExists(atPath: rejected.path), "Failed download must not be published")
  }
  let cancelledTarget = directory.appendingPathComponent("cancelled.dmg")
  let download = Task {
    try await AppUpdate.downloadVerified(updateFixtureManifest(path: "/cancel.dmg"),
                                         to: cancelledTarget, configuration: configuration)
  }
  try await Task.sleep(nanoseconds: 50_000_000)
  download.cancel()
  do {
    _ = try await download.value
    throw UpdateRegressionFailure(description: "Cancelled download succeeded")
  } catch is CancellationError {}
  try updateExpect(!FileManager.default.fileExists(atPath: cancelledTarget.path), "Cancelled download not published")
  let cancelledCheck = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    return try await AppUpdate.fetchNewer(from: endpoint, currentVersion: "1", configuration: configuration)
  }
  do {
    _ = try await cancelledCheck.value
    throw UpdateRegressionFailure(description: "Pre-cancelled manifest check succeeded")
  } catch is CancellationError {}
  let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
  try updateExpect(!files.contains(where: { $0.hasPrefix(".linea-update-") }), "Staging cleaned after success, failure and cancellation")

  let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("scripts/create-update-manifest.sh")
  func generate(_ arguments: [String]) throws -> (status: Int32, data: Data) {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [script.path] + arguments
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, data)
  }
  let generated = try generate([source.path, manifest.version, manifest.downloadURL.absoluteString])
  try updateExpect(generated.status == 0, "Manifest generator succeeded")
  try updateExpect(try AppUpdate.parseManifest(generated.data) == manifest, "Generator and client schema agree")
  let enterpriseDownload = "https://releases.company.internal:8443/installer.dmg"
  let enterpriseGenerated = try generate([source.path, manifest.version, enterpriseDownload, "13.0"])
  try updateExpect(enterpriseGenerated.status == 0, "Enterprise manifest generator succeeded")
  try updateExpect(try AppUpdate.parseManifest(enterpriseGenerated.data).downloadURL.absoluteString == enterpriseDownload,
                   "Enterprise manifest schema agrees")
  for arguments in [
    [], [source.path, "1.0-beta", manifest.downloadURL.absoluteString],
    [source.path, "1", "http://cdn.example.com/file.dmg"],
    [source.path, "1", "https://user@cdn.example.com/file.dmg"],
    [source.path, "1", "https://cdn.example.com/%2e%2e/file.dmg"],
    [source.path, "1", "https://cdn.example.com/file.dmg/"],
    [notDMG.path, "1", manifest.downloadURL.absoluteString],
  ] {
    let rejected = try generate(arguments)
    try updateExpect(rejected.status != 0 && rejected.data.isEmpty, "Invalid generator input fails without output")
  }
  print("Update regression tests ok (offline)")
}

#if UPDATE_REGRESSION_MAIN
@main
private enum UpdateRegressionMain {
  static func main() async throws { try await runUpdateRegressionTests() }
}
#endif
