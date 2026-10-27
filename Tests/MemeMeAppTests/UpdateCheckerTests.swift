import Foundation
@testable import MemeMeApp
import MemeMeCore
import XCTest

/// Serves one canned response to URLSessions built with `makeSession()` and records the requests.
/// The update checker and installer tests share it.
final class UpdateStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var statusCode = 200
    private static var body = Data()
    private static var contentType = "application/json"
    private static var responseURL: URL?
    private static var requests: [URLRequest] = []

    /// Sets the next responses and forgets earlier requests. `responseURL` stands in for where redirects ended
    /// (default: the request's URL).
    static func respond(status: Int, body: Data, contentType: String = "application/json", responseURL: URL? = nil) {
        lock.lock()
        defer { lock.unlock() }
        statusCode = status
        self.body = body
        self.contentType = contentType
        self.responseURL = responseURL
        requests = []
    }

    static func respond(status: Int, text: String) {
        respond(status: status, body: Data(text.utf8))
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func record(_ request: URLRequest) -> (status: Int, body: Data, contentType: String, responseURL: URL?) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return (status: statusCode, body: body, contentType: contentType, responseURL: responseURL)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let reply = UpdateStubURLProtocol.record(request)
        guard let url = reply.responseURL ?? request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: reply.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": reply.contentType]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// latest.json fixtures, shaped like the feed CI publishes.
private enum FeedFixture {
    static let feedURL = URL(string: "https://github.com/Michaell14/MemeMe/releases/latest/download/latest.json")!
    static let dmgURL = "https://github.com/Michaell14/MemeMe/releases/download/v1.0-58/MemeMe.dmg"
    static let sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    static func json(build: Int, downloadURL: String = FeedFixture.dmgURL, minimumSystemVersion: String? = "14.0") -> Data {
        var fields = [
            "\"version\": \"1.0\"",
            "\"build\": \(build)",
            "\"downloadURL\": \"\(downloadURL)\"",
            "\"sha256\": \"\(sha256)\"",
            "\"size\": 4200000",
            "\"notes\": [\"Faster search\", \"Stickers keep their edges\"]",
            "\"releasePageURL\": \"https://github.com/Michaell14/MemeMe/releases/tag/v1.0-\(build)\"",
        ]
        if let minimumSystemVersion {
            fields.append("\"minimumSystemVersion\": \"\(minimumSystemVersion)\"")
        }
        return Data(("{" + fields.joined(separator: ", ") + "}").utf8)
    }
}

/// A checker wired to the stub session, a throwaway UserDefaults suite and an updates folder in a sandbox.
/// `start()` is never called, so nothing is scheduled, observed or cleaned up on this Mac.
private struct CheckerHarness {
    let sandbox: TestSandbox
    let session: URLSession
    let suiteName: String
    let defaults: UserDefaults

    init(_ name: String = #function) throws {
        sandbox = try TestSandbox(name)
        session = UpdateStubURLProtocol.makeSession()
        suiteName = "MemeMeAppTests.UpdateChecker.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    @MainActor
    func makeChecker(feedURL: URL? = FeedFixture.feedURL, installedBuild: Int = 57) -> UpdateChecker {
        let installer = UpdateInstaller(
            session: session,
            updatesDirectory: sandbox.url.appendingPathComponent("Updates", isDirectory: true)
        )
        return UpdateChecker(
            feedURL: feedURL,
            installedVersion: "1.0",
            installedBuild: installedBuild,
            session: session,
            installer: installer,
            defaults: defaults
        )
    }

    func tearDown() {
        session.invalidateAndCancel()
        defaults.removePersistentDomain(forName: suiteName)
        sandbox.remove()
    }
}

final class UpdateCheckerTests: XCTestCase {
    @MainActor
    func testNewerBuildIsAvailable() async throws {
        let harness = try CheckerHarness()
        defer { harness.tearDown() }
        UpdateStubURLProtocol.respond(status: 200, body: FeedFixture.json(build: 58))
        let checker = harness.makeChecker(installedBuild: 57)

        let decision = await checker.check()

        guard case .available(let manifest)? = decision else {
            return XCTFail("Expected .available, got \(String(describing: decision))")
        }
        XCTAssertEqual(manifest.build, 58)
        XCTAssertEqual(manifest.displayVersion, "1.0 (58)")
        XCTAssertEqual(checker.available, manifest)
        XCTAssertEqual(checker.phase, .idle, "The phase goes back to idle after a check")
        let requests = UpdateStubURLProtocol.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url, FeedFixture.feedURL)
    }

    @MainActor
    func testSameBuildIsUpToDate() async throws {
        let harness = try CheckerHarness()
        defer { harness.tearDown() }
        UpdateStubURLProtocol.respond(status: 200, body: FeedFixture.json(build: 58))
        let checker = harness.makeChecker(installedBuild: 58)

        let decision = await checker.check()

        XCTAssertEqual(decision, UpdateDecision.upToDate)
        XCTAssertNil(checker.available)
    }

    @MainActor
    func testAvailableClearsOnceTheFeedMatchesTheInstalledBuild() async throws {
        let harness = try CheckerHarness()
        defer { harness.tearDown() }
        let checker = harness.makeChecker(installedBuild: 57)

        UpdateStubURLProtocol.respond(status: 200, body: FeedFixture.json(build: 58))
        await checker.check()
        XCTAssertEqual(checker.available?.build, 58)

        UpdateStubURLProtocol.respond(status: 200, body: FeedFixture.json(build: 57))
        let decision = await checker.check()

        XCTAssertEqual(decision, UpdateDecision.upToDate)
        XCTAssertNil(checker.available)
    }

    @MainActor
    func testHTTPErrorReturnsNilAndKeepsWhatWasAvailable() async throws {
        let harness = try CheckerHarness()
        defer { harness.tearDown() }
        let checker = harness.makeChecker(installedBuild: 57)
        UpdateStubURLProtocol.respond(status: 200, body: FeedFixture.json(build: 58))
        await checker.check()
        XCTAssertEqual(checker.available?.build, 58)

        UpdateStubURLProtocol.respond(status: 404, text: "Not Found")
        let decision = await checker.check()

        XCTAssertNil(decision)
        XCTAssertEqual(checker.available?.build, 58, "A failed check changes nothing")
        XCTAssertEqual(checker.phase, .idle)
        XCTAssertEqual(UpdateStubURLProtocol.recordedRequests().count, 1)
    }

    @MainActor
    func testMalformedJSONReturnsNil() async throws {
        let harness = try CheckerHarness()
        defer { harness.tearDown() }
        let checker = harness.makeChecker(installedBuild: 57)

        UpdateStubURLProtocol.respond(status: 200, text: #"{"version": "1.0", "build": "#)
        let truncated = await checker.check()
        UpdateStubURLProtocol.respond(status: 200, text: #"{"version": "1.0", "build": "fifty-eight"}"#)
        let wrongTypes = await checker.check()

        XCTAssertNil(truncated)
        XCTAssertNil(wrongTypes)
        XCTAssertNil(checker.available)
    }

    @MainActor
    func testUntrustedDownloadHostReturnsNil() async throws {
        let harness = try CheckerHarness()
        defer { harness.tearDown() }
        let checker = harness.makeChecker(installedBuild: 57)
        UpdateStubURLProtocol.respond(status: 200, body: FeedFixture.json(build: 58, downloadURL: "https://example.com/MemeMe.dmg"))

        let decision = await checker.check()

        XCTAssertNil(decision)
        XCTAssertNil(checker.available)
    }

    @MainActor
    func testNewerBuildForANewerMacOSIsNotOffered() async throws {
        let harness = try CheckerHarness()
        defer { harness.tearDown() }
        let checker = harness.makeChecker(installedBuild: 57)
        UpdateStubURLProtocol.respond(status: 200, body: FeedFixture.json(build: 58, minimumSystemVersion: "99.0"))

        let decision = await checker.check()

        guard case .requiresNewerSystem(let manifest)? = decision else {
            return XCTFail("Expected .requiresNewerSystem, got \(String(describing: decision))")
        }
        XCTAssertEqual(manifest.minimumSystemVersion, "99.0")
        XCTAssertNil(checker.available)
    }

    @MainActor
    func testWithoutAFeedURLNothingIsRequested() async throws {
        let harness = try CheckerHarness()
        defer { harness.tearDown() }
        UpdateStubURLProtocol.respond(status: 200, body: FeedFixture.json(build: 58))
        let checker = harness.makeChecker(feedURL: nil, installedBuild: 57)

        let decision = await checker.check()

        XCTAssertFalse(checker.isEnabled)
        XCTAssertNil(decision)
        XCTAssertNil(checker.available)
        XCTAssertEqual(checker.phase, .idle)
        XCTAssertTrue(UpdateStubURLProtocol.recordedRequests().isEmpty)
    }

    @MainActor
    func testTestRunnerBundleHasNoFeedSoUpdatesAreOff() {
        let checker = UpdateChecker(bundle: .main)

        XCTAssertNil(checker.feedURL)
        XCTAssertFalse(checker.isEnabled)
        XCTAssertFalse(checker.installedVersion.isEmpty)
    }

    @MainActor
    func testInstalledDisplayVersionShowsVersionAndBuild() {
        let checker = UpdateChecker(feedURL: nil, installedVersion: "1.0", installedBuild: 57)

        XCTAssertEqual(checker.installedDisplayVersion, "1.0 (57)")
    }

    @MainActor
    func testBundleInitReadsTheFeedURLAndVersions() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }

        let released = try makeBundle(in: sandbox, name: "Released", info: [
            "MemeMeUpdateFeedURL": "  https://github.com/Michaell14/MemeMe/releases/latest/download/latest.json\n",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "57",
        ])
        let checker = UpdateChecker(bundle: released)
        XCTAssertEqual(checker.feedURL, FeedFixture.feedURL, "The feed URL is trimmed")
        XCTAssertTrue(checker.isEnabled)
        XCTAssertEqual(checker.installedVersion, "1.0")
        XCTAssertEqual(checker.installedBuild, 57)
        XCTAssertEqual(checker.installedDisplayVersion, "1.0 (57)")

        for (index, feed) in ["", "   ", "http://github.com/Michaell14/MemeMe/latest.json", "latest.json"].enumerated() {
            let bundle = try makeBundle(in: sandbox, name: "Feed\(index)", info: [
                "MemeMeUpdateFeedURL": feed,
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "57",
            ])
            XCTAssertNil(UpdateChecker(bundle: bundle).feedURL, "\"\(feed)\" turns updates off")
        }

        let unversioned = try makeBundle(in: sandbox, name: "Unversioned", info: ["CFBundleVersion": "57b"])
        let local = UpdateChecker(bundle: unversioned)
        XCTAssertNil(local.feedURL)
        XCTAssertEqual(local.installedVersion, "0")
        XCTAssertEqual(local.installedBuild, 0)
    }

    /// A bundle folder with only Contents/Info.plist; each name gets its own path, so Bundle's cache can't interfere.
    private func makeBundle(in sandbox: TestSandbox, name: String, info: [String: Any]) throws -> Bundle {
        let bundleURL = try sandbox.directory("\(name).bundle")
        let contents = try sandbox.directory("\(name).bundle/Contents")
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist", isDirectory: false))
        return try XCTUnwrap(Bundle(url: bundleURL))
    }
}
