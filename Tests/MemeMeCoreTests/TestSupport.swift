import Foundation
import XCTest
@testable import MemeMeCore

/// Population-neutral face with selected fields changed.
func makeFace(brow: Double = 0.45, eye: Double = 0.45, mouth: Double = 0.05, width: Double = 0.45,
              smile: Double = 0.5, tilt: Double = 0, gaze: Double = 0.1) -> FaceFeatures {
    FaceFeatures(browRaise: brow, eyeOpenness: eye, mouthOpenness: mouth, mouthWidth: width,
                 smile: smile, headTilt: tilt, gazeSide: gaze)
}

/// Handcrafted faces. Intensities are against the population neutral.
enum TestFaces {
    static let neutral = FaceFeatures.populationNeutral
    /// Raised brows, wide eyes, open mouth (deviation +0.2, +0.2, +0.6); intensity ≈ 0.5014.
    static let surprise = makeFace(brow: 0.65, eye: 0.65, mouth: 0.65)
    /// 1.5 × the surprise deviation; intensity ≈ 0.7521.
    static let strongSurprise = makeFace(brow: 0.75, eye: 0.75, mouth: 0.95)
    /// 1.1 × the surprise deviation: same direction, not 15 % stronger.
    static let slightlyStrongerSurprise = makeFace(brow: 0.67, eye: 0.67, mouth: 0.71)
    /// 0.5 × the surprise deviation; intensity ≈ 0.2507.
    static let mildSurprise = makeFace(brow: 0.55, eye: 0.55, mouth: 0.35)
    /// Wide smile (mouthWidth +0.3, smile +0.4), orthogonal to surprise; intensity ≈ 0.3780.
    static let smile = makeFace(width: 0.75, smile: 0.9)
}

/// Whole-second UTC dates (ISO-8601 JSON keeps seconds only).
enum TestDates {
    static let january20 = Date(timeIntervalSince1970: 1_768_903_200)      // 2026-01-20T10:00:00Z
    static let february10 = Date(timeIntervalSince1970: 1_770_710_400)     // 2026-02-10T08:00:00Z
    static let march2 = Date(timeIntervalSince1970: 1_772_442_000)         // 2026-03-02T09:00:00Z
    static let march15 = Date(timeIntervalSince1970: 1_773_576_000)        // 2026-03-15T12:00:00Z
    static let march20 = Date(timeIntervalSince1970: 1_773_997_200)        // 2026-03-20T09:00:00Z
    static let march31Late = Date(timeIntervalSince1970: 1_774_999_800)    // 2026-03-31T23:30:00Z
    static let april1Early = Date(timeIntervalSince1970: 1_775_003_400)    // 2026-04-01T00:30:00Z
    static let september5 = Date(timeIntervalSince1970: 1_788_609_600)     // 2026-09-05T12:00:00Z
    static let newYearsEve2025 = Date(timeIntervalSince1970: 1_767_225_599) // 2025-12-31T23:59:59Z
}

/// A library item with test-friendly defaults. Arguments must be passed in this declaration order.
func makeItem(id: UUID = UUID(),
              name: String = "item",
              kind: ItemKind = .mine,
              tier: ItemTier = .meme,
              source: String = "Downloads",
              sourceDetail: String? = nil,
              addedAt: Date = TestDates.march15,
              modified: Date? = nil,
              hash: String? = nil,
              isSticker: Bool = false,
              isAnimated: Bool = false,
              face: FaceFeatures? = nil,
              pose: PoseFeatures? = nil,
              intensity: Double = 0,
              featurePrint: [Float]? = nil,
              text: String = "",
              labels: [String] = [],
              personID: UUID? = nil,
              attribution: String? = nil,
              timesSent: Int = 0,
              lastSentAt: Date? = nil,
              fileURL: URL? = nil) -> LibraryItem {
    LibraryItem(id: id,
                fileURL: fileURL ?? URL(fileURLWithPath: "/tmp/mememe-tests/\(id.uuidString).png"),
                displayName: name,
                kind: kind,
                tier: tier,
                source: source,
                sourceDetail: sourceDetail,
                addedAt: addedAt,
                fileModifiedAt: modified,
                contentHash: hash ?? "hash-\(id.uuidString)",
                isSticker: isSticker,
                isAnimated: isAnimated,
                face: face,
                pose: pose,
                intensity: intensity,
                featurePrint: featurePrint,
                text: text,
                labels: labels,
                personID: personID,
                attribution: attribution,
                timesSent: timesSent,
                lastSentAt: lastSentAt)
}

/// Element-wise comparison with a tolerance.
func assertVectorsEqual(_ actual: [Double], _ expected: [Double], accuracy: Double = 1e-9,
                        file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual.count, expected.count, "vector length", file: file, line: line)
    for (index, pair) in zip(actual, expected).enumerated() {
        XCTAssertEqual(pair.0, pair.1, accuracy: accuracy, "index \(index)", file: file, line: line)
    }
}
