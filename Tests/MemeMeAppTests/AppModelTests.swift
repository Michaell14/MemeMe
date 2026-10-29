import Foundation
@testable import MemeMeApp
import MemeMeCore
import XCTest

/// A stand-in for the on-device model: names from a table, each pose asked about once (its answer, nil too, kept like
/// `PoseNamer` keeps it). Unavailable unless a test says so, so no test asks the Mac's model.
@MainActor
private final class StubPoseNamer: PoseNaming {
    var isAvailable = false
    var names: [String: String] = [:]
    private(set) var questions = 0
    private(set) var prewarms = 0
    private var answers: [String: String?] = [:]

    func cachedName(for description: PoseDescription) -> String?? {
        answers[description.key]
    }

    func prewarm() {
        prewarms += 1
    }

    func name(_ description: PoseDescription) async -> String? {
        if let answer = answers[description.key] {
            return answer
        }
        questions += 1
        let answer = isAvailable ? names[description.key] : nil
        answers[description.key] = .some(answer)
        return answer
    }
}

/// AppModel can be built headless: its init only creates the camera controller (an AVCaptureSession that is not
/// started), the indexer, web discovery and the friend service. Web discovery is switched off in these stores and
/// its cache lives in the test's temporary folder, so no network and no web cache on this Mac take part.
///
/// `panelWillShow` would ask for camera access 0.6 s after opening when access is undecided (activating the app for
/// the system prompt); `requestsCameraAccessOnShow = false` turns that off, so the checks don't depend on timing.
///
/// A described pose's search (`runExpressionSearch` asking the namer, the web rows waiting for its words) can't be
/// driven from here: it starts from a held query, which the tracker only takes from frames while the camera is live,
/// and the panel only goes live with a camera and camera access (CI has neither). What it decides is checked through
/// `AppModel.describedWords` with a stand-in namer, and its pieces (`WebQuery.described`, `pickTemplates`) in
/// MemeTemplatesTests and WebDiscoverTests.
final class AppModelTests: XCTestCase {
    /// How long a test waits for the panel to react (the text search is debounced by 80 ms).
    private static let openPanelBudget: TimeInterval = 2

    /// Whole-second UTC dates in the middle of their months.
    private static let january20 = Date(timeIntervalSince1970: 1_768_903_200)    // 2026-01-20T10:00:00Z
    private static let february10 = Date(timeIntervalSince1970: 1_770_710_400)   // 2026-02-10T08:00:00Z
    private static let march15 = Date(timeIntervalSince1970: 1_773_576_000)      // 2026-03-15T12:00:00Z

    /// `poseNamer`: nil = a stand-in without a model (`StubPoseNamer`).
    @MainActor
    private func makeModel(in sandbox: TestSandbox, items: [LibraryItem], people: [Person] = [],
                           poseNamer: (any PoseNaming)? = nil) throws -> AppModel {
        let store = try LibraryStore(rootURL: sandbox.url.appendingPathComponent("Library", isDirectory: true))
        var settings = store.settings
        settings.webDiscoverEnabled = false
        settings.hasCompletedFirstRun = true
        settings.libraryOfferAccepted = true
        store.settings = settings
        for item in items {
            let added = store.add(item)
            XCTAssertTrue(added, "duplicate fixture \(item.displayName)")
        }
        for person in people {
            store.upsert(person)
        }
        let namer: any PoseNaming
        if let poseNamer {
            namer = poseNamer
        } else {
            namer = StubPoseNamer()
        }
        let model = AppModel(store: store, webCacheRoot: sandbox.url.appendingPathComponent("WebCache", isDirectory: true),
                             poseNamer: namer)
        model.requestsCameraAccessOnShow = false
        return model
    }

    /// "Zorblax" matches the March meme by name and the January maybe-tier image by its OCR text; the dog matches nothing.
    private func fixtures(in sandbox: TestSandbox) -> (march: LibraryItem, january: LibraryItem, unrelated: LibraryItem) {
        let march = LibraryItem(
            fileURL: sandbox.file("zorblax shocked.png"),
            displayName: "Zorblax shocked",
            kind: .mine,
            tier: .meme,
            source: "Downloads",
            addedAt: AppModelTests.march15,
            fileModifiedAt: AppModelTests.march15,
            contentHash: "hash-march"
        )
        let january = LibraryItem(
            fileURL: sandbox.file("IMG_0001.png"),
            displayName: "IMG_0001",
            kind: .mine,
            tier: .maybe,
            source: "Desktop",
            addedAt: AppModelTests.january20,
            fileModifiedAt: AppModelTests.january20,
            contentHash: "hash-january",
            text: "when the zorblax arrives"
        )
        let unrelated = LibraryItem(
            fileURL: sandbox.file("calm dog.png"),
            displayName: "Calm dog",
            kind: .mine,
            tier: .meme,
            source: "Downloads",
            addedAt: AppModelTests.february10,
            fileModifiedAt: AppModelTests.february10,
            contentHash: "hash-dog"
        )
        return (march: march, january: january, unrelated: unrelated)
    }

    @MainActor
    func testLaunchForgetsGIPHYPicksEarlierVersionsSaved() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let items = fixtures(in: sandbox)
        let pick = LibraryItem(
            fileURL: sandbox.url.appendingPathComponent("Library/Sent/abc-still.gif"),
            displayName: "Shocked",
            kind: .web,
            source: "GIPHY",
            contentHash: "giphy:abc",
            isAnimated: true
        )
        let model = try makeModel(in: sandbox, items: [items.march, pick])

        XCTAssertEqual(model.store.items.map { $0.id }, [items.march.id], "saved GIPHY picks are removed when the app starts")
        model.panelWillShow(previousApp: nil)
        defer {
            model.panelDidHide()
            model.saveNow()
        }
        XCTAssertEqual(model.results.map { $0.item.id }, [items.march.id])
        XCTAssertFalse(model.showsGiphyRow, "Web Discover is off in these tests")
        XCTAssertTrue(model.giphyResults.isEmpty)
        XCTAssertEqual(model.focusedPick, .meme(items.march))
    }

    @MainActor
    func testTypingSearchesByWordsGroupedByMonth() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let items = fixtures(in: sandbox)
        let model = try makeModel(in: sandbox, items: [items.march, items.january, items.unrelated])

        model.panelWillShow(previousApp: nil)
        defer {
            model.panelDidHide()
            model.saveNow()
        }
        model.queryText = "zorblax"
        let reachedText = await waitUntil(timeout: AppModelTests.openPanelBudget) { model.mode == .text }
        let mode = model.mode
        let results = model.results
        let hint = model.hint
        let focusedIndex = model.focusedIndex
        let showsFaceToken = model.showsFaceToken
        let naming = model.naming

        XCTAssertTrue(reachedText, "Typing should switch to text mode after the 80 ms debounce (mode is \(mode))")
        XCTAssertEqual(results.map { $0.item.id }, [items.march.id, items.january.id],
                       "Own matches grouped by month, newest month first; maybe-tier items are found by typing")
        XCTAssertEqual(results.map { $0.section }, ["March 2026", "January 2026"])
        XCTAssertFalse(results.contains { $0.item.id == items.unrelated.id })
        XCTAssertEqual(hint.title, "Searching by words")
        XCTAssertEqual(hint.subtitle, "The camera is off while you type.")
        XCTAssertEqual(focusedIndex, 0)
        XCTAssertFalse(showsFaceToken, "Typing right after opening stops the camera instead of keeping a face token")
        XCTAssertNil(naming)
    }

    @MainActor
    func testEscapeClearsTheTextFirstAndClosesSecond() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let items = fixtures(in: sandbox)
        let model = try makeModel(in: sandbox, items: [items.march, items.january, items.unrelated])

        model.panelWillShow(previousApp: nil)
        defer {
            model.panelDidHide()
            model.saveNow()
        }
        model.queryText = "zorblax"
        _ = await waitUntil(timeout: AppModelTests.openPanelBudget) { model.mode == .text }

        let first = model.handleEscape()
        let textAfterFirst = model.queryText
        let modeAfterFirst = model.mode
        let resultsAfterFirst = model.results
        let hintAfterFirst = model.hint
        let second = model.handleEscape()

        XCTAssertTrue(first, "The first Esc clears the typed text and keeps the panel open")
        XCTAssertEqual(textAfterFirst, "")
        XCTAssertNotEqual(modeAfterFirst, .text)
        XCTAssertNotEqual(hintAfterFirst.title, "Searching by words")
        // Back to the recent grid: own meme-tier items, no text sections.
        XCTAssertEqual(Set(resultsAfterFirst.map { $0.item.id }), [items.march.id, items.unrelated.id])
        XCTAssertTrue(resultsAfterFirst.allSatisfy { $0.section == nil })
        XCTAssertFalse(second, "With nothing left to clear, Esc closes the panel")
    }

    @MainActor
    func testTypedUnknownNameAsksAboutUnnamedFaces() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let person = Person(name: nil, embeddings: [[1, 0, 0]])
        let sticker = LibraryItem(
            fileURL: sandbox.file("sticker-1.png"),
            displayName: "New face — happy",
            kind: .friend,
            tier: .meme,
            source: "Friend sticker",
            sourceDetail: "IMG_2207.HEIC",
            addedAt: AppModelTests.march15,
            contentHash: "hash-sticker",
            isSticker: true,
            personID: person.id
        )
        let model = try makeModel(in: sandbox, items: [sticker], people: [person])

        model.panelWillShow(previousApp: nil)
        defer {
            model.panelDidHide()
            model.saveNow()
        }
        model.queryText = "sam"
        let asked = await waitUntil(timeout: AppModelTests.openPanelBudget) { model.naming != nil }
        let naming = model.naming
        let results = model.results

        XCTAssertTrue(asked, "A typed name that matches nothing should ask “Is one of these Sam?”")
        XCTAssertEqual(naming?.name, "Sam")
        XCTAssertEqual(naming?.candidates.map { $0.personID }, [person.id])
        XCTAssertEqual(naming?.candidates.first?.stickerCount, 1)
        XCTAssertEqual(naming?.candidates.first?.sample?.id, sticker.id)
        XCTAssertTrue(results.isEmpty)
    }

    @MainActor
    func testThePoseNamerWarmsOnlyOnceTheCameraIsLive() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let namer = StubPoseNamer()
        namer.isAvailable = true
        let model = try makeModel(in: sandbox, items: [], poseNamer: namer)

        model.panelWillShow(previousApp: nil)
        defer {
            model.panelDidHide()
            model.saveNow()
        }
        let mode = model.mode
        let readout = model.readout

        XCTAssertNotEqual(mode, .live, "the camera goes live with its first frame, never while the panel opens")
        XCTAssertEqual(namer.prewarms, 0, "the model loads once the camera reads you")
        XCTAssertEqual(namer.questions, 0, "nothing is held, so nothing is asked")
        XCTAssertNil(readout)
    }

    @MainActor
    func testADescribedPoseIsSearchedByTheModelsNameOnceItGaveOne() async {
        let namer = StubPoseNamer()
        let flexing = PoseDescription(
            facts: [
                "One arm: at head height, bent sharply, upper arm out to the side, forearm up, beside the head.",
                "The other arm hangs at the side.",
            ],
            phrase: "flexing"
        )

        var words = AppModel.describedWords(for: flexing, namer: namer)
        XCTAssertEqual(words.phrase, "flexing", "without the model, the rule's phrase")
        XCTAssertFalse(words.named)
        XCTAssertFalse(words.waits, "without the model nothing waits")

        namer.isAvailable = true
        words = AppModel.describedWords(for: flexing, namer: namer)
        XCTAssertEqual(words.phrase, "flexing", "the rule's phrase until the model answers")
        XCTAssertFalse(words.named)
        XCTAssertTrue(words.waits, "a pose the model was never asked about waits for its name")

        namer.names[flexing.key] = "gun show"
        let name = await namer.name(flexing)
        XCTAssertEqual(name, "gun show")
        words = AppModel.describedWords(for: flexing, namer: namer)
        XCTAssertEqual(words.phrase, "gun show", "its name is searched at once from then on")
        XCTAssertTrue(words.named)
        XCTAssertFalse(words.waits)
        XCTAssertEqual(namer.questions, 1, "and the model isn't asked again")

        let horns = PoseDescription(facts: ["One hand: index and little fingers straight, the others curled."],
                                    phrase: "rock on")
        let noName = await namer.name(horns)
        XCTAssertNil(noName)
        words = AppModel.describedWords(for: horns, namer: namer)
        XCTAssertEqual(words.phrase, "rock on", "no name keeps the rule's phrase")
        XCTAssertFalse(words.named)
        XCTAssertFalse(words.waits, "and doesn't wait again")

        XCTAssertFalse(MoodReadout(word: "rock on", source: .pose).named, "the rule's phrase shows no sparkles")
        XCTAssertTrue(MoodReadout(word: "gun show", source: .faceAndPose, named: true).named)
    }

    @MainActor
    func testEscapeClearsPinsBeforeClosing() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let model = try makeModel(in: sandbox, items: [])

        model.togglePin(.mouth)
        let pinned = model.pins
        let first = model.handleEscape()
        let pinsAfterFirst = model.pins
        let second = model.handleEscape()

        XCTAssertEqual(pinned, [.mouth])
        XCTAssertTrue(first, "The first Esc clears the pins")
        XCTAssertTrue(pinsAfterFirst.isEmpty)
        XCTAssertFalse(second, "With nothing left to clear, Esc closes the panel")
    }
}
