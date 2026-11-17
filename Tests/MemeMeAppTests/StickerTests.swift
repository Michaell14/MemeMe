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

/// The screen cut's drawing takes the subjects it covers, not exactly what was drawn.
final class ScreenDrawingTests: XCTestCase {
    /// A 100 × 100 instance mask: subject 1 in the box (10…29, 10…29), subject 2 in (60…89, 60…89).
    private let size = 100
    private lazy var labels: [UInt8] = {
        var labels = [UInt8](repeating: 0, count: size * size)
        for y in 10..<30 { for x in 10..<30 { labels[y * size + x] = 1 } }
        for y in 60..<90 { for x in 60..<90 { labels[y * size + x] = 2 } }
        return labels
    }()

    private func covered(_ points: [CGPoint], pen: CGFloat = 0.02) -> IndexSet {
        ScreenSubjects.instances(in: labels, width: size, height: size, coveredBy: points, penWidth: pen)
    }

    func testALoopAroundASubjectTakesAllOfIt() {
        let loop = [CGPoint(x: 0.05, y: 0.05), CGPoint(x: 0.35, y: 0.05), CGPoint(x: 0.35, y: 0.35),
                    CGPoint(x: 0.05, y: 0.35), CGPoint(x: 0.05, y: 0.06)]
        XCTAssertEqual(covered(loop), IndexSet(integer: 1))
    }

    func testALooseLoopThatGrazesANeighbourLeavesItOut() {
        // Around subject 1, its far corner just reaching the edge of subject 2.
        let loop = [CGPoint(x: 0.05, y: 0.05), CGPoint(x: 0.62, y: 0.05), CGPoint(x: 0.62, y: 0.62),
                    CGPoint(x: 0.05, y: 0.62)]
        XCTAssertEqual(covered(loop), IndexSet(integer: 1))
    }

    func testAScribbleAcrossASubjectReachesIt() {
        let scribble = [CGPoint(x: 0.6, y: 0.62), CGPoint(x: 0.9, y: 0.65), CGPoint(x: 0.6, y: 0.70),
                        CGPoint(x: 0.9, y: 0.75), CGPoint(x: 0.6, y: 0.80), CGPoint(x: 0.9, y: 0.85)]
        XCTAssertEqual(covered(scribble, pen: 0.05), IndexSet(integer: 2))
    }

    func testOneLoopAroundBothTakesBoth() {
        let loop = [CGPoint(x: 0.02, y: 0.02), CGPoint(x: 0.98, y: 0.02), CGPoint(x: 0.98, y: 0.98),
                    CGPoint(x: 0.02, y: 0.98)]
        XCTAssertEqual(covered(loop), IndexSet([1, 2]))
    }

    func testADrawingOverTheBackgroundTakesNothing() {
        let line = [CGPoint(x: 0.4, y: 0.1), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.4, y: 0.9)]
        XCTAssertTrue(covered(line).isEmpty)
        XCTAssertTrue(covered([CGPoint(x: 0.2, y: 0.2)]).isEmpty, "a single point is a click, not a drawing")
    }
}
