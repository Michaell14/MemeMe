import Foundation
import XCTest
@testable import MemeMeCore

final class LibraryItemTests: XCTestCase {
    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// An item with every optional field set.
    private func fullItem() -> LibraryItem {
        LibraryItem(id: UUID(),
                    fileURL: URL(fileURLWithPath: "/Users/me/Downloads/shocked-cat.gif"),
                    displayName: "Shocked cat",
                    kind: .mine,
                    tier: .maybe,
                    source: "Downloads",
                    sourceDetail: "from reddit.com",
                    addedAt: TestDates.march20,
                    fileModifiedAt: TestDates.march15,
                    fileSize: 123_456,
                    contentHash: "abc123",
                    isSticker: false,
                    isAnimated: true,
                    face: TestFaces.surprise,
                    pose: PoseFeatures(handsRaised: 0.5, armsSpread: 0.25, bodyVisible: 1),
                    intensity: 0.5,
                    featurePrint: [0.25, -1, 3.5],
                    featurePrintRevision: 2,
                    text: "OMG",
                    labels: ["cat", "animal"],
                    personID: UUID(),
                    faceEmbedding: [1, 2],
                    remoteURL: URL(string: "https://media.giphy.com/media/abc/downsized.gif"),
                    previewURL: URL(string: "https://media.giphy.com/media/abc/200w.gif"),
                    attribution: "via GIPHY",
                    timesSent: 3,
                    lastSentAt: TestDates.september5,
                    faceShape: FaceShape(leftEyeOpen: 0.25, rightEyeOpen: 0.05, lipWidth: 0.75, tongue: 0.5),
                    faceRevision: LibraryItem.currentFaceRevision)
    }

    private func jsonObject(_ item: LibraryItem) throws -> [String: Any] {
        let data = try makeEncoder().encode(item)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testInitializerDefaults() {
        let item = LibraryItem(fileURL: URL(fileURLWithPath: "/tmp/a.png"), displayName: "a", kind: .mine, source: "Desktop", contentHash: "h")
        XCTAssertEqual(item.tier, .meme)
        XCTAssertNil(item.sourceDetail)
        XCTAssertEqual(item.fileSize, 0)
        XCTAssertFalse(item.isSticker)
        XCTAssertFalse(item.isAnimated)
        XCTAssertNil(item.face)
        XCTAssertNil(item.faceShape)
        XCTAssertEqual(item.faceRevision, 0)
        XCTAssertEqual(item.intensity, 0)
        XCTAssertEqual(item.featurePrintRevision, 0)
        XCTAssertEqual(item.text, "")
        XCTAssertEqual(item.labels, [])
        XCTAssertEqual(item.timesSent, 0)
        XCTAssertNil(item.lastSentAt)
    }

    func testJSONRoundTripPreservesEveryField() throws {
        let item = fullItem()
        let data = try makeEncoder().encode(item)
        XCTAssertEqual(try makeDecoder().decode(LibraryItem.self, from: data), item)
    }

    func testFloatVectorsAreStoredAsBase64Strings() throws {
        let object = try jsonObject(fullItem())
        XCTAssertEqual(object["featurePrint"] as? String, FloatCoding.encode([0.25, -1, 3.5]))
        XCTAssertEqual(object["faceEmbedding"] as? String, FloatCoding.encode([1, 2]))
        XCTAssertEqual(object["kind"] as? String, "mine")
        XCTAssertEqual(object["tier"] as? String, "maybe")
        XCTAssertEqual(object["addedAt"] as? String, "2026-03-20T09:00:00Z")
        XCTAssertEqual(object["fileModifiedAt"] as? String, "2026-03-15T12:00:00Z")
    }

    func testNilOptionalsAreOmitted() throws {
        let object = try jsonObject(makeItem(name: "plain"))
        for key in ["sourceDetail", "fileModifiedAt", "face", "faceShape", "pose", "featurePrint", "personID",
                    "faceEmbedding", "remoteURL", "previewURL", "attribution", "lastSentAt"] {
            XCTAssertNil(object[key], key)
        }
        XCTAssertNotNil(object["timesSent"])
        XCTAssertEqual(object["faceRevision"] as? Int, 0)
    }

    func testFaceShapeAndRevisionAreStored() throws {
        let item = fullItem()
        let object = try jsonObject(item)
        let shape = try XCTUnwrap(object["faceShape"] as? [String: Any])
        XCTAssertEqual(shape["tongue"] as? Double, 0.5)
        XCTAssertEqual(shape["lipWidth"] as? Double, 0.75)
        XCTAssertNil(shape["gazeUp"])
        XCTAssertEqual(object["faceRevision"] as? Int, LibraryItem.currentFaceRevision)

        let decoded = try makeDecoder().decode(LibraryItem.self, from: makeEncoder().encode(item))
        XCTAssertEqual(decoded.faceShape, FaceShape(leftEyeOpen: 0.25, rightEyeOpen: 0.05, lipWidth: 0.75, tongue: 0.5))
        XCTAssertEqual(decoded.faceRevision, 1)
    }

    func testItemsFromBeforeFaceShapesDecodeWithout() throws {
        // Stored by an earlier version: a face, no shape, no revision.
        let old = """
        {"id": "\(UUID().uuidString)", "fileURL": "file:///tmp/a.png", "contentHash": "h",
         "face": {"browRaise": 0.5, "eyeOpenness": 0.5, "mouthOpenness": 0, "mouthWidth": 0.5, "smile": 0.5,
                  "headTilt": 0, "gazeSide": 0}}
        """
        let item = try makeDecoder().decode(LibraryItem.self, from: Data(old.utf8))
        XCTAssertNotNil(item.face)
        XCTAssertNil(item.faceShape)
        XCTAssertEqual(item.faceRevision, 0)

        // Damaged: a shape that isn't one and a revision that isn't a number fall back; a shape's field of the wrong
        // type only drops that field.
        let damaged = """
        {"id": "\(UUID().uuidString)", "fileURL": "file:///tmp/a.png", "contentHash": "h",
         "faceShape": "x", "faceRevision": "one"}
        """
        let broken = try makeDecoder().decode(LibraryItem.self, from: Data(damaged.utf8))
        XCTAssertNil(broken.faceShape)
        XCTAssertEqual(broken.faceRevision, 0)
        let partly = """
        {"id": "\(UUID().uuidString)", "fileURL": "file:///tmp/a.png", "contentHash": "h",
         "faceShape": {"tongue": "x", "lipWidth": 0.75}, "faceRevision": 1}
        """
        let partial = try makeDecoder().decode(LibraryItem.self, from: Data(partly.utf8))
        XCTAssertEqual(partial.faceShape, FaceShape(lipWidth: 0.75))
        XCTAssertEqual(partial.faceRevision, 1)
    }

    func testDecodingMinimalJSONUsesDefaults() throws {
        let id = UUID()
        let json = #"{"id": "\#(id.uuidString)", "fileURL": "file:///tmp/Funny%20dog.png", "contentHash": "h1"}"#
        let item = try makeDecoder().decode(LibraryItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.fileURL.path, "/tmp/Funny dog.png")
        XCTAssertEqual(item.contentHash, "h1")
        XCTAssertEqual(item.displayName, "Funny dog")
        XCTAssertEqual(item.kind, .mine)
        XCTAssertEqual(item.tier, .meme)
        XCTAssertEqual(item.source, "")
        XCTAssertNil(item.sourceDetail)
        XCTAssertEqual(item.addedAt, Date(timeIntervalSince1970: 0))
        XCTAssertNil(item.fileModifiedAt)
        XCTAssertEqual(item.fileSize, 0)
        XCTAssertFalse(item.isSticker)
        XCTAssertFalse(item.isAnimated)
        XCTAssertNil(item.face)
        XCTAssertNil(item.faceShape)
        XCTAssertEqual(item.faceRevision, 0)
        XCTAssertNil(item.pose)
        XCTAssertEqual(item.intensity, 0)
        XCTAssertNil(item.featurePrint)
        XCTAssertEqual(item.featurePrintRevision, 0)
        XCTAssertEqual(item.text, "")
        XCTAssertEqual(item.labels, [])
        XCTAssertNil(item.personID)
        XCTAssertNil(item.faceEmbedding)
        XCTAssertNil(item.remoteURL)
        XCTAssertNil(item.previewURL)
        XCTAssertNil(item.attribution)
        XCTAssertEqual(item.timesSent, 0)
        XCTAssertNil(item.lastSentAt)
    }

    func testMissingAddedAtFallsBackToModificationDate() throws {
        let json = #"{"id": "\#(UUID().uuidString)", "fileURL": "file:///tmp/a.png", "contentHash": "h", "fileModifiedAt": "2026-02-10T08:00:00Z"}"#
        let item = try makeDecoder().decode(LibraryItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.fileModifiedAt, TestDates.february10)
        XCTAssertEqual(item.addedAt, TestDates.february10)
    }

    func testDecodingToleratesWrongTypesAndLegacyArrays() throws {
        let json = """
        {"id": "\(UUID().uuidString)", "fileURL": "file:///tmp/a.png", "contentHash": "h2",
         "tier": "someday", "timesSent": "three", "featurePrint": [1.0, 2.5], "labels": "cat",
         "addedAt": "2026-03-15T12:00:00Z", "fileModifiedAt": "not a date", "face": {"smile": 1}}
        """
        let item = try makeDecoder().decode(LibraryItem.self, from: Data(json.utf8))
        let expectedPrint: [Float] = [1.0, 2.5]
        XCTAssertEqual(item.tier, .meme)
        XCTAssertEqual(item.timesSent, 0)
        XCTAssertEqual(item.featurePrint, expectedPrint)
        XCTAssertEqual(item.labels, [])
        XCTAssertEqual(item.addedAt, TestDates.march15)
        XCTAssertNil(item.fileModifiedAt)
        XCTAssertNil(item.face)
    }

    func testDecodingRequiresIdentityKeys() {
        let noID = #"{"fileURL": "file:///tmp/a.png", "contentHash": "h"}"#
        let noURL = #"{"id": "\#(UUID().uuidString)", "contentHash": "h"}"#
        let noHash = #"{"id": "\#(UUID().uuidString)", "fileURL": "file:///tmp/a.png"}"#
        for json in [noID, noURL, noHash] {
            XCTAssertThrowsError(try makeDecoder().decode(LibraryItem.self, from: Data(json.utf8)), json)
        }
    }

    func testIsOwn() {
        XCTAssertTrue(makeItem(kind: .mine).isOwn)
        XCTAssertTrue(makeItem(kind: .friend).isOwn)
        XCTAssertFalse(makeItem(kind: .pack).isOwn)
        XCTAssertFalse(makeItem(kind: .web).isOwn)
    }

    func testMonthKeyUsesUTCAndPrefersTheModificationDate() {
        XCTAssertEqual(makeItem(addedAt: TestDates.march15).monthKey, "March 2026")
        XCTAssertEqual(makeItem(addedAt: TestDates.september5, modified: TestDates.february10).monthKey, "February 2026")
        XCTAssertEqual(makeItem(addedAt: TestDates.march31Late).monthKey, "March 2026")
        XCTAssertEqual(makeItem(addedAt: TestDates.april1Early).monthKey, "April 2026")
        XCTAssertEqual(makeItem(addedAt: TestDates.newYearsEve2025).monthKey, "December 2025")
        XCTAssertEqual(makeItem(addedAt: TestDates.september5).monthKey, "September 2026")
    }

    func testProvenance() {
        let own = makeItem(source: "Downloads", sourceDetail: "from reddit.com", addedAt: TestDates.september5, modified: TestDates.march15)
        XCTAssertEqual(own.provenance, "Downloads · from reddit.com · Mar 2026")

        let plain = makeItem(source: "Desktop", addedAt: TestDates.february10)
        XCTAssertEqual(plain.provenance, "Desktop · Feb 2026")

        let sticker = makeItem(kind: .friend, source: "Friend sticker", sourceDetail: "IMG_2207.HEIC",
                               addedAt: TestDates.september5, isSticker: true)
        XCTAssertEqual(sticker.provenance, "Friend sticker · Sep 2026")

        let web = makeItem(kind: .web, source: "GIPHY", attribution: "via GIPHY")
        XCTAssertEqual(web.provenance, "via GIPHY")
        XCTAssertEqual(makeItem(kind: .web, source: "GIPHY").provenance, "via GIPHY")
    }
}
