import AppKit
import Foundation
@testable import MemeMeApp
import MemeMeCore
import XCTest

/// A tiny Imgflip for a URLSession built with this protocol class: api.imgflip.com answers with `list`, every other
/// URL with `image`.
final class TemplateStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var listBody = Data()
    private static var imageBody = Data()
    private static var listRequests = 0

    static func serve(list: Data, image: Data) {
        lock.lock()
        defer { lock.unlock() }
        listBody = list
        imageBody = image
        listRequests = 0
    }

    static var listRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return listRequests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }
        let isList = url.host == "api.imgflip.com"
        TemplateStubURLProtocol.lock.lock()
        if isList {
            TemplateStubURLProtocol.listRequests += 1
        }
        let body = isList ? TemplateStubURLProtocol.listBody : TemplateStubURLProtocol.imageBody
        TemplateStubURLProtocol.lock.unlock()
        let headers = ["Content-Type": isList ? "application/json" : "image/png"]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class MemeTemplatesTests: XCTestCase {
    /// Imgflip's answer: the second entry repeats an id, the third is not https.
    private let listJSON = """
    {"success": true, "data": {"memes": [
      {"id": "112126428", "name": "Distracted Boyfriend", "url": "https://i.imgflip.com/1ur9b0.jpg", "width": 1200, "height": 800, "box_count": 3},
      {"id": "112126428", "name": "Distracted Boyfriend again", "url": "https://i.imgflip.com/1ur9b0.jpg", "width": 1200, "height": 800},
      {"id": "1", "name": "Plain HTTP", "url": "http://example.com/a.jpg", "width": 10, "height": 10},
      {"id": "155067746", "name": "Surprised Pikachu", "url": "https://i.imgflip.com/2kbn1e.jpg", "width": 1893, "height": 1893},
      {"id": "80707627", "name": "Sad Pablo Escobar", "url": "https://i.imgflip.com/1c1uej.jpg", "width": 720, "height": 709}
    ]}}
    """

    func testImgflipsListIsReadInOrderOnceEachAndHTTPSOnly() throws {
        let list = try XCTUnwrap(MemeTemplates.parseList(Data(listJSON.utf8)))
        XCTAssertEqual(list.map(\.name), ["Distracted Boyfriend", "Surprised Pikachu", "Sad Pablo Escobar"])
        XCTAssertEqual(list.first?.width, 1200)
        XCTAssertNil(MemeTemplates.parseList(Data(#"{"success": false, "error_message": "nope"}"#.utf8)))
        XCTAssertNil(MemeTemplates.parseList(Data("not json".utf8)))
    }

    func testTypedWordsBecomeOneGIPHYQuery() {
        XCTAssertEqual(WebQuery.words(from: ["Sad"]), .words("sad"))
        XCTAssertEqual(WebQuery.words(from: ["  so ", " Sad  dog"]), .words("so sad dog"))
        XCTAssertNil(WebQuery.words(from: ["a"]))
        XCTAssertNil(WebQuery.words(from: ["ok"]), "two letters find nothing useful and still cost a search")
        XCTAssertNil(WebQuery.words(from: ["!!"]))
        XCTAssertNil(WebQuery.words(from: []))
        guard case let .words(long)? = WebQuery.words(from: [String(repeating: "x", count: 80)]) else {
            return XCTFail("a long query is cut, not dropped")
        }
        XCTAssertEqual(long.count, WebQuery.maximumLength)
        XCTAssertEqual(WebQuery.mood(.shocked).searchTerms, "shocked reaction")
        XCTAssertEqual(WebQuery.words("so sad").label, "so sad")
    }

    @MainActor
    func testTheRowPicksTemplatesForAMoodOrWords() throws {
        let list = try XCTUnwrap(MemeTemplates.parseList(Data(listJSON.utf8)))
        XCTAssertEqual(AppModel.pickTemplates(for: .mood(.shocked), from: list).first?.name, "Surprised Pikachu")
        XCTAssertEqual(AppModel.pickTemplates(for: .mood(.reaction), from: list).map(\.name),
                       ["Distracted Boyfriend", "Surprised Pikachu", "Sad Pablo Escobar"])
        XCTAssertEqual(AppModel.pickTemplates(for: .words("sad"), from: list).map(\.name), ["Sad Pablo Escobar"])
        XCTAssertEqual(AppModel.pickTemplates(for: .words("guy looking back"), from: list).map(\.name), ["Distracted Boyfriend"])
    }

    @MainActor
    func testTheListIsFetchedOnceKeptAndItsImagesLoadAndCopy() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let png = try XCTUnwrap(CaptureEncoder.png(try TestImages.shapes(width: 400, height: 300)))
        TemplateStubURLProtocol.serve(list: Data(listJSON.utf8), image: png)
        let store = try LibraryStore(rootURL: sandbox.url.appendingPathComponent("Library", isDirectory: true))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TemplateStubURLProtocol.self]
        let root = sandbox.url.appendingPathComponent("Templates", isDirectory: true)

        let templates = MemeTemplates(store: store, cacheRoot: root, configuration: configuration)
        XCTAssertNil(templates.cachedList)
        let fetched = await templates.templates()
        let list = try XCTUnwrap(fetched)
        XCTAssertEqual(list.count, 3)
        _ = await templates.templates()
        XCTAssertEqual(TemplateStubURLProtocol.listRequestCount, 1, "the list is asked for once a day")

        let loaded = await templates.image(for: list[0])
        let image = try XCTUnwrap(loaded)
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 320)
        XCTAssertNotNil(templates.cachedImage(for: list[0]))

        let prepared = await templates.prepareForCopy(list[0])
        let file = try XCTUnwrap(prepared)
        XCTAssertEqual(try Data(contentsOf: file), png)
        XCTAssertTrue(file.path.hasPrefix(root.path))

        // The next launch starts from the kept list without asking Imgflip again.
        let later = MemeTemplates(store: store, cacheRoot: root, configuration: configuration)
        XCTAssertEqual(later.cachedList?.map(\.id), list.map(\.id))
        _ = await later.templates()
        XCTAssertEqual(TemplateStubURLProtocol.listRequestCount, 1)

        // Off with Web Discover.
        var settings = store.settings
        settings.webDiscoverEnabled = false
        store.settings = settings
        XCTAssertNil(later.cachedList)
        let offList = await later.templates()
        XCTAssertNil(offList)
    }
}
