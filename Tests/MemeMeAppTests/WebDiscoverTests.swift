import AppKit
import CoreFoundation
import Foundation
@testable import MemeMeApp
import MemeMeCore
import XCTest

/// A tiny GIPHY for a URLSession built with this protocol class: the search answers with one result per id (stills
/// and full GIFs on media0…4.giphy.com), and every media URL serves the same GIF bytes.
final class WebStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var searchStatus = 200
    private static var searchBody = Data()
    private static var mediaBody = Data()
    private static var searches = 0
    private static var mediaRequests = 0
    private static var lastSearch: URL?

    /// Forgets earlier requests and serves `ids` (the search answering `searchStatus`) with `media` for every image.
    static func serve(ids: [String], media: Data, searchStatus status: Int = 200) {
        lock.lock()
        defer { lock.unlock() }
        searchStatus = status
        searchBody = Data(searchJSON(ids: ids).utf8)
        mediaBody = media
        searches = 0
        mediaRequests = 0
        lastSearch = nil
    }

    static var searchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return searches
    }

    static var mediaRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return mediaRequests
    }

    /// The last search's URL (its query holds what was asked of GIPHY).
    static var lastSearchURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return lastSearch
    }

    static func searchJSON(ids: [String]) -> String {
        let entries = ids.enumerated().map { index, id -> String in
            let media = "https://media\(index % 5).giphy.com/media/\(id)"
            return """
            {"type": "gif", "id": "\(id)", "title": "GIF \(id)", "images": {
              "downsized": {"height": "200", "width": "200", "url": "\(media)/giphy-downsized.gif"},
              "fixed_width_small": {"height": "100", "width": "100", "url": "\(media)/100w.gif"},
              "fixed_width_small_still": {"height": "100", "width": "100", "url": "\(media)/100w_s.gif"}},
             "user": {"username": "maker\(index)", "display_name": ""}}
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
        WebStubURLProtocol.lock.lock()
        let status: Int
        let body: Data
        if url.host == "api.giphy.com" {
            WebStubURLProtocol.searches += 1
            WebStubURLProtocol.lastSearch = url
            status = WebStubURLProtocol.searchStatus
            body = WebStubURLProtocol.searchBody
        } else {
            WebStubURLProtocol.mediaRequests += 1
            status = 200
            body = WebStubURLProtocol.mediaBody
        }
        WebStubURLProtocol.lock.unlock()
        reply(status: status, body: body)
    }

    override func stopLoading() {
        stopped = true
    }

    /// Answers on the thread URLSession started this request on, as URLProtocol expects.
    private func reply(status: Int, body: Data) {
        DispatchQueue.global().async {
            guard let runLoop = self.clientRunLoop else { return }
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
                self.deliver(status: status, body: body)
            }
            CFRunLoopWakeUp(runLoop)
        }
    }

    private func deliver(status: Int, body: Data) {
        guard !stopped, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Cache-Control": "max-age=3600"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// WebDiscover against the stub: no real network, its files in the test's temporary folder.
final class WebDiscoverTests: XCTestCase {
    private static let budget: TimeInterval = 10

    @MainActor
    private func makeWeb(in sandbox: TestSandbox, enabled: Bool = true, key: String? = "test-key") throws -> (WebDiscover, LibraryStore) {
        let store = try LibraryStore(rootURL: sandbox.url.appendingPathComponent("Library", isDirectory: true))
        var settings = store.settings
        settings.webDiscoverEnabled = enabled
        settings.giphyAPIKey = key
        store.settings = settings
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebStubURLProtocol.self]
        let web = WebDiscover(store: store, cacheRoot: webRoot(in: sandbox), configuration: configuration)
        return (web, store)
    }

    private func webRoot(in sandbox: TestSandbox) -> URL {
        sandbox.url.appendingPathComponent("Web", isDirectory: true)
    }

    private func gifData(in sandbox: TestSandbox) throws -> Data {
        let url = sandbox.file("still.gif")
        try TestImages.writeGIF([TestImages.shapes(width: 100, height: 100)], to: url)
        return try Data(contentsOf: url)
    }

    private func ids(_ count: Int) -> [String] {
        (0..<count).map { "gif\($0)" }
    }

    @MainActor
    func testResultsKeepGIPHYsOrderAndAreReusedFromMemory() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let (web, _) = try makeWeb(in: sandbox)
        WebStubURLProtocol.serve(ids: ids(7), media: try gifData(in: sandbox))

        let gifs = await web.gifs(for: .shocked)
        XCTAssertEqual(gifs?.map(\.id), ids(7), "GIPHY's results, in GIPHY's order")
        XCTAssertEqual(gifs?.first?.creator, "maker0", "an empty display name falls back to the username")
        XCTAssertEqual(web.cachedGIFs(for: .shocked)?.map(\.id), ids(7))
        XCTAssertNil(web.cachedGIFs(for: .happy))
        XCTAssertEqual(WebStubURLProtocol.searchCount, 1)

        let again = await web.gifs(for: .shocked)
        XCTAssertEqual(again?.map(\.id), ids(7))
        XCTAssertEqual(WebStubURLProtocol.searchCount, 1, "results from the last 10 minutes are reused")
        XCTAssertEqual(WebDiscover.resultLifetime, 600)
    }

    @MainActor
    func testASearchAsksForFourRowsAndTheRowPagesThroughThem() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let (web, _) = try makeWeb(in: sandbox)
        WebStubURLProtocol.serve(ids: ids(30), media: try gifData(in: sandbox))

        let found = await web.gifs(for: .tongueOut)
        let gifs = try XCTUnwrap(found)
        XCTAssertEqual(gifs.map(\.id), ids(24), "24 asked for, and no more kept")
        let url = try XCTUnwrap(WebStubURLProtocol.lastSearchURL)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "limit" }?.value, "24")
        XCTAssertEqual(query.first { $0.name == "q" }?.value, "tongue out")
        XCTAssertEqual(WebStubURLProtocol.searchCount, 1)

        // Six at a time, wrapping around to the first six after the fourth page.
        XCTAssertEqual(WebDiscover.page(0, of: gifs, size: 6).map(\.id), Array(ids(24)[0..<6]))
        XCTAssertEqual(WebDiscover.page(1, of: gifs, size: 6).map(\.id), Array(ids(24)[6..<12]))
        XCTAssertEqual(WebDiscover.page(3, of: gifs, size: 6).map(\.id), Array(ids(24)[18..<24]))
        XCTAssertEqual(WebDiscover.page(4, of: gifs, size: 6).map(\.id), Array(ids(24)[0..<6]))
        XCTAssertEqual(WebDiscover.page(-1, of: gifs, size: 6).map(\.id), Array(ids(24)[0..<6]))
        // Ten results: the second page runs on into the first.
        let ten = Array(gifs.prefix(10))
        XCTAssertEqual(WebDiscover.page(1, of: ten, size: 6).map(\.id), ["gif6", "gif7", "gif8", "gif9", "gif0", "gif1"])
        XCTAssertEqual(WebDiscover.page(2, of: ten, size: 6).map(\.id), ["gif2", "gif3", "gif4", "gif5", "gif6", "gif7"])
        // Six or fewer: every page is all of them.
        let four = Array(gifs.prefix(4))
        XCTAssertEqual(WebDiscover.page(1, of: four, size: 6).map(\.id), ids(4))
        XCTAssertEqual(WebDiscover.page(5, of: [], size: 6), [])
        XCTAssertEqual(WebStubURLProtocol.searchCount, 1, "turning pages searches nothing")
    }

    @MainActor
    func testNoResultsOrImagesAreWrittenToDisk() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let (web, _) = try makeWeb(in: sandbox)
        WebStubURLProtocol.serve(ids: ids(3), media: try gifData(in: sandbox))

        let found = await web.gifs(for: .laughing)
        let gifs = try XCTUnwrap(found)
        for gif in gifs {
            let still = await web.still(for: gif)
            XCTAssertNotNil(still)
            XCTAssertNotNil(web.cachedStill(for: gif))
            let preview = await web.preview(for: gif)
            XCTAssertNotNil(preview)
        }
        // Only the search times and the (empty) folder for copies; HTTP/ is URLSession's own cache.
        let rateFile = webRoot(in: sandbox).appendingPathComponent("rate.json")
        _ = await waitUntil(timeout: WebDiscoverTests.budget) { FileManager.default.fileExists(atPath: rateFile.path) }
        let names = visibleFileNames(in: webRoot(in: sandbox)).filter { $0 != "HTTP" }
        XCTAssertEqual(names, ["files", "rate.json"])
        XCTAssertEqual(visibleFileNames(in: webRoot(in: sandbox).appendingPathComponent("files")), [])
    }

    @MainActor
    func testCopyingDownloadsTheFullGIFToAShortLivedFile() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let (web, _) = try makeWeb(in: sandbox)
        let media = try gifData(in: sandbox)
        WebStubURLProtocol.serve(ids: ids(1), media: media)

        let found = await web.gifs(for: .smug)
        let gif = try XCTUnwrap(found?.first)
        let prepared = await web.prepareForCopy(gif)
        let file = try XCTUnwrap(prepared)
        XCTAssertEqual(try Data(contentsOf: file), media)
        XCTAssertEqual(file.deletingLastPathComponent().lastPathComponent, "files")
        let again = await web.prepareForCopy(gif)
        XCTAssertEqual(again, file)
    }

    @MainActor
    func testWarmStartsOneSearchThatOthersJoin() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let (web, _) = try makeWeb(in: sandbox)
        WebStubURLProtocol.serve(ids: ids(2), media: try gifData(in: sandbox))

        web.warm(.crying)
        web.warm(.crying)
        XCTAssertTrue(web.isSearching(.crying))
        let gifs = await web.gifs(for: .crying)
        XCTAssertEqual(gifs?.count, 2)
        XCTAssertFalse(web.isSearching(.crying))
        XCTAssertEqual(WebStubURLProtocol.searchCount, 1)

        web.warm(.crying)
        XCTAssertFalse(web.isSearching(.crying), "fresh results are not searched again")
        XCTAssertEqual(WebStubURLProtocol.searchCount, 1)
    }

    @MainActor
    func testNothingIsSearchedWhenOffOrWithoutAKey() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        WebStubURLProtocol.serve(ids: ids(2), media: try gifData(in: sandbox))

        let (off, _) = try makeWeb(in: sandbox, enabled: false)
        XCTAssertEqual(off.status, .off)
        off.warm(.sad)
        let offResult = await off.gifs(for: .sad)
        XCTAssertNil(offResult)

        let (keyless, _) = try makeWeb(in: sandbox, key: nil)
        XCTAssertEqual(keyless.status, .noKey)
        let keylessResult = await keyless.gifs(for: .sad)
        XCTAssertNil(keylessResult)
        XCTAssertEqual(WebStubURLProtocol.searchCount, 0)
    }

    @MainActor
    func testTooManyRequestsPausesSearching() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let (web, _) = try makeWeb(in: sandbox)
        WebStubURLProtocol.serve(ids: [], media: Data(), searchStatus: 429)

        let refused = await web.gifs(for: .angry)
        XCTAssertNil(refused)
        XCTAssertEqual(web.status, .limitReached)
        XCTAssertEqual(WebStubURLProtocol.searchCount, 1, "GIPHY refusing a search is not retried")

        let other = await web.gifs(for: .confused)
        XCTAssertNil(other)
        XCTAssertEqual(WebStubURLProtocol.searchCount, 1, "no searches while paused")
    }

    @MainActor
    func testARejectedKeyWaitsButANewKeySearchesAtOnce() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let (web, store) = try makeWeb(in: sandbox)
        WebStubURLProtocol.serve(ids: [], media: Data(), searchStatus: 403)

        _ = await web.gifs(for: .smug)
        XCTAssertEqual(web.status, .keyRejected)
        _ = await web.gifs(for: .nervous)
        XCTAssertEqual(WebStubURLProtocol.searchCount, 1, "the refused key waits")

        var settings = store.settings
        settings.giphyAPIKey = "new-key"
        store.settings = settings
        XCTAssertEqual(web.status, .ready)
        WebStubURLProtocol.serve(ids: ids(1), media: try gifData(in: sandbox))
        let gifs = await web.gifs(for: .nervous)
        XCTAssertEqual(gifs?.count, 1)
        XCTAssertEqual(WebStubURLProtocol.searchCount, 1)
    }

    @MainActor
    func testAServerErrorIsRetriedOnce() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let (web, _) = try makeWeb(in: sandbox)
        WebStubURLProtocol.serve(ids: [], media: Data(), searchStatus: 503)

        let failed = await web.gifs(for: .excited)
        XCTAssertNil(failed)
        XCTAssertEqual(WebStubURLProtocol.searchCount, 2)
        XCTAssertEqual(web.status, .ready, "a server error doesn't pause other moods")
    }

    @MainActor
    func testPruningDeletesOldCopiesAndEarlierVersionsResultFiles() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let root = webRoot(in: sandbox)
        let files = root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let oldManifest = root.appendingPathComponent("shocked.json")
        let oldStill = files.appendingPathComponent("abc-still.gif")
        let recentCopy = files.appendingPathComponent("def-full.gif")
        for url in [oldManifest, oldStill, recentCopy] {
            try Data("x".utf8).write(to: url)
        }
        try Data("[]".utf8).write(to: root.appendingPathComponent("rate.json"))
        let twoHoursAgo = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes([.modificationDate: twoHoursAgo], ofItemAtPath: oldStill.path)

        let (web, _) = try makeWeb(in: sandbox)
        web.pruneCache()
        let pruned = await waitUntil(timeout: WebDiscoverTests.budget) {
            !FileManager.default.fileExists(atPath: oldManifest.path) && !FileManager.default.fileExists(atPath: oldStill.path)
        }
        XCTAssertTrue(pruned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentCopy.path), "a copy made within the hour stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("rate.json").path))
    }
}
