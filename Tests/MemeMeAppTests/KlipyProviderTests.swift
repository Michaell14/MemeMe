import Foundation
@testable import MemeMeApp
import MemeMeCore
import XCTest

/// KLIPY's answers, served by `GiphyStubURLProtocol` (it serves any canned JSON).
final class KlipyProviderTests: XCTestCase {
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GiphyStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func queryItems(of request: URLRequest?) throws -> [String: String] {
        let url = try XCTUnwrap(request?.url, "KlipyProvider made no request")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        var items: [String: String] = [:]
        for item in components.queryItems ?? [] {
            items[item.name] = item.value ?? ""
        }
        return items
    }

    func testSearchMapsRenditionsAndSkipsAdsAndEntriesWithoutThem() async throws {
        GiphyStubURLProtocol.respond(status: 200, json: KlipyProviderTests.searchPayload)
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let provider = KlipyProvider(apiKey: "test-key", session: session)

        let gifs = try await provider.search("shocked", limit: 24)

        // Entry 2 is an ad, entry 3 has no GIF to copy, entry 4 repeats entry 1's id, entry 5 has only http:// URLs.
        XCTAssertEqual(gifs.map(\.id), ["1234567", "abc-9"])
        XCTAssertEqual(provider.name, "KLIPY")

        let shocked = try XCTUnwrap(gifs.first)
        XCTAssertEqual(shocked.title, "Shocked Face")
        XCTAssertEqual(shocked.stillURL, URL(string: "https://static.klipy.com/1234567/sm.jpg"), "a GIF's still is sm.jpg")
        XCTAssertEqual(shocked.previewURL, URL(string: "https://static.klipy.com/1234567/sm.gif"))
        XCTAssertEqual(shocked.fullURL, URL(string: "https://static.klipy.com/1234567/md.gif"), "md.gif is copied, not hd")
        XCTAssertEqual(shocked.width, 300, "sizes describe the copied rendition")
        XCTAssertEqual(shocked.height, 280)
        XCTAssertEqual(shocked.provider, "KLIPY")
        XCTAssertNil(shocked.pageURL)

        // Fallbacks: no sm, so xs's still and preview; no md, so hd's GIF; sizes as strings; an empty title.
        let fallback = try XCTUnwrap(gifs.last)
        XCTAssertEqual(fallback.title, "GIF")
        XCTAssertEqual(fallback.stillURL, URL(string: "https://static.klipy.com/abc-9/xs.jpg"))
        XCTAssertEqual(fallback.previewURL, URL(string: "https://static.klipy.com/abc-9/xs.gif"))
        XCTAssertEqual(fallback.fullURL, URL(string: "https://static.klipy.com/abc-9/hd.gif"))
        XCTAssertEqual(fallback.width, 498)
        XCTAssertEqual(fallback.height, 374)
    }

    func testTheKeyGoesInThePathWithOnlyTheDocumentedParameters() async throws {
        GiphyStubURLProtocol.respond(status: 200, json: KlipyProviderTests.searchPayload)
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        _ = try await KlipyProvider(apiKey: "test-key", session: session).search("  shocked  ", limit: 100)
        let request = GiphyStubURLProtocol.recordedRequests().first
        XCTAssertEqual(request?.url?.host, "api.klipy.com")
        XCTAssertEqual(request?.url?.path, "/api/v1/test-key/gifs/search")
        let items = try queryItems(of: request)
        XCTAssertEqual(Set(items.keys), ["q", "per_page", "page", "customer_id", "content_filter"])
        XCTAssertEqual(items["q"], "shocked")
        XCTAssertEqual(items["per_page"], "50", "per_page is at most 50")
        XCTAssertEqual(items["page"], "1")
        XCTAssertEqual(items["customer_id"], KlipyProvider.launchCustomerID)
        XCTAssertEqual(items["content_filter"], "medium")

        _ = try await KlipyProvider(apiKey: "test-key", kind: .stickers, session: session).trending(limit: 2)
        let trending = GiphyStubURLProtocol.recordedRequests().last
        XCTAssertEqual(trending?.url?.path, "/api/v1/test-key/stickers/trending")
        let trendingItems = try queryItems(of: trending)
        XCTAssertNil(trendingItems["q"], "trending sends no words")
        XCTAssertEqual(trendingItems["per_page"], "8", "per_page is at least 8")
    }

    func testAStickersStillKeepsItsTransparency() async throws {
        GiphyStubURLProtocol.respond(status: 200, json: KlipyProviderTests.searchPayload)
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let stickers = try await KlipyProvider(apiKey: "test-key", kind: .stickers, session: session).search("wow", limit: 24)
        XCTAssertEqual(stickers.first?.stillURL, URL(string: "https://static.klipy.com/1234567/sm.webp"),
                       "no JPEG for a sticker: sm has no png, so its webp")
        XCTAssertEqual(stickers.first?.title, "Shocked Face")
    }

    func testAnEmptyQueryAsksNothing() async throws {
        GiphyStubURLProtocol.respond(status: 200, json: KlipyProviderTests.searchPayload)
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let gifs = try await KlipyProvider(apiKey: "test-key", session: session).search("   ", limit: 24)
        XCTAssertTrue(gifs.isEmpty)
        XCTAssertTrue(GiphyStubURLProtocol.recordedRequests().isEmpty)
    }

    func testAnUnknownKeyReadsAsRefused() async throws {
        // What KLIPY answers for a key it doesn't know.
        GiphyStubURLProtocol.respond(status: 404, json: #"{"result":false,"errors":{"message":["The provided API key is invalid."]}}"#)
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        do {
            _ = try await KlipyProvider(apiKey: "wrong-key", session: session).search("shocked", limit: 24)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(WebAPIError.status(of: error), 401)
        }

        GiphyStubURLProtocol.respond(status: 429, json: #"{"result":false}"#)
        do {
            _ = try await KlipyProvider(apiKey: "test-key", session: session).trending(limit: 24)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(WebAPIError.status(of: error), 429, "too many requests stays 429")
        }
    }

    func testAKeyThatWouldChangeThePathIsNeverSent() async throws {
        GiphyStubURLProtocol.respond(status: 200, json: KlipyProviderTests.searchPayload)
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        do {
            _ = try await KlipyProvider(apiKey: "../other/key", session: session).search("shocked", limit: 24)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(WebAPIError.status(of: error), 401)
        }
        XCTAssertTrue(GiphyStubURLProtocol.recordedRequests().isEmpty)
    }

    func testAResultsServiceIsReadFromItsProvider() {
        XCTAssertEqual(WebService(provider: "KLIPY"), .klipy)
        XCTAssertEqual(WebService(provider: "GIPHY"), .giphy)
        XCTAssertEqual(WebService(provider: ""), .giphy)
        XCTAssertEqual(WebDiscover.cacheFolder(service: .klipy, kind: .stickers), "MemeMe/KlipyStickers")
        XCTAssertEqual(WebDiscover.cacheFolder(service: .giphy, kind: .gifs), "MemeMe/Web", "GIPHY's cache stays put")
    }

    private static let searchPayload = #"""
    {
      "result": true,
      "data": {
        "data": [
          {
            "id": 1234567,
            "slug": "shocked-face",
            "title": "Shocked Face",
            "type": "gif",
            "file": {
              "hd": { "gif": { "url": "https://static.klipy.com/1234567/hd.gif", "width": 498, "height": 464, "size": 900000 } },
              "md": { "gif": { "url": "https://static.klipy.com/1234567/md.gif", "width": 300, "height": 280, "size": 400000 },
                      "jpg": { "url": "https://static.klipy.com/1234567/md.jpg", "width": 300, "height": 280 } },
              "sm": { "gif": { "url": "https://static.klipy.com/1234567/sm.gif", "width": 220, "height": 205 },
                      "jpg": { "url": "https://static.klipy.com/1234567/sm.jpg", "width": 220, "height": 205 },
                      "webp": { "url": "https://static.klipy.com/1234567/sm.webp", "width": 220, "height": 205 } },
              "xs": { "jpg": { "url": "https://static.klipy.com/1234567/xs.jpg", "width": 90, "height": 84 } }
            }
          },
          {
            "id": 1,
            "type": "ad",
            "title": "Sponsored",
            "file": { "md": { "gif": { "url": "https://ads.example.com/ad.gif", "width": 300, "height": 250 } },
                      "sm": { "jpg": { "url": "https://ads.example.com/ad.jpg", "width": 300, "height": 250 } } }
          },
          {
            "id": 2,
            "title": "No GIF",
            "file": { "sm": { "jpg": { "url": "https://static.klipy.com/2/sm.jpg", "width": 220, "height": 220 } } }
          },
          {
            "id": "1234567",
            "title": "Duplicate",
            "file": { "md": { "gif": { "url": "https://static.klipy.com/dup/md.gif" } },
                      "sm": { "jpg": { "url": "https://static.klipy.com/dup/sm.jpg" } } }
          },
          {
            "id": 5,
            "title": "Insecure",
            "file": { "md": { "gif": { "url": "http://static.klipy.com/5/md.gif" } },
                      "sm": { "jpg": { "url": "http://static.klipy.com/5/sm.jpg" } } }
          },
          {
            "id": "abc-9",
            "title": "",
            "file": {
              "hd": { "gif": { "url": "https://static.klipy.com/abc-9/hd.gif", "width": "498", "height": "374" } },
              "xs": { "gif": { "url": "https://static.klipy.com/abc-9/xs.gif", "width": 90, "height": 68 },
                      "jpg": { "url": "https://static.klipy.com/abc-9/xs.jpg", "width": 90, "height": 68 } }
            }
          }
        ],
        "current_page": 1,
        "per_page": 24,
        "has_next": false
      }
    }
    """#
}
