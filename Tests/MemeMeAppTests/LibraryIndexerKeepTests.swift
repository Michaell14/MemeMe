import Foundation
@testable import MemeMeApp
import MemeMeCore
import XCTest

/// Hand-ins ("Keep it", menu-bar drops): copied into Kept, deduplicated by content, undoable.
/// Keeping analyzes each image with Vision; a failed analysis counts as `skipped`.
final class LibraryIndexerKeepTests: XCTestCase {
    @MainActor
    func testKeepCopiesIntoKeptDedupesAndUndoRemovesItemAndFile() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let inbox = try sandbox.directory("Inbox")
        let original = inbox.appendingPathComponent("no-way.png", isDirectory: false)
        try TestImages.writePNG(try TestImages.shapes(seed: 1), to: original)
        let originalBytes = try Data(contentsOf: original)

        let store = try LibraryStore(rootURL: sandbox.url.appendingPathComponent("Library", isDirectory: true))
        let indexer = LibraryIndexer(store: store)

        // First hand-in: one item, copied into Kept.
        let first = await indexer.keep(urls: [original], source: "Kept")
        XCTAssertEqual(first.addedIDs.count, 1, "Keeping a readable PNG adds one item (skipped \(first.skipped): did Vision analysis fail?)")
        XCTAssertEqual(first.skipped, 0)
        XCTAssertEqual(first.duplicates, 0)
        XCTAssertEqual(first.sources, ["Kept"])

        let itemID = try XCTUnwrap(first.addedIDs.first)
        let item = try XCTUnwrap(store.item(id: itemID))
        XCTAssertEqual(item.kind, .mine)
        XCTAssertEqual(item.source, "Kept")
        XCTAssertEqual(item.displayName, "no-way")
        XCTAssertNotEqual(item.tier, .skipped, "Hand-ins are always findable by words")
        XCTAssertEqual(item.contentHash, ImageAnalyzer.sha256Hex(originalBytes))
        XCTAssertEqual(item.fileSize, Int64(originalBytes.count))
        XCTAssertFalse(item.isAnimated)
        XCTAssertEqual(item.faceRevision, LibraryItem.currentFaceRevision, "a new item's face is read the current way")
        XCTAssertEqual(item.poseRevision, LibraryItem.currentPoseRevision)
        XCTAssertEqual(
            item.fileURL.deletingLastPathComponent().standardizedFileURL.path,
            store.keptDirectory.standardizedFileURL.path,
            "Kept files live in the library's Kept folder"
        )
        XCTAssertEqual(try Data(contentsOf: item.fileURL), originalBytes, "Kept holds a byte-for-byte copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "The handed-in file is copied, never moved")
        XCTAssertEqual(visibleFileNames(in: store.keptDirectory), [item.fileURL.lastPathComponent])

        // Saved right away: a fresh store sees the item.
        let reloaded = try LibraryStore(rootURL: store.rootURL)
        XCTAssertEqual(reloaded.items.map { $0.id }, [itemID])

        // The same file again: a duplicate, nothing new in Kept.
        let second = await indexer.keep(urls: [original], source: "Kept")
        XCTAssertEqual(second.addedIDs, [])
        XCTAssertEqual(second.duplicates, 1)
        XCTAssertEqual(second.skipped, 0)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(visibleFileNames(in: store.keptDirectory), [item.fileURL.lastPathComponent])

        // Undo removes the item and its Kept copy, never the original.
        indexer.undo(first)
        XCTAssertNil(store.item(id: itemID))
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.fileURL.path))
        XCTAssertEqual(visibleFileNames(in: store.keptDirectory), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "Undo never touches the original")
        XCTAssertFalse(store.contains(hash: item.contentHash))

        // After undo the same image can be kept again.
        let again = await indexer.keep(urls: [original], source: "Kept")
        XCTAssertEqual(again.addedIDs.count, 1)
        XCTAssertEqual(again.duplicates, 0)
    }

    @MainActor
    func testTheFacePassReadsYourMemesAndStickersBehindTheFaceRevision() {
        func item(_ kind: ItemKind, tier: ItemTier = .meme, faceRevision: Int = 0) -> LibraryItem {
            LibraryItem(fileURL: URL(fileURLWithPath: "/tmp/face.png"), displayName: "face", kind: kind, tier: tier,
                        source: "Downloads", contentHash: "hash", faceRevision: faceRevision)
        }
        XCTAssertTrue(LibraryIndexer.needsFaceRefresh(item(.mine)))
        XCTAssertTrue(LibraryIndexer.needsFaceRefresh(item(.mine, tier: .maybe)))
        XCTAssertTrue(LibraryIndexer.needsFaceRefresh(item(.friend)), "stickers are read again too")
        XCTAssertFalse(LibraryIndexer.needsFaceRefresh(item(.mine, tier: .skipped)), "skipped files keep no face")
        XCTAssertFalse(LibraryIndexer.needsFaceRefresh(item(.web)))
        XCTAssertFalse(LibraryIndexer.needsFaceRefresh(item(.pack)))
        XCTAssertFalse(LibraryIndexer.needsFaceRefresh(item(.mine, faceRevision: LibraryItem.currentFaceRevision)))
        XCTAssertFalse(LibraryIndexer.needsFaceRefresh(item(.friend, faceRevision: LibraryItem.currentFaceRevision)))
    }

    func testTheFacePassNeverTradesAFaceForNone() {
        let old = FaceFeatures(browRaise: 0.6, eyeOpenness: 0.5, mouthOpenness: 0.3, mouthWidth: 0.5, smile: 0.7,
                               headTilt: 0, gazeSide: 0.1)
        let new = FaceFeatures.populationNeutral
        let shape = FaceShape(lipWidth: 0.8, tongue: 0.4)
        var meme = LibraryItem(fileURL: URL(fileURLWithPath: "/tmp/face.png"), displayName: "face", kind: .mine,
                               source: "Downloads", contentHash: "hash", face: old, intensity: 0.4)

        // A meme read afresh takes the new face, shape and intensity.
        let reread = LibraryIndexer.applyingFaceReading(meme, face: new, shape: shape, intensity: 0.1)
        XCTAssertEqual(reread.face, new)
        XCTAssertEqual(reread.faceShape, shape)
        XCTAssertEqual(reread.intensity, 0.1)
        XCTAssertEqual(reread.faceRevision, LibraryItem.currentFaceRevision)

        // No face found this time: the old face stays.
        let missed = LibraryIndexer.applyingFaceReading(meme, face: nil, shape: nil, intensity: 0)
        XCTAssertEqual(missed.face, old)
        XCTAssertEqual(missed.intensity, 0.4)
        XCTAssertNil(missed.faceShape)
        XCTAssertEqual(missed.faceRevision, LibraryItem.currentFaceRevision)

        // A sticker keeps the face read on its source photo and takes only the shape of its cut-out.
        meme.isSticker = true
        let sticker = LibraryIndexer.applyingFaceReading(meme, face: new, shape: shape, intensity: 0.1)
        XCTAssertEqual(sticker.face, old)
        XCTAssertEqual(sticker.intensity, 0.4)
        XCTAssertEqual(sticker.faceShape, shape)
        XCTAssertEqual(sticker.faceRevision, LibraryItem.currentFaceRevision)
    }

    @MainActor
    func testAKeptFileDeletedInFinderIsForgottenBeforeItsNameIsReused() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let first = try sandbox.directory("First").appendingPathComponent("pasted.png", isDirectory: false)
        let second = try sandbox.directory("Second").appendingPathComponent("pasted.png", isDirectory: false)
        try TestImages.writePNG(try TestImages.shapes(seed: 3), to: first)
        try TestImages.writePNG(try TestImages.shapes(seed: 4), to: second)
        let store = try LibraryStore(rootURL: sandbox.url.appendingPathComponent("Library", isDirectory: true))
        let indexer = LibraryIndexer(store: store)

        let kept = await indexer.keep(urls: [first], source: "Kept")
        let oldID = try XCTUnwrap(kept.addedIDs.first)
        let oldFile = try XCTUnwrap(store.item(id: oldID)?.fileURL)
        try FileManager.default.removeItem(at: oldFile)

        // The next "pasted.png" may take the freed name; the deleted one's item is gone, not pointing at it.
        let next = await indexer.keep(urls: [second], source: "Kept")
        let newID = try XCTUnwrap(next.addedIDs.first)
        XCTAssertNil(store.item(id: oldID))
        XCTAssertEqual(store.items.map(\.id), [newID])
        XCTAssertEqual(indexer.removeItemsWithMissingFiles(), 0)

        // Deleted again while MemeMe runs: forgotten on the next check, and saved.
        try FileManager.default.removeItem(at: try XCTUnwrap(store.item(id: newID)?.fileURL))
        XCTAssertEqual(indexer.removeItemsWithMissingFiles(), 1)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(try LibraryStore(rootURL: store.rootURL).items.isEmpty)
    }

    @MainActor
    func testOneDropWithTheSameFileTwiceKeepsOneCopyAndSkipsNonImages() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let inbox = try sandbox.directory("Inbox")
        let image = inbox.appendingPathComponent("reaction.png", isDirectory: false)
        try TestImages.writePNG(try TestImages.shapes(seed: 2), to: image)
        let notes = inbox.appendingPathComponent("notes.txt", isDirectory: false)
        try Data("shopping list".utf8).write(to: notes)

        let store = try LibraryStore(rootURL: sandbox.url.appendingPathComponent("Library", isDirectory: true))
        let indexer = LibraryIndexer(store: store)

        let batch = await indexer.keep(urls: [image, image, notes], source: "Kept")

        XCTAssertEqual(batch.addedIDs.count, 1, "skipped \(batch.skipped): did Vision analysis fail?")
        XCTAssertEqual(batch.duplicates, 1, "The second copy in the same drop is merged")
        XCTAssertEqual(batch.skipped, 1, "A text file is not an image")
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(
            visibleFileNames(in: store.keptDirectory),
            store.items.map { $0.fileURL.lastPathComponent },
            "The extra copy written for the duplicate is deleted"
        )

        indexer.undo(batch)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(visibleFileNames(in: store.keptDirectory), [])
    }

    @MainActor
    func testKeepingNothingAddsNothing() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let store = try LibraryStore(rootURL: sandbox.url.appendingPathComponent("Library", isDirectory: true))
        let indexer = LibraryIndexer(store: store)

        let batch = await indexer.keep(urls: [], source: "Kept")

        XCTAssertEqual(batch.addedIDs, [])
        XCTAssertEqual(batch.duplicates, 0)
        XCTAssertEqual(batch.skipped, 0)
        XCTAssertTrue(store.items.isEmpty)
    }
}
