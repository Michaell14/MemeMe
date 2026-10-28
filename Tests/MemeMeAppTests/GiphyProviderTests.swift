import Foundation
@testable import MemeMeApp
import MemeMeCore
import XCTest

/// Serves canned GIPHY responses to a URLSession built with this protocol class, and records the requests.
final class GiphyStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var statusCode = 200
    private static var body = Data()
    private static var requests: [URLRequest] = []

    /// Sets the next responses and forgets earlier requests.
    static func respond(status: Int, json: String) {
        lock.lock()
        defer { lock.unlock() }
        statusCode = status
        body = Data(json.utf8)
        requests = []
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    private static func record(_ request: URLRequest) -> (status: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return (status: statusCode, body: body)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let reply = GiphyStubURLProtocol.record(request)
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: reply.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
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

final class GiphyProviderTests: XCTestCase {
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GiphyStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func queryItems(of request: URLRequest?) throws -> [String: String] {
        let url = try XCTUnwrap(request?.url, "GiphyProvider made no request")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        var items: [String: String] = [:]
        for item in components.queryItems ?? [] {
            items[item.name] = item.value ?? ""
        }
        return items
    }

    func testSearchMapsRenditionsAndSkipsEntriesWithoutThem() async throws {
        GiphyStubURLProtocol.respond(status: 200, json: GiphyProviderTests.searchPayload)
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let provider = GiphyProvider(apiKey: "test-key", session: session)

        let gifs = try await provider.search("shocked reaction", limit: 25)

        // Entry 2 has no still rendition, entry 4 repeats entry 1's id, entry 5 only has http:// URLs.
        XCTAssertEqual(gifs.map { $0.id }, ["FiGiRei2ICzzG", "3o7TKSjRrfIPjeiVyM"])
        XCTAssertEqual(provider.name, "GIPHY")

        let shocked = try XCTUnwrap(gifs.first)
        XCTAssertEqual(shocked.title, "Shocked Oh My God")
        XCTAssertEqual(shocked.creator, "Some Channel", "the maker comes from user.display_name")
        XCTAssertNil(gifs.last?.creator, "results without a user have no creator")
        XCTAssertEqual(shocked.stillURL, URL(string: "https://media2.giphy.com/media/FiGiRei2ICzzG/100w_s.gif?cid=e1bb72ff&rid=100w_s.gif&ct=g"),
                       "stillURL comes from images.fixed_width_small_still")
        XCTAssertEqual(shocked.previewURL, URL(string: "https://media2.giphy.com/media/FiGiRei2ICzzG/100w.gif?cid=e1bb72ff&rid=100w.gif&ct=g"),
                       "previewURL comes from images.fixed_width_small")
        XCTAssertEqual(shocked.fullURL, URL(string: "https://media2.giphy.com/media/FiGiRei2ICzzG/giphy-downsized.gif?cid=e1bb72ff&rid=giphy-downsized.gif&ct=g"),
                       "fullURL comes from images.downsized (≤ 2 MB), not original")
        XCTAssertEqual(shocked.width, 250, "Sizes arrive as strings and describe the full (downsized) rendition")
        XCTAssertEqual(shocked.height, 250)
        XCTAssertEqual(shocked.pageURL, URL(string: "https://giphy.com/gifs/funny-shocked-FiGiRei2ICzzG"))
        XCTAssertEqual(shocked.provider, "GIPHY")

        // Fallbacks: fixed_width_still for the still, original for the full GIF, no preview.
        let surprised = try XCTUnwrap(gifs.last)
        XCTAssertEqual(surprised.title, "Surprised Reaction")
        XCTAssertEqual(surprised.stillURL, URL(string: "https://media0.giphy.com/media/3o7TKSjRrfIPjeiVyM/200w_s.gif"))
        XCTAssertNil(surprised.previewURL)
        XCTAssertEqual(surprised.fullURL, URL(string: "https://media0.giphy.com/media/3o7TKSjRrfIPjeiVyM/giphy.gif"))
        XCTAssertEqual(surprised.width, 480, "Plain JSON numbers are accepted too")
        XCTAssertEqual(surprised.height, 270)
        XCTAssertEqual(surprised.provider, "GIPHY")
    }

    func testSearchSendsOnlyTheQueryAndTheDocumentedParameters() async throws {
        GiphyStubURLProtocol.respond(status: 200, json: GiphyProviderTests.searchPayload)
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let provider = GiphyProvider(apiKey: "test-key", session: session)

        _ = try await provider.search("shocked reaction", limit: 25)

        let requests = GiphyStubURLProtocol.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        let request = requests.first
        let url = try XCTUnwrap(request?.url)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "api.giphy.com")
        XCTAssertEqual(url.path, "/v1/gifs/search")
        XCTAssertEqual(request?.httpMethod ?? "GET", "GET")
        XCTAssertEqual(try queryItems(of: request), [
            "api_key": "test-key",
            "q": "shocked reaction",
            "limit": "25",
            "offset": "0",
            "rating": "pg-13",
            "lang": "en",
        ])
    }

    func testLimitIsClampedToWhatGiphyAccepts() async throws {
        GiphyStubURLProtocol.respond(status: 200, json: #"{"data": []}"#)
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let provider = GiphyProvider(apiKey: "test-key", rating: "g", session: session)

        _ = try await provider.search("happy", limit: 500)
        _ = try await provider.search("happy", limit: 0)

        let requests = GiphyStubURLProtocol.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(try queryItems(of: requests.first)["limit"], "50")
        XCTAssertEqual(try queryItems(of: requests.last)["limit"], "1")
        XCTAssertEqual(try queryItems(of: requests.first)["rating"], "g")
    }

    func testBlankQueryMakesNoRequest() async throws {
        GiphyStubURLProtocol.respond(status: 200, json: GiphyProviderTests.searchPayload)
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let provider = GiphyProvider(apiKey: "test-key", session: session)

        let gifs = try await provider.search("   ", limit: 25)

        XCTAssertTrue(gifs.isEmpty)
        XCTAssertTrue(GiphyStubURLProtocol.recordedRequests().isEmpty)
    }

    func testHTTPErrorThrows() async throws {
        GiphyStubURLProtocol.respond(status: 429, json: #"{"message": "API rate limit exceeded"}"#)
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let provider = GiphyProvider(apiKey: "test-key", session: session)

        do {
            let gifs = try await provider.search("crying", limit: 10)
            XCTFail("A 429 response should throw, got \(gifs.count) results")
        } catch {
            // Expected: WebDiscover treats a throw as a failed fetch.
        }
    }

    func testMissingOrMalformedDataArrayYieldsNoResults() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let provider = GiphyProvider(apiKey: "test-key", session: session)

        GiphyStubURLProtocol.respond(status: 200, json: #"{"meta": {"status": 200, "msg": "OK"}}"#)
        let missing = try await provider.search("sad", limit: 10)
        XCTAssertTrue(missing.isEmpty)

        GiphyStubURLProtocol.respond(status: 200, json: #"{"data": "unavailable"}"#)
        let malformed = try await provider.search("sad", limit: 10)
        XCTAssertTrue(malformed.isEmpty)
    }

    // MARK: - Fixture

    /// Shaped like a real `/v1/gifs/search` response: sizes as strings, extra keys, query strings on media URLs.
    static let searchPayload = #"""
    {
      "data": [
        {
          "type": "gif",
          "id": "FiGiRei2ICzzG",
          "url": "https://giphy.com/gifs/funny-shocked-FiGiRei2ICzzG",
          "slug": "funny-shocked-FiGiRei2ICzzG",
          "bitly_url": "https://gph.is/1Xb5BlS",
          "title": "Shocked Oh My God GIF by Some Channel",
          "rating": "pg",
          "import_datetime": "2016-06-15 20:10:56",
          "images": {
            "original": {
              "height": "480", "width": "480", "size": "3109447", "frames": "61",
              "url": "https://media2.giphy.com/media/FiGiRei2ICzzG/giphy.gif?cid=e1bb72ff&rid=giphy.gif&ct=g",
              "mp4": "https://media2.giphy.com/media/FiGiRei2ICzzG/giphy.mp4?cid=e1bb72ff&rid=giphy.mp4&ct=g",
              "hash": "8b5e0c1d"
            },
            "downsized": {
              "height": "250", "width": "250", "size": "1475913",
              "url": "https://media2.giphy.com/media/FiGiRei2ICzzG/giphy-downsized.gif?cid=e1bb72ff&rid=giphy-downsized.gif&ct=g"
            },
            "fixed_width_small": {
              "height": "100", "width": "100", "size": "301212",
              "url": "https://media2.giphy.com/media/FiGiRei2ICzzG/100w.gif?cid=e1bb72ff&rid=100w.gif&ct=g",
              "webp": "https://media2.giphy.com/media/FiGiRei2ICzzG/100w.webp?cid=e1bb72ff&rid=100w.webp&ct=g"
            },
            "fixed_width_small_still": {
              "height": "100", "width": "100", "size": "6290",
              "url": "https://media2.giphy.com/media/FiGiRei2ICzzG/100w_s.gif?cid=e1bb72ff&rid=100w_s.gif&ct=g"
            },
            "fixed_width_still": {
              "height": "200", "width": "200", "size": "19104",
              "url": "https://media2.giphy.com/media/FiGiRei2ICzzG/200w_s.gif?cid=e1bb72ff&rid=200w_s.gif&ct=g"
            },
            "looping": {
              "mp4_size": "1702011",
              "mp4": "https://media2.giphy.com/media/FiGiRei2ICzzG/giphy-loop.mp4?cid=e1bb72ff&rid=giphy-loop.mp4&ct=g"
            }
          },
          "user": { "username": "somechannel", "display_name": "Some Channel" },
          "analytics_response_payload": "e=Z2lmX2lkPUZpR2lSZWkySUN6ekc"
        },
        {
          "type": "gif",
          "id": "noStillRendition",
          "url": "https://giphy.com/gifs/wow-noStillRendition",
          "title": "Wow GIF",
          "rating": "g",
          "images": {
            "original": { "height": "200", "width": "200", "url": "https://media1.giphy.com/media/noStillRendition/giphy.gif" },
            "downsized": { "height": "200", "width": "200", "url": "https://media1.giphy.com/media/noStillRendition/giphy-downsized.gif" },
            "fixed_width_small": { "height": "100", "width": "100", "url": "https://media1.giphy.com/media/noStillRendition/100w.gif" }
          }
        },
        {
          "type": "gif",
          "id": "3o7TKSjRrfIPjeiVyM",
          "url": "https://giphy.com/gifs/reaction-3o7TKSjRrfIPjeiVyM",
          "title": "Surprised Reaction GIF",
          "rating": "g",
          "images": {
            "original": { "height": 270, "width": 480, "url": "https://media0.giphy.com/media/3o7TKSjRrfIPjeiVyM/giphy.gif" },
            "fixed_width_still": { "height": "113", "width": "200", "url": "https://media0.giphy.com/media/3o7TKSjRrfIPjeiVyM/200w_s.gif" }
          }
        },
        {
          "type": "gif",
          "id": "FiGiRei2ICzzG",
          "url": "https://giphy.com/gifs/funny-shocked-FiGiRei2ICzzG",
          "title": "Shocked Oh My God GIF (repeat)",
          "images": {
            "downsized": { "height": "250", "width": "250", "url": "https://media2.giphy.com/media/FiGiRei2ICzzG/giphy-downsized.gif" },
            "fixed_width_small_still": { "height": "100", "width": "100", "url": "https://media2.giphy.com/media/FiGiRei2ICzzG/100w_s.gif" }
          }
        },
        {
          "type": "gif",
          "id": "insecureOnly",
          "url": "http://giphy.com/gifs/insecureOnly",
          "title": "Insecure GIF",
          "images": {
            "downsized": { "height": "200", "width": "200", "url": "http://media.giphy.com/media/insecureOnly/giphy-downsized.gif" },
            "fixed_width_small_still": { "height": "100", "width": "100", "url": "http://media.giphy.com/media/insecureOnly/100w_s.gif" }
          }
        }
      ],
      "pagination": { "total_count": 4218, "count": 5, "offset": 0 },
      "meta": { "status": 200, "msg": "OK", "response_id": "f3c2b1a0e9d8" }
    }
    """#
}
