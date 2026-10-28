import CoreFoundation
import Foundation
@testable import MemeMeApp
import MemeMeCore
import XCTest

/// A tiny GIPHY for a URLSession built with this protocol class: the search answers with one result per id, each
/// with its still on media0…4.giphy.com, and the stills are served after a short delay so the ones a search starts
/// together overlap. Stills can be held back until released, to watch results stream in.
final class WebStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var searchStatus = 200
    private static var searchBody = Data()
    private static var stillBody = Data()
    private static var heldIDs: Set<String> = []
    private static var waiting: [String: WebStubURLProtocol] = [:]
    private static var searches = 0
    private static var stillsInFlight = 0
    private static var maximumStillsInFlight = 0
    /// Stills reply after this, so a search's stills are in flight together.
    private static let stillDelay: TimeInterval = 0.15

    /// Forgets earlier requests and serves `ids` (search status `searchStatus`), holding back the stills of `holding`.
    static func serve(ids: [String], still: Data, searchStatus status: Int = 200, holding: Set<String> = []) {
        lock.lock()
        defer { lock.unlock() }
        searchStatus = status
        searchBody = Data(searchJSON(ids: ids).utf8)
        stillBody = still
        heldIDs = holding
        waiting = [:]
        searches = 0
        stillsInFlight = 0
        maximumStillsInFlight = 0
    }

    /// Lets a held still answer.
    static func release(_ id: String) {
        lock.lock()
        heldIDs.remove(id)
        let held = waiting.removeValue(forKey: id)
        lock.unlock()
        held?.reply(status: 200, body: stillBody, isStill: true, after: 0)
    }

    static var searchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return searches
    }

    static var mostStillsAtOnce: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumStillsInFlight
    }

    static func searchJSON(ids: [String]) -> String {
        let entries = ids.enumerated().map { index, id -> String in
            let media = "https://media\(index % 5).giphy.com/media/\(id)"
            return """
            {"type": "gif", "id": "\(id)", "title": "GIF \(id)", "images": {
              "downsized": {"height": "200", "width": "200", "url": "\(media)/giphy-downsized.gif"},
              "fixed_width_small": {"height": "100", "width": "100", "url": "\(media)/100w.gif"},
              "fixed_width_small_still": {"height": "100", "width": "100", "url": "\(media)/100w_s.gif"}}}
            """
        }
        return #"{"data": ["# + entries.joined(separator: ",") + #"], "meta": {"status": 200}}"#
    }

    private var clientRunLoop: CFRunLoop?
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        clientRunLoop = CFRunLoopGetCurrent()
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if url.host == "api.giphy.com" {
            WebStubURLProtocol.lock.lock()
            WebStubURLProtocol.searches += 1
            let status = WebStubURLProtocol.searchStatus
            let body = WebStubURLProtocol.searchBody
            WebStubURLProtocol.lock.unlock()
            reply(status: status, body: body, isStill: false, after: 0)
            return
        }
        // https://mediaN.giphy.com/media/<id>/100w_s.gif
        let components = url.pathComponents
        let id = components.count > 2 ? components[2] : ""
        WebStubURLProtocol.lock.lock()
        WebStubURLProtocol.stillsInFlight += 1
        WebStubURLProtocol.maximumStillsInFlight = max(WebStubURLProtocol.maximumStillsInFlight, WebStubURLProtocol.stillsInFlight)
        let isHeld = WebStubURLProtocol.heldIDs.contains(id)
        if isHeld {
            WebStubURLProtocol.waiting[id] = self
        }
        let body = WebStubURLProtocol.stillBody
        WebStubURLProtocol.lock.unlock()
        if !isHeld {
            reply(status: 200, body: body, isStill: true, after: WebStubURLProtocol.stillDelay)
        }
    }

    override func stopLoading() {
        stopped = true
    }

    /// Answers later on the thread URLSession started this request on, as URLProtocol expects.
    private func reply(status: Int, body: Data, isStill: Bool, after delay: TimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            guard let runLoop = self.clientRunLoop else { return }
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
                self.deliver(status: status, body: body, isStill: isStill)
            }
            CFRunLoopWakeUp(runLoop)
        }
    }

    private func deliver(status: Int, body: Data, isStill: Bool) {
        if isStill {
            WebStubURLProtocol.lock.lock()
            WebStubURLProtocol.stillsInFlight -= 1
            WebStubURLProtocol.lock.unlock()
        }
        guard !stopped, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// What a test has read from a results stream so far (main actor only).
@MainActor
private final class StreamLog {
    var counts: [Int] = []
    var finished = false
    var latest: Int { counts.last ?? 0 }

    func read(_ stream: AsyncStream<[LibraryItem]>) -> Task<Void, Never> {
        Task { @MainActor in
            for await snapshot in stream {
                self.counts.append(snapshot.count)
            }
            self.finished = true
        }
    }
}

/// WebDiscover against the stub: no real network, the cache in the test's temporary folder. Stills are analyzed with
/// Vision like real ones, so these tests need Vision on the test machine.
final class WebDiscoverTests: XCTestCase {
    private static let budget: TimeInterval = 20

    @MainActor
    private func makeWeb(in sandbox: TestSandbox, enabled: Bool = true, key: String? = "test-key") throws -> (WebDiscover, LibraryStore) {
        let store = try LibraryStore(rootURL: sandbox.url.appendingPathComponent("Library", isDirectory: true))
        var settings = store.settings
        settings.webDiscoverEnabled = enabled
        settings.giphyAPIKey = key
        store.settings = settings
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebStubURLProtocol.self]
        let web = WebDiscover(store: store, cacheRoot: sandbox.url.appendingPathComponent("Web", isDirectory: true), configuration: configuration)
        return (web, store)
    }

    private func stillData(in sandbox: TestSandbox) throws -> Data {
        let url = sandbox.file("still.gif")
        try TestImages.writeGIF([TestImages.shapes(width: 100, height: 100)], to: url)
        return try Data(contentsOf: url)
    }

    private func ids(_ count: Int) -> [String] {
        (0..<count).map { "gif\($0)" }
    }

    /// Lets a search's last writes land before the sandbox goes.
    @MainActor
    private func settle(_ web: WebDiscover) async {
        _ = await waitUntil(timeout: WebDiscoverTests.budget) { !web.isFetching }
    }

    @MainActor
    func testStillsDownloadTogetherAndResultsArriveBeforeTheSlowestOne() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let (web, _) = try makeWeb(in: sandbox)
        let still = try stillData(in: sandbox)
        WebStubURLProtocol.serve(ids: ids(6), still: still, holding: Set(ids(6)))

        let log = StreamLog()
        let reading = log.read(web.results(for: .shocked))
        // Every still is held, so six are in flight only if all six were requested together, however slow the machine.
        let allStarted = await waitUntil(timeout: WebDiscoverTests.budget) { WebStubURLProtocol.mostStillsAtOnce == 6 }
        XCTAssertTrue(allStarted, "every still should download at once; at most \(WebStubURLProtocol.mostStillsAtOnce) did")
        for id in ids(5) {
            WebStubURLProtocol.release(id)
        }
        let fiveIn = await waitUntil(timeout: WebDiscoverTests.budget) { log.latest == 5 }
        XCTAssertTrue(fiveIn, "results should stream in while one still is held back; got \(log.counts)")
        XCTAssertFalse(log.finished)
        XCTAssertEqual(web.partialItems(for: .shocked).count, 5)
        XCTAssertEqual(web.partialItems(for: .shocked).map(\.contentHash), ["giphy:gif0", "giphy:gif1", "giphy:gif2", "giphy:gif3", "giphy:gif4"])
        XCTAssertTrue(web.cachedItems(for: .shocked).isEmpty, "a search is cached only once it is complete")

        WebStubURLProtocol.release("gif5")
        await reading.value
        XCTAssertEqual(log.latest, 6)
        XCTAssertEqual(web.cachedItems(for: .shocked).count, 6)
        XCTAssertTrue(web.partialItems(for: .shocked).isEmpty)
        XCTAssertEqual(WebStubURLProtocol.searchCount, 1)

        // Cached now: answered at once, without searching again.
        let again = StreamLog()
        await again.read(web.results(for: .shocked)).value
        XCTAssertEqual(again.counts, [6])
        XCTAssertEqual(WebStubURLProtocol.searchCount, 1)
        await settle(web)
    }

    @MainActor
    func testASecondListenerJoinsTheRunningSearch() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let (web, _) = try makeWeb(in: sandbox)
        let still = try stillData(in: sandbox)
        WebStubURLProtocol.serve(ids: ids(3), still: still, holding: ["gif2"])

        let first = StreamLog()
        let firstReading = first.read(web.results(for: .happy))
        _ = await waitUntil(timeout: WebDiscoverTests.budget) { first.latest == 2 }

        let second = StreamLog()
        let secondReading = second.read(web.results(for: .happy))
        let caughtUp = await waitUntil(timeout: WebDiscoverTests.budget) { second.latest == 2 }
        XCTAssertTrue(caughtUp, "a new listener gets what is already in; got \(second.counts)")
        XCTAssertEqual(WebStubURLProtocol.searchCount, 1)

        WebStubURLProtocol.release("gif2")
        await firstReading.value
        await secondReading.value
        XCTAssertEqual(first.latest, 3)
        XCTAssertEqual(second.latest, 3)
        await settle(web)
    }

    @MainActor
    func testWarmStartsOneSearchThatResultsJoin() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let (web, _) = try makeWeb(in: sandbox)
        let still = try stillData(in: sandbox)
        WebStubURLProtocol.serve(ids: ids(2), still: still)

        web.warm(.laughing)
        web.warm(.laughing)
        let log = StreamLog()
        await log.read(web.results(for: .laughing)).value
        XCTAssertEqual(log.latest, 2)
        XCTAssertEqual(WebStubURLProtocol.searchCount, 1)

        web.warm(.laughing)
        XCTAssertFalse(web.isFetching, "a cached mood is not searched again")
        XCTAssertEqual(WebStubURLProtocol.searchCount, 1)
        await settle(web)
    }

    @MainActor
    func testNothingIsSearchedWhenOffOrWithoutAKey() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let still = try stillData(in: sandbox)
        WebStubURLProtocol.serve(ids: ids(2), still: still)

        let (off, _) = try makeWeb(in: sandbox, enabled: false)
        XCTAssertEqual(off.status, .off)
        off.warm(.sad)
        let offLog = StreamLog()
        await offLog.read(off.results(for: .sad)).value
        XCTAssertEqual(offLog.counts, [])

        let (keyless, _) = try makeWeb(in: sandbox, key: nil)
        XCTAssertEqual(keyless.status, .noKey)
        let keylessLog = StreamLog()
        await keylessLog.read(keyless.results(for: .sad)).value
        XCTAssertEqual(keylessLog.counts, [])
        XCTAssertEqual(WebStubURLProtocol.searchCount, 0)
    }

    @MainActor
    func testTooManyRequestsPausesSearching() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let (web, _) = try makeWeb(in: sandbox)
        WebStubURLProtocol.serve(ids: [], still: Data(), searchStatus: 429)

        let log = StreamLog()
        await log.read(web.results(for: .angry)).value
        await settle(web)
        XCTAssertEqual(log.counts, [])
        XCTAssertEqual(web.status, .limitReached)
        XCTAssertEqual(WebStubURLProtocol.searchCount, 1, "GIPHY refusing a search is not retried")

        let other = StreamLog()
        await other.read(web.results(for: .confused)).value
        XCTAssertEqual(other.counts, [])
        XCTAssertEqual(WebStubURLProtocol.searchCount, 1, "no searches while paused")
    }

    @MainActor
    func testARejectedKeyWaitsButANewKeySearchesAtOnce() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let (web, store) = try makeWeb(in: sandbox)
        WebStubURLProtocol.serve(ids: [], still: Data(), searchStatus: 403)

        await StreamLog().read(web.results(for: .smug)).value
        await settle(web)
        XCTAssertEqual(web.status, .keyRejected)
        await StreamLog().read(web.results(for: .nervous)).value
        XCTAssertEqual(WebStubURLProtocol.searchCount, 1, "the refused key waits")

        var settings = store.settings
        settings.giphyAPIKey = "new-key"
        store.settings = settings
        XCTAssertEqual(web.status, .ready)
        let still = try stillData(in: sandbox)
        WebStubURLProtocol.serve(ids: ids(1), still: still)
        let log = StreamLog()
        await log.read(web.results(for: .nervous)).value
        XCTAssertEqual(log.latest, 1)
        XCTAssertEqual(WebStubURLProtocol.searchCount, 1)
        await settle(web)
    }

    @MainActor
    func testAServerErrorIsRetriedOnce() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let (web, _) = try makeWeb(in: sandbox)
        WebStubURLProtocol.serve(ids: [], still: Data(), searchStatus: 503)

        await StreamLog().read(web.results(for: .crying)).value
        await settle(web)
        XCTAssertEqual(WebStubURLProtocol.searchCount, 2)
        XCTAssertEqual(web.status, .ready, "a server error doesn't pause other moods")
    }
}
