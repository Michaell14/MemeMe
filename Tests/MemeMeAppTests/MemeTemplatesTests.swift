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

    func testADescribedPoseBecomesOneGIPHYQueryOfItsWords() {
        XCTAssertEqual(WebQuery.described(from: "Flexing"), .described("flexing"))
        XCTAssertEqual(WebQuery.described(from: "  rock \n ON  "), .described("rock on"), "normalized like typed words")
        XCTAssertNil(WebQuery.described(from: "ok"), "two letters find nothing useful and still cost a search")
        XCTAssertNil(WebQuery.described(from: " - "))
        XCTAssertNil(WebQuery.described(from: ""))
        guard case let .described(long)? = WebQuery.described(from: String(repeating: "flex ", count: 20)) else {
            return XCTFail("long words are cut, not dropped")
        }
        XCTAssertEqual(long, Array(repeating: "flex", count: 10).joined(separator: " "), "cut to 50 and trimmed")

        let rockOn = WebQuery.described("rock on")
        XCTAssertEqual(rockOn.searchTerms, "rock on", "only the few words naming the pose go to GIPHY")
        XCTAssertEqual(rockOn.label, "rock on")
        XCTAssertNotEqual(rockOn, .words("rock on"), "read by the camera, not typed")
        XCTAssertFalse(rockOn.isTyped)
        XCTAssertFalse(WebQuery.mood(.flex).isTyped)
        XCTAssertTrue(WebQuery.words("rock on").isTyped)
    }

    @MainActor
    func testADescribedPoseShowsTheTemplatesItsWordsNameThenTheMoodsAndPages() throws {
        // Eleven plain templates, Surprised Pikachu (made for shocked) and Buff Doge (named by "flexing") last.
        var list: [MemeTemplate] = []
        for number in 1...11 {
            let url = try XCTUnwrap(URL(string: "https://i.imgflip.com/plain\(number).jpg"))
            list.append(MemeTemplate(id: "plain\(number)", name: "Plain Template \(number)", url: url, width: 500, height: 500))
        }
        let pikachuURL = try XCTUnwrap(URL(string: "https://i.imgflip.com/2kbn1e.jpg"))
        list.append(MemeTemplate(id: "155067746", name: "Surprised Pikachu", url: pikachuURL, width: 1893, height: 1893))
        let dogeURL = try XCTUnwrap(URL(string: "https://i.imgflip.com/43a45p.png"))
        list.append(MemeTemplate(id: "247375501", name: "Buff Doge vs. Cheems", url: dogeURL, width: 937, height: 720))

        // What the words name, then the face's mood's (shocked), then the most popular; each once.
        let flexing = WebQuery.described("flexing")
        let first = AppModel.pickTemplates(for: flexing, from: list, fallback: .shocked).map(\.name)
        XCTAssertEqual(first, ["Buff Doge vs. Cheems", "Surprised Pikachu"] + (1...4).map { "Plain Template \($0)" })
        XCTAssertEqual(AppModel.pickTemplates(for: flexing, from: list, page: 0, fallback: .shocked).map(\.name), first)
        let second = AppModel.pickTemplates(for: flexing, from: list, page: 1, fallback: .shocked).map(\.name)
        XCTAssertEqual(second, (5...10).map { "Plain Template \($0)" }, "the same words caught again turn the page")
        let third = AppModel.pickTemplates(for: flexing, from: list, page: 2, fallback: .shocked).map(\.name)
        XCTAssertEqual(third.count, Theme.columns, "wrapping around, the row stays full")
        XCTAssertEqual(Set(first + second + third), Set(list.map(\.name)), "every template turns up within three pages")

        // Words that name nothing are never an empty row: the face's mood's templates, paged the same way.
        let unnamed = WebQuery.described("zorblax wiggle")
        for page in 0...2 {
            XCTAssertEqual(AppModel.pickTemplates(for: unnamed, from: list, page: page, fallback: .shocked).map(\.name),
                           AppModel.pickTemplates(for: .mood(.shocked), from: list, page: page).map(\.name))
        }
        XCTAssertEqual(AppModel.pickTemplates(for: unnamed, from: list).map(\.name),
                       AppModel.pickTemplates(for: .mood(.reaction), from: list).map(\.name),
                       "without a face, the most popular")
        XCTAssertTrue(AppModel.pickTemplates(for: flexing, from: []).isEmpty)
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
    func testTheSameMoodCaughtAgainTurnsToTheNextTemplates() throws {
        // Eleven plain templates and Surprised Pikachu (made for shocked) last in Imgflip's order: for shocked,
        // Pikachu first, then the plain ones in order.
        var list: [MemeTemplate] = []
        for number in 1...11 {
            let url = try XCTUnwrap(URL(string: "https://i.imgflip.com/plain\(number).jpg"))
            list.append(MemeTemplate(id: "plain\(number)", name: "Plain Template \(number)", url: url, width: 500, height: 500))
        }
        let pikachuURL = try XCTUnwrap(URL(string: "https://i.imgflip.com/2kbn1e.jpg"))
        list.append(MemeTemplate(id: "155067746", name: "Surprised Pikachu", url: pikachuURL, width: 1893, height: 1893))

        let first = AppModel.pickTemplates(for: .mood(.shocked), from: list).map(\.name)
        XCTAssertEqual(first, ["Surprised Pikachu"] + (1...5).map { "Plain Template \($0)" })
        XCTAssertEqual(AppModel.pickTemplates(for: .mood(.shocked), from: list, page: 0).map(\.name), first)
        XCTAssertEqual(AppModel.pickTemplates(for: .mood(.shocked), from: list, page: 1).map(\.name),
                       (6...11).map { "Plain Template \($0)" })
        XCTAssertEqual(AppModel.pickTemplates(for: .mood(.shocked), from: list, page: 2).map(\.name), first,
                       "back to the start once all twelve were shown")
        // Typed words have no pages.
        XCTAssertEqual(AppModel.pickTemplates(for: .words("pikachu"), from: list, page: 1).map(\.name), ["Surprised Pikachu"])
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
