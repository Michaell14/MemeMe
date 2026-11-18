import CoreGraphics
import Foundation
@testable import MemeMeApp
import MemeMeCore
import XCTest

/// A stand-in for Image Playground: a plain picture (a red disc on white), or the error a test asks for. No test asks
/// the Mac's image model.
@MainActor
final class StubEmojiMaker: EmojiMaking {
    var mayBeAvailable = true
    var onAvailabilityChange: (() -> Void)?
    var error: EmojiMakerError?
    private(set) var asked: [String] = []
    private(set) var prewarms = 0

    func prewarm() {
        prewarms += 1
    }

    func image(for words: String) async throws -> CGImage {
        asked.append(words)
        if let error { throw error }
        return StubEmojiMaker.disc()
    }

    /// Four different discs (so each makes its own sticker), or `error` before any.
    func images(for words: String, count: Int) -> AsyncThrowingStream<CGImage, Error> {
        asked.append(words)
        let error = self.error
        return AsyncThrowingStream { continuation in
            if let error {
                continuation.finish(throwing: error)
                return
            }
            for index in 0..<count {
                continuation.yield(StubEmojiMaker.disc(red: 0.2 + 0.2 * CGFloat(index)))
            }
            continuation.finish()
        }
    }

    static func disc(side: Int = 256, red: CGFloat = 0.9) -> CGImage {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(CGColor(red: red, green: 0.1, blue: 0.1, alpha: 1))
        let inset = CGFloat(side) * 0.2
        context.fillEllipse(in: CGRect(x: inset, y: inset, width: CGFloat(side) - 2 * inset,
                                       height: CGFloat(side) - 2 * inset))
        return context.makeImage()!
    }
}

/// Make emoji: offered for the words typed while your own things show, it saves what Image Playground made as one of
/// your stickers (source "Made"), named after the words, and selects it.
final class MakeEmojiTests: XCTestCase {
    private static let budget: TimeInterval = 5

    @MainActor
    private func makeModel(in sandbox: TestSandbox, maker: StubEmojiMaker) throws -> AppModel {
        let store = try LibraryStore(rootURL: sandbox.url.appendingPathComponent("Library", isDirectory: true))
        var settings = store.settings
        settings.webDiscoverEnabled = false
        settings.hasCompletedFirstRun = true
        settings.libraryOfferAccepted = true
        store.settings = settings
        let model = AppModel(store: store, webCacheRoot: sandbox.url.appendingPathComponent("WebCache", isDirectory: true),
                             emojiMaker: maker)
        model.requestsCameraAccessOnShow = false
        return model
    }

    func testConceptFoldsSpacesAndKeepsItShort() {
        XCTAssertEqual(EmojiMaker.concept(for: "  apple \n  pie "), "apple pie")
        XCTAssertEqual(EmojiMaker.concept(for: "   "), "")
        XCTAssertEqual(EmojiMaker.concept(for: String(repeating: "a", count: 100)).count, 60)
    }

    @MainActor
    func testOfferedForTypedWordsOnlyWhereTheMacMayMakeImages() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let maker = StubEmojiMaker()
        let model = try makeModel(in: sandbox, maker: maker)

        model.panelWillShow(previousApp: nil)
        defer {
            model.panelDidHide()
            model.saveNow()
        }
        XCTAssertEqual(maker.prewarms, 1, "Opening the panel finds out whether images can be made")
        XCTAssertNil(model.emojiOffer, "Nothing typed: nothing to make")

        model.queryText = "apple pie"
        _ = await waitUntil(timeout: MakeEmojiTests.budget) { model.mode == .text }
        XCTAssertEqual(model.emojiOffer, "apple pie")

        maker.mayBeAvailable = false
        XCTAssertNil(model.emojiOffer, "A Mac without Image Playground isn't offered it")
    }

    @MainActor
    func testMakingSavesASelectedStickerNamedAfterTheWords() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let maker = StubEmojiMaker()
        let model = try makeModel(in: sandbox, maker: maker)

        model.panelWillShow(previousApp: nil)
        defer {
            model.panelDidHide()
            model.saveNow()
        }
        model.queryText = "apple pie"
        _ = await waitUntil(timeout: MakeEmojiTests.budget) { model.emojiOffer != nil }

        model.makeEmoji()
        XCTAssertEqual(model.makingEmoji, "apple pie")
        XCTAssertNil(model.emojiOffer, "One at a time")
        let done = await waitUntil(timeout: MakeEmojiTests.budget) { model.makingEmoji == nil }
        XCTAssertTrue(done)

        XCTAssertEqual(maker.asked, ["apple pie"])
        let made = model.store.items.filter { $0.source == "Made" }
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(made.first?.displayName, "Apple pie")
        XCTAssertEqual(made.first?.isSticker, true)
        XCTAssertEqual(made.first?.kind, .mine)
        XCTAssertEqual(model.clipNotice?.itemID, made.first?.id, "The notice offers Rename and Undo")
        XCTAssertEqual(model.newStickerID, made.first?.id)

        model.undoClippedSticker()
        XCTAssertTrue(model.store.items.filter { $0.source == "Made" }.isEmpty, "Undo deletes it")
    }

    @MainActor
    func testTheEmojiSectionOffersIdeasFirstAndKeepsWhatYouMake() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let maker = StubEmojiMaker()
        let model = try makeModel(in: sandbox, maker: maker)

        model.panelWillShow(previousApp: nil)
        defer {
            model.panelDidHide()
            model.saveNow()
        }
        model.selectSource(.emoji)
        XCTAssertEqual(model.searchPlaceholder, "Search your emoji, or describe a new one…")
        XCTAssertTrue(model.layout.picks.isEmpty, "Nothing made yet")
        XCTAssertEqual(model.layout.title, "Your emoji")
        XCTAssertTrue(model.layout.message?.hasPrefix("Make your own emoji") == true)
        XCTAssertEqual(model.emojiStarters, AppModel.emojiStarters)

        model.makeStarterEmoji("proud cat")
        XCTAssertEqual(model.queryText, "proud cat", "The idea is typed in, so the search finds it after")
        XCTAssertEqual(model.makingEmoji, "proud cat")
        XCTAssertEqual(model.emojiCandidateWords, "proud cat")
        XCTAssertTrue(model.emojiStarters.isEmpty, "One at a time")
        let made4 = await waitUntil(timeout: MakeEmojiTests.budget) { model.emojiCandidates.count == 4 }
        XCTAssertTrue(made4, "Four options stream in")
        XCTAssertTrue(model.store.items.filter { $0.source == PickerSource.madeEmojiSource }.isEmpty,
                      "Nothing is kept until you pick")

        let pick = try XCTUnwrap(model.emojiCandidates.first?.id)
        model.keepEmojiCandidate(id: pick)
        XCTAssertNil(model.emojiCandidateWords, "Keeping one closes the strip")
        let done = await waitUntil(timeout: MakeEmojiTests.budget) { model.newStickerID != nil }
        XCTAssertTrue(done)

        XCTAssertEqual(maker.asked, ["proud cat"])
        XCTAssertEqual(model.source, .emoji, "It stays in the Emoji section")
        let made = model.store.items.filter { $0.source == PickerSource.madeEmojiSource }
        XCTAssertEqual(made.map(\.displayName), ["Proud cat"])
        guard case let .meme(first)? = model.layout.picks.first else {
            return XCTFail("The new emoji should be the first tile")
        }
        XCTAssertEqual(first.id, made.first?.id)

        model.queryText = ""
        _ = await waitUntil(timeout: MakeEmojiTests.budget) { model.mode != .text }
        XCTAssertTrue(model.emojiStarters.isEmpty, "Ideas only until the first emoji")
    }

    @MainActor
    func testKeepAllTryAgainAndEscape() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let maker = StubEmojiMaker()
        let model = try makeModel(in: sandbox, maker: maker)

        model.panelWillShow(previousApp: nil)
        defer {
            model.panelDidHide()
            model.saveNow()
        }
        model.selectSource(.emoji)
        model.queryText = "apple pie"
        _ = await waitUntil(timeout: MakeEmojiTests.budget) { model.emojiOffer != nil }
        model.makeEmoji()
        XCTAssertNil(model.emojiOffer, "The strip has its own Try again")
        _ = await waitUntil(timeout: MakeEmojiTests.budget) { model.emojiCandidates.count == 4 }

        // Esc drops them, files included, and keeps nothing.
        let files = model.emojiCandidates.map(\.pngURL)
        XCTAssertTrue(model.handleEscape())
        XCTAssertNil(model.emojiCandidateWords)
        XCTAssertTrue(model.emojiCandidates.isEmpty)
        let gone = await waitUntil(timeout: MakeEmojiTests.budget) {
            files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
        }
        XCTAssertTrue(gone, "Dropped options leave no files")
        XCTAssertTrue(model.store.items.filter { $0.source == PickerSource.madeEmojiSource }.isEmpty)

        // Try again asks once more; Keep all keeps every one.
        _ = await waitUntil(timeout: MakeEmojiTests.budget) { model.emojiOffer != nil }
        model.makeEmoji()
        _ = await waitUntil(timeout: MakeEmojiTests.budget) { model.emojiCandidates.count == 4 }
        model.retryEmojiCandidates()
        _ = await waitUntil(timeout: MakeEmojiTests.budget) { model.emojiCandidates.count == 4 }
        XCTAssertEqual(maker.asked, ["apple pie", "apple pie", "apple pie"])
        model.keepAllEmojiCandidates()
        let kept = await waitUntil(timeout: MakeEmojiTests.budget) {
            model.store.items.filter { $0.source == PickerSource.madeEmojiSource }.count == 4
        }
        XCTAssertTrue(kept, "Keep all keeps the four")
        XCTAssertNil(model.emojiCandidateWords)
        XCTAssertEqual(model.source, .emoji)
    }

    @MainActor
    func testLeavingTheEmojiSectionDropsItsOptions() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let maker = StubEmojiMaker()
        let model = try makeModel(in: sandbox, maker: maker)

        model.panelWillShow(previousApp: nil)
        defer {
            model.panelDidHide()
            model.saveNow()
        }
        model.selectSource(.emoji)
        model.makeStarterEmoji("taco party")
        _ = await waitUntil(timeout: MakeEmojiTests.budget) { model.emojiCandidates.count == 4 }
        model.selectSource(.all)
        XCTAssertNil(model.emojiCandidateWords)
        XCTAssertTrue(model.emojiCandidates.isEmpty)
        XCTAssertNil(model.makingEmoji)
    }

    @MainActor
    func testTheEmojiSectionSaysWhyWithoutImagePlayground() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let maker = StubEmojiMaker()
        maker.mayBeAvailable = false
        let model = try makeModel(in: sandbox, maker: maker)

        model.panelWillShow(previousApp: nil)
        defer {
            model.panelDidHide()
            model.saveNow()
        }
        model.selectSource(.emoji)
        XCTAssertEqual(model.searchPlaceholder, "Search your emoji…")
        XCTAssertEqual(model.layout.message,
                       "Emoji are made with Image Playground, which needs Apple Intelligence on this Mac.")
        XCTAssertTrue(model.emojiStarters.isEmpty)
    }

    @MainActor
    func testARefusalSavesNothing() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let maker = StubEmojiMaker()
        maker.error = .refused
        let model = try makeModel(in: sandbox, maker: maker)

        model.panelWillShow(previousApp: nil)
        defer {
            model.panelDidHide()
            model.saveNow()
        }
        model.queryText = "someone famous"
        _ = await waitUntil(timeout: MakeEmojiTests.budget) { model.emojiOffer != nil }

        model.makeEmoji()
        let done = await waitUntil(timeout: MakeEmojiTests.budget) { model.makingEmoji == nil }
        XCTAssertTrue(done)
        XCTAssertTrue(model.store.items.filter { $0.source == "Made" }.isEmpty)
        XCTAssertNil(model.clipNotice)
        XCTAssertEqual(model.emojiOffer, "someone famous", "It can be tried again")

        // In the Emoji section the strip goes too, with nothing kept.
        model.selectSource(.emoji)
        _ = await waitUntil(timeout: MakeEmojiTests.budget) { model.emojiOffer != nil }
        model.makeEmoji()
        let gone = await waitUntil(timeout: MakeEmojiTests.budget) { model.emojiCandidateWords == nil }
        XCTAssertTrue(gone)
        XCTAssertNil(model.makingEmoji)
        XCTAssertTrue(model.store.items.filter { $0.source == "Made" }.isEmpty)
    }
}
