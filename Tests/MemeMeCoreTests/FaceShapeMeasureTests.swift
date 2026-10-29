#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import XCTest
@testable import MemeMeCore

final class FaceShapeMeasureTests: XCTestCase {
    // MARK: A synthetic face (face-box-normalized, origin bottom-left)

    /// Vision's left eye is on the picture's right. Eyes 0.3 apart at height 0.6, so a length of 0.03 is 0.1 eye
    /// distances.
    private static let leftEyeCenter = CGPoint(x: 0.65, y: 0.6)
    private static let rightEyeCenter = CGPoint(x: 0.35, y: 0.6)

    /// A hexagon 0.12 wide and 2 × `half` high: area 0.12 × `half` + 0.06 × `half` = 0.18 × `half`, so its opening
    /// is 0.18 × `half` / 0.0144 (0.25 for a `half` of 0.02).
    private static func eye(_ center: CGPoint, half: CGFloat = 0.02) -> [CGPoint] {
        [CGPoint(x: center.x - 0.06, y: center.y), CGPoint(x: center.x - 0.03, y: center.y + half),
         CGPoint(x: center.x + 0.03, y: center.y + half), CGPoint(x: center.x + 0.06, y: center.y),
         CGPoint(x: center.x + 0.03, y: center.y - half), CGPoint(x: center.x - 0.03, y: center.y - half)]
    }

    private static func brow(over center: CGPoint, at y: CGFloat) -> [CGPoint] {
        [CGPoint(x: center.x - 0.06, y: y), CGPoint(x: center.x, y: y), CGPoint(x: center.x + 0.06, y: y)]
    }

    /// 0.24 wide (0.38...0.62) and 0.09 high (0.255...0.345): 0.8 and 0.3 eye distances.
    private static let outerLips: [CGPoint] = [
        CGPoint(x: 0.38, y: 0.30), CGPoint(x: 0.42, y: 0.33), CGPoint(x: 0.46, y: 0.345), CGPoint(x: 0.50, y: 0.34),
        CGPoint(x: 0.54, y: 0.345), CGPoint(x: 0.58, y: 0.33), CGPoint(x: 0.62, y: 0.30), CGPoint(x: 0.58, y: 0.27),
        CGPoint(x: 0.54, y: 0.258), CGPoint(x: 0.50, y: 0.255), CGPoint(x: 0.46, y: 0.258), CGPoint(x: 0.42, y: 0.27),
    ]
    /// A closed mouth: 0.01 high (0.295...0.305).
    private static let innerLips: [CGPoint] = [
        CGPoint(x: 0.40, y: 0.30), CGPoint(x: 0.45, y: 0.305), CGPoint(x: 0.50, y: 0.305), CGPoint(x: 0.55, y: 0.305),
        CGPoint(x: 0.60, y: 0.30), CGPoint(x: 0.55, y: 0.295), CGPoint(x: 0.50, y: 0.295), CGPoint(x: 0.45, y: 0.295),
    ]

    private static func face(leftEyeHalfHeight: CGFloat = 0.02, leftBrowY: CGFloat = 0.69,
                             outerLips: [CGPoint] = FaceShapeMeasureTests.outerLips,
                             innerLips: [CGPoint] = FaceShapeMeasureTests.innerLips,
                             pupilY: CGFloat = 0.6) -> FaceShapeMeasure.Landmarks {
        FaceShapeMeasure.Landmarks(
            leftEye: eye(leftEyeCenter, half: leftEyeHalfHeight),
            rightEye: eye(rightEyeCenter),
            leftBrow: brow(over: leftEyeCenter, at: leftBrowY),
            rightBrow: brow(over: rightEyeCenter, at: 0.69),
            outerLips: outerLips,
            innerLips: innerLips,
            leftPupil: [CGPoint(x: leftEyeCenter.x, y: pupilY)],
            rightPupil: [CGPoint(x: rightEyeCenter.x, y: pupilY)]
        )
    }

    /// `point` turned by `degrees` about (0.5, 0.5), scaled by `scale` and moved by `shift`.
    private static func moved(_ point: CGPoint, degrees: Double, scale: Double = 1, shift: CGPoint = .zero) -> CGPoint {
        let angle = degrees * Double.pi / 180
        let x = Double(point.x) - 0.5
        let y = Double(point.y) - 0.5
        return CGPoint(x: 0.5 + scale * (x * cos(angle) - y * sin(angle)) + Double(shift.x),
                       y: 0.5 + scale * (x * sin(angle) + y * cos(angle)) + Double(shift.y))
    }

    private static func moved(_ landmarks: FaceShapeMeasure.Landmarks, degrees: Double, scale: Double = 1,
                              shift: CGPoint = .zero) -> FaceShapeMeasure.Landmarks {
        landmarks.map { moved($0, degrees: degrees, scale: scale, shift: shift) }
    }

    private func assertShape(_ shape: FaceShape?, equals expected: FaceShape, file: StaticString = #filePath,
                             line: UInt = #line) {
        guard let shape else {
            XCTFail("no shape", file: file, line: line)
            return
        }
        let names = ["leftEyeOpen", "rightEyeOpen", "leftBrowGap", "rightBrowGap", "lipWidth", "lipHeight", "lipOpening",
                     "lowerLip", "cornerTilt", "mouthShift", "gazeUp", "tongue"]
        for (name, field) in zip(names, FaceShape.fields) {
            switch (shape[keyPath: field], expected[keyPath: field]) {
            case let (value?, wanted?):
                XCTAssertEqual(value, wanted, accuracy: 1e-9, name, file: file, line: line)
            case (nil, nil):
                break
            case let (value, wanted):
                XCTFail("\(name): \(String(describing: value)) instead of \(String(describing: wanted))", file: file, line: line)
            }
        }
    }

    /// The level face: eyes 0.25 open, brows 0.09 = 0.3 over the eyes, lips 0.8 × 0.3, the mouth closed (0.01 = 1/30
    /// open), the lower lip 0.295 − 0.255 = 0.04 = 2/15 thick, nothing to one side, looking ahead.
    private static let levelShape = FaceShape(leftEyeOpen: 0.25, rightEyeOpen: 0.25, leftBrowGap: 0.3, rightBrowGap: 0.3,
                                              lipWidth: 0.8, lipHeight: 0.3, lipOpening: 1.0 / 30, lowerLip: 2.0 / 15,
                                              cornerTilt: 0, mouthShift: 0, gazeUp: 0)

    // MARK: Geometry

    func testALevelFace() {
        let shape = FaceShapeMeasure.shape(of: FaceShapeMeasureTests.face(), color: nil)
        assertShape(shape, equals: FaceShapeMeasureTests.levelShape)
        XCTAssertNil(shape.flatMap { FaceCues(shape: $0, rest: nil).clearCue }, "a resting face shows no cue")
    }

    func testATiltedSmallerOrMovedFaceMeasuresTheSame() {
        let level = FaceShapeMeasureTests.face()
        let moves: [(degrees: Double, scale: Double, shift: CGPoint)] = [
            (degrees: 20, scale: 1, shift: .zero),
            (degrees: -20, scale: 1, shift: .zero),
            (degrees: -20, scale: 0.6, shift: CGPoint(x: 0.05, y: -0.03)),
            (degrees: 35, scale: 1.3, shift: .zero),
        ]
        for move in moves {
            let tilted = FaceShapeMeasureTests.moved(level, degrees: move.degrees, scale: move.scale, shift: move.shift)
            assertShape(FaceShapeMeasure.shape(of: tilted, color: nil), equals: FaceShapeMeasureTests.levelShape)
        }
        // The eyes named the other way round (a mirrored picture) give the same frame.
        var swapped = level
        swapped.leftEye = level.rightEye
        swapped.rightEye = level.leftEye
        swapped.leftPupil = level.rightPupil
        swapped.rightPupil = level.leftPupil
        swapped.leftBrow = level.rightBrow
        swapped.rightBrow = level.leftBrow
        assertShape(FaceShapeMeasure.shape(of: swapped, color: nil), equals: FaceShapeMeasureTests.levelShape)
    }

    func testAWink() {
        // The left eye 0.008 high: 0.18 × 0.004 / 0.0144 = 0.05 open.
        var expected = FaceShapeMeasureTests.levelShape
        expected.leftEyeOpen = 0.05
        let shape = FaceShapeMeasure.shape(of: FaceShapeMeasureTests.face(leftEyeHalfHeight: 0.004), color: nil)
        assertShape(shape, equals: expected)
        XCTAssertEqual(shape.flatMap { FaceCues(shape: $0, rest: nil).clearCue }, .wink)
    }

    func testOneRaisedBrow() {
        // The left brow 0.045 higher: (0.735 − 0.6) / 0.3 = 0.45.
        var expected = FaceShapeMeasureTests.levelShape
        expected.leftBrowGap = 0.45
        let shape = FaceShapeMeasure.shape(of: FaceShapeMeasureTests.face(leftBrowY: 0.735), color: nil)
        assertShape(shape, equals: expected)
        XCTAssertEqual(shape.flatMap { FaceCues(shape: $0, rest: nil).clearCue }, .raisedBrow)
    }

    func testPursedLips() {
        // The lips drawn in to 0.625 of their width: 0.15 = 0.5 wide, as high as before.
        func pursed(_ points: [CGPoint]) -> [CGPoint] {
            points.map { CGPoint(x: 0.5 + ($0.x - 0.5) * 0.625, y: $0.y) }
        }
        var expected = FaceShapeMeasureTests.levelShape
        expected.lipWidth = 0.5
        let shape = FaceShapeMeasure.shape(of: FaceShapeMeasureTests.face(outerLips: pursed(FaceShapeMeasureTests.outerLips),
                                                                          innerLips: pursed(FaceShapeMeasureTests.innerLips)),
                                           color: nil)
        assertShape(shape, equals: expected)
        XCTAssertEqual(shape.flatMap { FaceCues(shape: $0, rest: nil).clearCue }, .pucker)
    }

    func testASmirk() {
        // The left corner 0.045 up: (0.345 − 0.3) / 0.3 = 0.15 higher than the right one.
        var lips = FaceShapeMeasureTests.outerLips
        lips[0] = CGPoint(x: 0.38, y: 0.345)
        var expected = FaceShapeMeasureTests.levelShape
        expected.cornerTilt = 0.15
        let shape = FaceShapeMeasure.shape(of: FaceShapeMeasureTests.face(outerLips: lips), color: nil)
        assertShape(shape, equals: expected)
        XCTAssertEqual(shape.flatMap { FaceCues(shape: $0, rest: nil).clearCue }, .smirk)

        // The whole mouth 0.045 to the side: 0.15 off the midline.
        let shifted = FaceShapeMeasureTests.outerLips.map { CGPoint(x: $0.x + 0.045, y: $0.y) }
        let inner = FaceShapeMeasureTests.innerLips.map { CGPoint(x: $0.x + 0.045, y: $0.y) }
        let aside = FaceShapeMeasure.shape(of: FaceShapeMeasureTests.face(outerLips: shifted, innerLips: inner), color: nil)
        XCTAssertEqual(aside?.mouthShift ?? 0, 0.15, accuracy: 1e-9)
        XCTAssertEqual(aside?.cornerTilt ?? 1, 0, accuracy: 1e-9)
    }

    func testEyesLookingUp() {
        // Pupils 0.015 over the middle of eyes 0.04 high: 0.375. The frame follows the pupils, so nothing else moves.
        var expected = FaceShapeMeasureTests.levelShape
        expected.gazeUp = 0.375
        let shape = FaceShapeMeasure.shape(of: FaceShapeMeasureTests.face(pupilY: 0.615), color: nil)
        assertShape(shape, equals: expected)
        XCTAssertEqual(shape.flatMap { FaceCues(shape: $0, rest: nil).clearCue }, .eyeRoll)
    }

    func testNoShapeWithoutBothEyes() {
        var oneEye = FaceShapeMeasureTests.face()
        oneEye.leftEye = []
        oneEye.leftPupil = []
        XCTAssertNil(FaceShapeMeasure.shape(of: oneEye, color: nil))
        XCTAssertNil(FaceShapeMeasure.shape(of: FaceShapeMeasure.Landmarks(), color: nil))

        // An eye's contour alone (no pupil) places it.
        var noPupils = FaceShapeMeasureTests.face()
        noPupils.leftPupil = []
        noPupils.rightPupil = []
        var expected = FaceShapeMeasureTests.levelShape
        expected.gazeUp = nil
        assertShape(FaceShapeMeasure.shape(of: noPupils, color: nil), equals: expected)

        // Missing lips leave their fields out.
        var noLips = FaceShapeMeasureTests.face()
        noLips.outerLips = []
        noLips.innerLips = []
        let shape = FaceShapeMeasure.shape(of: noLips, color: { _ in FaceShapeMeasure.Sample(luma: 100, redness: 150) })
        XCTAssertEqual(shape?.leftEyeOpen ?? 0, 0.25, accuracy: 1e-9)
        XCTAssertNil(shape?.lipWidth)
        XCTAssertNil(shape?.lipOpening)
        XCTAssertNil(shape?.lowerLip)
        XCTAssertNil(shape?.cornerTilt)
        XCTAssertNil(shape?.tongue)
    }

    func testLevelingTurnsTheFaceAboutTheEyes() {
        let level = FaceShapeMeasureTests.face()
        XCTAssertEqual(FaceShapeMeasure.leveled(level), level, "an upright face is left as it is")

        // Tilted 20° and leveled again: the same face about the eyes' midpoint (which the tilt moved).
        let leveled = FaceShapeMeasure.leveled(FaceShapeMeasureTests.moved(level, degrees: 20))
        let midpoint = FaceShapeMeasureTests.moved(CGPoint(x: 0.5, y: 0.6), degrees: 20)
        let expected = level.map { CGPoint(x: $0.x - 0.5 + midpoint.x, y: $0.y - 0.6 + midpoint.y) }
        let pairs = [(leveled.leftEye, expected.leftEye), (leveled.rightBrow, expected.rightBrow),
                     (leveled.outerLips, expected.outerLips), (leveled.innerLips, expected.innerLips),
                     (leveled.leftPupil, expected.leftPupil)]
        for (got, wanted) in pairs {
            XCTAssertEqual(got.count, wanted.count)
            for (point, target) in zip(got, wanted) {
                XCTAssertEqual(point.x, target.x, accuracy: 1e-9)
                XCTAssertEqual(point.y, target.y, accuracy: 1e-9)
            }
        }
    }

    // MARK: Tongue

    /// Cheeks redness 150 and brightness 160; lips (the outer lips' box) 175; a tongue 0.07 wide hanging 0.1 under
    /// them (0.465...0.535 × 0.15...0.25) redness 200, brightness 150.
    private static func tongueColor(_ point: CGPoint) -> FaceShapeMeasure.Sample? {
        if point.x >= 0.465 && point.x <= 0.535 && point.y >= 0.15 && point.y < 0.25 {
            return FaceShapeMeasure.Sample(luma: 150, redness: 200)
        }
        if point.x >= 0.38 && point.x <= 0.62 && point.y >= 0.255 && point.y <= 0.345 {
            return FaceShapeMeasure.Sample(luma: 120, redness: 175)
        }
        return FaceShapeMeasure.Sample(luma: 160, redness: 150)
    }

    func testTheTongueShare() {
        // Skin 150, lips 175 (C = 25): tongue-colored is redness ≥ 165 and brightness ≥ 72. The band under the lips
        // is x −0.24...0.24 and y −1.17...−1.62 (12 × 8 samples); the tongue covers x −0.117...0.117 (6 columns) and
        // y down to −1.5 (6 rows): 36 of 96.
        let level = FaceShapeMeasureTests.face()
        let shape = FaceShapeMeasure.shape(of: level, color: FaceShapeMeasureTests.tongueColor)
        XCTAssertEqual(shape?.tongue ?? 0, 0.375, accuracy: 1e-9)
        XCTAssertEqual(shape.flatMap { FaceCues(shape: $0, rest: nil).clearCue }, .tongueOut)

        // The colors are read at face-box points: a tilted face in a tilted picture reads the same.
        let tilted = FaceShapeMeasureTests.moved(level, degrees: 20)
        let tiltedShape = FaceShapeMeasure.shape(of: tilted, color: { point in
            FaceShapeMeasureTests.tongueColor(FaceShapeMeasureTests.moved(point, degrees: -20))
        })
        XCTAssertEqual(tiltedShape?.tongue ?? 0, 0.375, accuracy: 1e-9)

        // Nothing under the lips is tongue-colored.
        let none = FaceShapeMeasure.shape(of: level, color: { point in
            point.y < 0.25 ? FaceShapeMeasure.Sample(luma: 160, redness: 150) : FaceShapeMeasureTests.tongueColor(point)
        })
        XCTAssertEqual(none?.tongue ?? 1, 0, accuracy: 1e-9)

        // A dark open mouth under the lips (brightness 60 < 72) isn't a tongue.
        let dark = FaceShapeMeasure.shape(of: level, color: { point in
            point.y < 0.25 && point.x >= 0.465 && point.x <= 0.535
                ? FaceShapeMeasure.Sample(luma: 60, redness: 200) : FaceShapeMeasureTests.tongueColor(point)
        })
        XCTAssertEqual(dark?.tongue ?? 1, 0, accuracy: 1e-9)
    }

    func testNoTongueWithoutColorsOrWhenLipsLookLikeSkin() {
        let level = FaceShapeMeasureTests.face()
        XCTAssertNil(FaceShapeMeasure.shape(of: level, color: nil)?.tongue)
        // Gray light: lips no redder than the cheeks.
        let gray = FaceShapeMeasure.shape(of: level, color: { _ in FaceShapeMeasure.Sample(luma: 128, redness: 140) })
        XCTAssertNil(gray?.tongue)
        XCTAssertEqual(gray?.lipWidth ?? 0, 0.8, accuracy: 1e-9, "the rest of the shape is measured")
        // Outside the picture.
        XCTAssertNil(FaceShapeMeasure.shape(of: level, color: { _ in nil })?.tongue)
    }
}
