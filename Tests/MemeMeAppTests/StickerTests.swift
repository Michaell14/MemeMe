import CoreGraphics
import Foundation
@testable import MemeMeApp
import MemeMeCore
import XCTest

/// Photos without people never become stickers. These tests run Vision face detection on a generated landscape.
final class StickerTests: XCTestCase {
    private func writeLandscape(in sandbox: TestSandbox) throws -> URL {
        let url = sandbox.file("IMG_0420.png")
        try TestImages.writePNG(try TestImages.landscape(), to: url)
        return url
    }

    func testLandscapeHasNoEligibleFaces() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let url = try writeLandscape(in: sandbox)

        let result: (facts: ImageFacts, faces: [CGRect])
        do {
            result = try StickerMaker.eligibleFaces(in: url)
        } catch {
            XCTFail("StickerMaker.eligibleFaces threw: \(error). This test needs Vision face detection on the test machine.")
            throw error
        }

        XCTAssertTrue(result.faces.isEmpty, "A landscape is not a photo of people")
        XCTAssertEqual(result.facts.faceCount, 0)
        XCTAssertFalse(result.facts.isAnimated)
        XCTAssertEqual(result.facts.pixelWidth, 640)
        XCTAssertEqual(result.facts.pixelHeight, 427)
    }

    func testMakeStickersWithoutFacesWritesNothing() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let url = try writeLandscape(in: sandbox)
        let directory = sandbox.url.appendingPathComponent("Stickers", isDirectory: true)

        let cuts = try StickerMaker.makeStickers(from: url, into: directory, faces: [])

        XCTAssertTrue(cuts.isEmpty)
        XCTAssertEqual(visibleFileNames(in: directory), [])
    }

    @MainActor
    func testFriendServiceKeepsALandscapeAsAMeme() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let url = try writeLandscape(in: sandbox)
        let store = try LibraryStore(rootURL: sandbox.url.appendingPathComponent("Library", isDirectory: true))
        let service = FriendService(store: store)
        let policy = store.settings.stickerPolicy
        XCTAssertEqual(policy, .automatic)

        let batch: StickerBatch?
        do {
            batch = try await service.process(photo: url)
        } catch {
            XCTFail("FriendService.process threw: \(error). This test needs Vision face detection on the test machine.")
            throw error
        }

        XCTAssertNil(batch, "No people → nil, so the caller keeps the file as a meme")
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.people.isEmpty)
        XCTAssertEqual(visibleFileNames(in: store.stickersDirectory), [])
    }

    @MainActor
    func testFriendServiceMakesNothingWhenThePolicyIsNever() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let url = try writeLandscape(in: sandbox)
        let store = try LibraryStore(rootURL: sandbox.url.appendingPathComponent("Library", isDirectory: true))
        var settings = store.settings
        settings.stickerPolicy = .never
        store.settings = settings
        let service = FriendService(store: store)
        let needsConsent = service.needsGroupingConsent

        let batch = try await service.process(photo: url)

        XCTAssertNil(batch)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(needsConsent, "Grouping consent has not been asked yet on a fresh library")
    }
}
