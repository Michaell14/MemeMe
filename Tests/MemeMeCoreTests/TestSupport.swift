import Foundation
import XCTest
@testable import MemeMeCore

/// XCTest on macOS re-exports DeveloperToolsSupport, which also declares a `LibraryItem`.
/// This module-level alias shadows it for every test file.
typealias LibraryItem = MemeMeCore.LibraryItem

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

/// An arm in shoulder widths from the middle of the shoulders (x toward the person's left, y up); nil = not seen.
struct TestArm {
    var elbow: (x: Double, y: Double)?
    var wrist: (x: Double, y: Double)?

    /// The same arm on the other side.
    var otherSide: TestArm {
        TestArm(elbow: elbow.map { (x: -$0.x, y: $0.y) }, wrist: wrist.map { (x: -$0.x, y: $0.y) })
    }
}

/// Handcrafted bodies facing the camera: shoulders at (±0.5, 0), the head about 0.76 above them.
enum TestPoses {
    static let rest = TestArm(elbow: (x: 0.55, y: -0.8), wrist: (x: 0.6, y: -1.5))
    static let up = TestArm(elbow: (x: 0.8, y: 1.0), wrist: (x: 0.9, y: 2.0))
    static let elbowUp = TestArm(elbow: (x: 0.8, y: 1.0), wrist: nil)
    static let atHead = TestArm(elbow: (x: 0.9, y: 0.6), wrist: (x: 0.3, y: 1.0))
    static let onFace = TestArm(elbow: (x: 0.45, y: -0.6), wrist: (x: 0.15, y: 0.45))
    static let clap = TestArm(elbow: (x: 0.6, y: -0.5), wrist: (x: 0.03, y: 0.1))
    static let shrug = TestArm(elbow: (x: 0.65, y: -0.8), wrist: (x: 1.0, y: -0.6))

    /// `left`/`right` are the person's own arms (nil = not seen); `hips` the left hip (the right one mirrored; nil = not
    /// seen); `head` moves the head. Placed at `origin` with `scale` image units per shoulder width, tilted by `roll`
    /// radians; `mirrored` flips the image left to right.
    static func body(left: TestArm?, right: TestArm?, origin: (x: Double, y: Double) = (x: 0.5, y: 0.45),
                     scale: Double = 0.2, roll: Double = 0, mirrored: Bool = false, shoulders: Bool = true,
                     hips: (x: Double, y: Double)? = nil, head: (x: Double, y: Double) = (x: 0, y: 0)) -> BodyJoints {
        var local: [BodyJoint: (x: Double, y: Double)] = [
            .nose: (x: head.x, y: 0.7 + head.y), .leftEye: (x: 0.08 + head.x, y: 0.8 + head.y),
            .rightEye: (x: -0.08 + head.x, y: 0.8 + head.y),
            .leftEar: (x: 0.18 + head.x, y: 0.75 + head.y), .rightEar: (x: -0.18 + head.x, y: 0.75 + head.y),
        ]
        if shoulders {
            local[.leftShoulder] = (x: 0.5, y: 0)
            local[.rightShoulder] = (x: -0.5, y: 0)
        }
        if let hips {
            local[.leftHip] = hips
            local[.rightHip] = (x: -hips.x, y: hips.y)
        }
        if let left {
            local[.leftElbow] = left.elbow
            local[.leftWrist] = left.wrist
        }
        if let right {
            local[.rightElbow] = right.elbow
            local[.rightWrist] = right.wrist
        }
        var points: [BodyJoint: PosePoint] = [:]
        for (joint, value) in local {
            let x = mirrored ? -value.x : value.x
            let rotatedX = x * cos(roll) - value.y * sin(roll)
            let rotatedY = x * sin(roll) + value.y * cos(roll)
            points[joint] = PosePoint(x: origin.x + scale * rotatedX, y: origin.y + scale * rotatedY)
        }
        return BodyJoints(points: points)
    }

    /// Both arms the same way.
    static func both(_ arm: TestArm, scale: Double = 0.2, roll: Double = 0, mirrored: Bool = false) -> BodyJoints {
        body(left: arm, right: arm.otherSide, scale: scale, roll: roll, mirrored: mirrored)
    }

    static func features(_ joints: BodyJoints, hand: HandShape? = nil) -> PoseFeatures {
        PoseFeatures(joints: joints, hand: hand)
    }
}

/// Handcrafted hands (palm about 1 unit long, wrist at the origin).
enum TestHands {
    private static let curledFingers: [HandJoint: PosePoint] = [
        .indexMCP: PosePoint(x: 0.9, y: 0.35), .indexPIP: PosePoint(x: 1.25, y: 0.3), .indexTip: PosePoint(x: 0.85, y: 0.15),
        .middleMCP: PosePoint(x: 0.95, y: 0.1), .middlePIP: PosePoint(x: 1.3, y: 0.05), .middleTip: PosePoint(x: 0.88, y: -0.05),
        .ringMCP: PosePoint(x: 0.9, y: -0.12), .ringPIP: PosePoint(x: 1.2, y: -0.15), .ringTip: PosePoint(x: 0.82, y: -0.2),
        .littleMCP: PosePoint(x: 0.8, y: -0.32), .littlePIP: PosePoint(x: 1.05, y: -0.33), .littleTip: PosePoint(x: 0.72, y: -0.35),
    ]

    private static func hand(_ points: [HandJoint: PosePoint], offset: PosePoint) -> HandJoints {
        var moved: [HandJoint: PosePoint] = [:]
        for (joint, point) in points {
            moved[joint] = PosePoint(x: point.x + offset.x, y: point.y + offset.y)
        }
        return HandJoints(points: moved)
    }

    /// `hand` with its wrist moved to `wrist` and its palm `size` long: a hand at a `TestPoses` body's wrist (a quarter
    /// of a shoulder width at the default scale).
    static func placed(_ hand: HandJoints, at wrist: PosePoint, size: Double = 0.05) -> HandJoints {
        HandJoints(points: hand.points.mapValues { PosePoint(x: wrist.x + size * $0.x, y: wrist.y + size * $0.y) })
    }

    /// A fist held sideways with the thumb straight up.
    static func thumbsUp(at offset: PosePoint = PosePoint(x: 0, y: 0)) -> HandJoints {
        var points = curledFingers
        points[.wrist] = PosePoint(x: 0, y: 0)
        points[.thumbCMC] = PosePoint(x: 0.2, y: 0.25)
        points[.thumbMP] = PosePoint(x: 0.45, y: 0.55)
        points[.thumbIP] = PosePoint(x: 0.5, y: 0.9)
        points[.thumbTip] = PosePoint(x: 0.52, y: 1.2)
        return hand(points, offset: offset)
    }

    /// The index finger straight out, the others curled, the thumb tucked along them.
    static func pointing() -> HandJoints {
        var points = curledFingers
        points[.wrist] = PosePoint(x: 0, y: 0)
        points[.indexPIP] = PosePoint(x: 1.3, y: 0.4)
        points[.indexDIP] = PosePoint(x: 1.55, y: 0.43)
        points[.indexTip] = PosePoint(x: 1.8, y: 0.45)
        points[.thumbCMC] = PosePoint(x: 0.2, y: 0.25)
        points[.thumbMP] = PosePoint(x: 0.45, y: 0.45)
        points[.thumbIP] = PosePoint(x: 0.7, y: 0.5)
        points[.thumbTip] = PosePoint(x: 0.9, y: 0.45)
        return hand(points, offset: PosePoint(x: 0, y: 0))
    }

    /// A fist: every finger curled, the thumb tucked across them.
    static func fist() -> HandJoints {
        var points = curledFingers
        points[.wrist] = PosePoint(x: 0, y: 0)
        points[.thumbCMC] = PosePoint(x: 0.2, y: 0.25)
        points[.thumbMP] = PosePoint(x: 0.45, y: 0.45)
        points[.thumbIP] = PosePoint(x: 0.7, y: 0.5)
        points[.thumbTip] = PosePoint(x: 0.9, y: 0.45)
        return hand(points, offset: PosePoint(x: 0, y: 0))
    }

    /// Horns ("rock on"): `pointing()` with the little finger straightened too, the middle and ring curled under the
    /// tucked thumb.
    static func rockOn() -> HandJoints {
        var points = pointing().points
        points[.littlePIP] = PosePoint(x: 1.1, y: -0.38)
        points[.littleDIP] = PosePoint(x: 1.32, y: -0.42)
        points[.littleTip] = PosePoint(x: 1.55, y: -0.46)
        return HandJoints(points: points)
    }

    /// All fingers straight up.
    static func openPalm() -> HandJoints {
        var points: [HandJoint: PosePoint] = [.wrist: PosePoint(x: 0, y: 0)]
        let fingers: [(HandJoint, HandJoint, HandJoint, Double)] = [
            (.indexMCP, .indexPIP, .indexTip, -0.3), (.middleMCP, .middlePIP, .middleTip, -0.1),
            (.ringMCP, .ringPIP, .ringTip, 0.1), (.littleMCP, .littlePIP, .littleTip, 0.3),
        ]
        for (mcp, pip, tip, x) in fingers {
            points[mcp] = PosePoint(x: x, y: 0.9)
            points[pip] = PosePoint(x: x * 1.3, y: 1.35)
            points[tip] = PosePoint(x: x * 1.6, y: 1.8)
        }
        points[.thumbTip] = PosePoint(x: -0.8, y: 0.6)
        points[.thumbIP] = PosePoint(x: -0.6, y: 0.45)
        return hand(points, offset: PosePoint(x: 0, y: 0))
    }
}
