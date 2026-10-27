import Foundation
@testable import MemeMeApp
import MemeMeCore
import XCTest

/// AppModel can be built headless: its init only creates the camera controller (an AVCaptureSession that is not
/// started), the indexer, web discovery and the friend service. Web discovery is switched off in these stores and
/// its cache lives in the test's temporary folder, so no network and no web cache on this Mac take part.
///
/// `panelWillShow` would ask for camera access 0.6 s after opening when access is undecided (activating the app for
/// the system prompt); `requestsCameraAccessOnShow = false` turns that off, so the checks don't depend on timing.
final class AppModelTests: XCTestCase {
    /// How long a test waits for the panel to react (the text search is debounced by 80 ms).
    private static let openPanelBudget: TimeInterval = 2

    /// Whole-second UTC dates in the middle of their months.
    private static let january20 = Date(timeIntervalSince1970: 1_768_903_200)    // 2026-01-20T10:00:00Z
    private static let february10 = Date(timeIntervalSince1970: 1_770_710_400)   // 2026-02-10T08:00:00Z
    private static let march15 = Date(timeIntervalSince1970: 1_773_576_000)      // 2026-03-15T12:00:00Z

    @MainActor
    private func makeModel(in sandbox: TestSandbox, items: [LibraryItem], people: [Person] = []) throws -> AppModel {
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
        let model = AppModel(store: store, webCacheRoot: sandbox.url.appendingPathComponent("WebCache", isDirectory: true))
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
