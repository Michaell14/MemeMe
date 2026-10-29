import Foundation
import XCTest
@testable import MemeMeCore

final class FaceCuesTests: XCTestCase {
    /// Only `cue` shows in `shape` (against `rest`), at `value`; every other cue is 0.
    private func assertOnly(_ cue: FaceCues.Cue, _ value: Double, _ shape: FaceShape, rest: FaceShape? = nil,
                            file: StaticString = #filePath, line: UInt = #line) {
        let cues = FaceCues(shape: shape, rest: rest)
        XCTAssertEqual(cues.values.count, FaceCues.Cue.allCases.count, file: file, line: line)
        for other in FaceCues.Cue.allCases {
            XCTAssertEqual(cues[other], other == cue ? value : 0, accuracy: 1e-9, "\(other)", file: file, line: line)
        }
    }

    // MARK: The cues

    func testTongueOut() {
        // Without a rest: (tongue − 0.2) / 0.25.
        assertOnly(.tongueOut, 0.4, FaceShape(tongue: 0.3))
        assertOnly(.tongueOut, 0, FaceShape(tongue: 0.15))
        // Against the rest: (0.3 − 0.05 − 0.12) / 0.25 = 0.52; a lower lip 1.6 × as thick as at rest adds 0.3.
        let rest = FaceShape(lowerLip: 0.1, tongue: 0.05)
        assertOnly(.tongueOut, 0.52, FaceShape(lowerLip: 0.12, tongue: 0.3), rest: rest)
        assertOnly(.tongueOut, 0.82, FaceShape(lowerLip: 0.2, tongue: 0.3), rest: rest)
        // A thick lip with the tongue share grown less than 0.06 (a pout) is nothing.
        assertOnly(.tongueOut, 0, FaceShape(lowerLip: 0.2, tongue: 0.1), rest: rest)
        // A rest without a tongue share reads it against the fixed value; no tongue share, no cue.
        assertOnly(.tongueOut, 0.4, FaceShape(tongue: 0.3), rest: FaceShape(lowerLip: 0.1))
        assertOnly(.tongueOut, 0, FaceShape(lowerLip: 0.3), rest: rest)
    }

    func testWink() {
        // Against the rest, each eye's opening over its resting one: 0.4 and 1 → (1 − 0.4 − 0.3) / 0.4 = 0.75.
        let rest = FaceShape(leftEyeOpen: 0.25, rightEyeOpen: 0.25)
        assertOnly(.wink, 0.75, FaceShape(leftEyeOpen: 0.1, rightEyeOpen: 0.25), rest: rest)
        assertOnly(.wink, 1, FaceShape(leftEyeOpen: 0.02, rightEyeOpen: 0.26), rest: rest)
        // Squinting with both eyes (0.4 and 0.6 of rest) isn't a wink.
        assertOnly(.wink, 0, FaceShape(leftEyeOpen: 0.1, rightEyeOpen: 0.15), rest: rest)
        // A wink on a broad smile, which narrows the open eye too: 0.12 and 0.72 → (0.72 − 0.12 − 0.3) / 0.4 = 0.75.
        assertOnly(.wink, 0.75, FaceShape(leftEyeOpen: 0.03, rightEyeOpen: 0.18), rest: rest)
        // Without a rest: (ln(higher / lower) − 0.7) / 0.7, ln 2.5 ≈ 0.9163; a shut eye counts as 0.005 open.
        assertOnly(.wink, 0.308986759820, FaceShape(leftEyeOpen: 0.25, rightEyeOpen: 0.1))
        assertOnly(.wink, 1, FaceShape(leftEyeOpen: 0, rightEyeOpen: 0.25))
        // Both eyes shut (a blink), or one eye not measured.
        assertOnly(.wink, 0, FaceShape(leftEyeOpen: 0, rightEyeOpen: 0))
        assertOnly(.wink, 0, FaceShape(rightEyeOpen: 0.25))
    }

    func testRaisedBrow() {
        // Without a rest: (|0.4 − 0.25| − 0.07) / 0.1 = 0.8; both brows up is surprise, not this.
        assertOnly(.raisedBrow, 0.8, FaceShape(leftBrowGap: 0.4, rightBrowGap: 0.25))
        assertOnly(.raisedBrow, 0, FaceShape(leftBrowGap: 0.4, rightBrowGap: 0.4))
        // Against a rest whose left brow sits 0.02 higher: (|0.15 − 0.02| − 0.05) / 0.1 = 0.8 for the left one,
        // (|−0.12 − 0.02| − 0.05) / 0.1 = 0.9 for the right one.
        let rest = FaceShape(leftBrowGap: 0.3, rightBrowGap: 0.28)
        assertOnly(.raisedBrow, 0.8, FaceShape(leftBrowGap: 0.4, rightBrowGap: 0.25), rest: rest)
        assertOnly(.raisedBrow, 0.9, FaceShape(leftBrowGap: 0.28, rightBrowGap: 0.4), rest: rest)
        assertOnly(.raisedBrow, 0, FaceShape(leftBrowGap: 0.4), rest: rest)
    }

    func testPucker() {
        // Against the rest: (1 − 0.64 / 0.8 − 0.1) / 0.15 = 2/3; an open mouth isn't a pucker.
        let rest = FaceShape(lipWidth: 0.8)
        assertOnly(.pucker, 2.0 / 3.0, FaceShape(lipWidth: 0.64, lipOpening: 0.02), rest: rest)
        assertOnly(.pucker, 0, FaceShape(lipWidth: 0.64, lipOpening: 0.2), rest: rest)
        // Without a rest: (0.7 − 0.58) / 0.15 = 0.8 when the lips are tall for their width (0.3 / 0.58 ≥ 0.4).
        assertOnly(.pucker, 0.8, FaceShape(lipWidth: 0.58, lipHeight: 0.3))
        assertOnly(.pucker, 0, FaceShape(lipWidth: 0.58, lipHeight: 0.2))
        assertOnly(.pucker, 0, FaceShape(lipWidth: 0.58))
    }

    func testSmirk() {
        // Without a rest: (|tilt| − 0.07) / 0.1 = 0.6, either side.
        assertOnly(.smirk, 0.6, FaceShape(cornerTilt: -0.13, mouthShift: 0.18))
        assertOnly(.smirk, 0, FaceShape(cornerTilt: 0.05, mouthShift: 0.1))
        // Against the rest: (|0.11 − 0.01| − 0.05) / 0.1 = 0.5.
        assertOnly(.smirk, 0.5, FaceShape(cornerTilt: 0.11, mouthShift: 0.17),
                   rest: FaceShape(cornerTilt: 0.01, mouthShift: 0.02))
        // The mouth off the eyes' midline alone (a turned head moves it as much) isn't a smirk.
        assertOnly(.smirk, 0, FaceShape(mouthShift: -0.3))
        assertOnly(.smirk, 0, FaceShape(mouthShift: 0.3), rest: FaceShape(cornerTilt: 0.01, mouthShift: 0))
    }

    func testEyeRoll() {
        // Without a rest: (0.11 − 0.07) / 0.05 = 0.8; against a rest of 0.03: (0.1 − 0.03 − 0.04) / 0.05 = 0.6.
        assertOnly(.eyeRoll, 0.8, FaceShape(gazeUp: 0.11))
        assertOnly(.eyeRoll, 0.6, FaceShape(gazeUp: 0.1), rest: FaceShape(gazeUp: 0.03))
        assertOnly(.eyeRoll, 0, FaceShape(gazeUp: -0.3))
        // Eyes narrowed under 0.8 of their rest (a squint, a frown) don't roll; open ones do.
        let rest = FaceShape(leftEyeOpen: 0.25, rightEyeOpen: 0.25, gazeUp: 0.03)
        XCTAssertEqual(FaceCues(shape: FaceShape(leftEyeOpen: 0.15, rightEyeOpen: 0.15, gazeUp: 0.2), rest: rest)[.eyeRoll], 0)
        XCTAssertEqual(FaceCues(shape: FaceShape(leftEyeOpen: 0.25, rightEyeOpen: 0.22, gazeUp: 0.2), rest: rest)[.eyeRoll], 1)
    }

    func testEachCueNamesItsMood() {
        let expected: [FaceCues.Cue: Mood] = [
            .tongueOut: .tongueOut, .wink: .wink, .raisedBrow: .raisedEyebrow, .pucker: .duckFace, .smirk: .smirk,
            .eyeRoll: .eyeRoll,
        ]
        XCTAssertEqual(expected.count, FaceCues.Cue.allCases.count)
        for cue in FaceCues.Cue.allCases {
            XCTAssertEqual(cue.mood, expected[cue], "\(cue)")
        }
    }

    // MARK: Strongest, clear, none

    func testStrongestAndClearCue() {
        XCTAssertEqual(FaceCues.clear, 0.5)
        // Two cues at 1: the first in `Cue.allCases` wins.
        let tie = FaceCues(shape: FaceShape(gazeUp: 0.33, tongue: 0.45), rest: nil)
        XCTAssertEqual(tie[.tongueOut], 1)
        XCTAssertEqual(tie[.eyeRoll], 1)
        XCTAssertEqual(tie.strongest?.cue, .tongueOut)
        XCTAssertEqual(tie.clearCue, .tongueOut)
        // The stronger of two: eye roll 0.8 over smirk 0.6.
        let both = FaceCues(shape: FaceShape(cornerTilt: 0.13, gazeUp: 0.11), rest: nil)
        XCTAssertEqual(both.strongest?.cue, .eyeRoll)
        XCTAssertEqual(both.strongest?.value ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(both.clearCue, .eyeRoll)
        // A cue under `clear` (0.4) is the strongest but names nothing.
        let weak = FaceCues(shape: FaceShape(leftBrowGap: 0.36, rightBrowGap: 0.25), rest: nil)
        XCTAssertEqual(weak.strongest?.cue, .raisedBrow)
        XCTAssertEqual(weak.strongest?.value ?? 0, 0.4, accuracy: 1e-9)
        XCTAssertNil(weak.clearCue)
    }

    func testNone() {
        XCTAssertEqual(FaceCues.none.values, [0, 0, 0, 0, 0, 0])
        XCTAssertNil(FaceCues.none.strongest)
        XCTAssertNil(FaceCues.none.clearCue)
        for cue in FaceCues.Cue.allCases {
            XCTAssertEqual(FaceCues.none[cue], 0, "\(cue)")
        }
        // Nothing measured reads as none; so does no shape at all.
        XCTAssertEqual(FaceCues(shape: FaceShape(), rest: nil), FaceCues.none)
        XCTAssertEqual(RestingBaseline().cues(of: nil), FaceCues.none)
    }

    func testTheBaselineReadsCuesAgainstItsRestingShape() {
        let shape = FaceShape(tongue: 0.3)
        XCTAssertEqual(RestingBaseline().cues(of: shape)[.tongueOut], 0.4, accuracy: 1e-9)
        XCTAssertEqual(RestingBaseline(restShape: FaceShape(tongue: 0.05)).cues(of: shape)[.tongueOut], 0.52, accuracy: 1e-9)
    }

    // MARK: FaceShape coding

    func testFaceShapeCodableRoundTripAndLenientDecoding() throws {
        let shape = FaceShape(leftEyeOpen: 0.25, rightEyeOpen: 0.1, leftBrowGap: 0.3, rightBrowGap: 0.28, lipWidth: 0.8,
                              lipHeight: 0.3, lipOpening: 0.02, lowerLip: 0.1, cornerTilt: -0.01, mouthShift: 0.02,
                              gazeUp: 0.05, tongue: 0.04)
        let data = try JSONEncoder().encode(shape)
        XCTAssertEqual(try JSONDecoder().decode(FaceShape.self, from: data), shape)

        // Fields that weren't measured are left out, and come back nil.
        let unmeasured = try JSONEncoder().encode(FaceShape())
        XCTAssertEqual(String(decoding: unmeasured, as: UTF8.self), "{}")
        XCTAssertEqual(try JSONDecoder().decode(FaceShape.self, from: Data("{}".utf8)), FaceShape())

        // A field that doesn't decode is nil; the others still load.
        let bad = try JSONDecoder().decode(FaceShape.self, from: Data(#"{"tongue": "lots", "lipWidth": 0.8, "gazeUp": null}"#.utf8))
        XCTAssertNil(bad.tongue)
        XCTAssertNil(bad.gazeUp)
        XCTAssertEqual(bad.lipWidth, 0.8)
        XCTAssertEqual(bad, FaceShape(lipWidth: 0.8))
    }

    // MARK: The mood

    private func mood(_ face: FaceFeatures?, _ shape: FaceShape?, pose: PoseFeatures? = nil,
                      baseline: RestingBaseline = RestingBaseline()) -> Mood {
        MoodClassifier.mood(for: face, pose: pose, shape: shape, baseline: baseline)
    }

    func testAClearCueNamesTheMood() {
        let shapes: [Mood: FaceShape] = [
            .tongueOut: FaceShape(tongue: 0.45),
            .wink: FaceShape(leftEyeOpen: 0, rightEyeOpen: 0.25),
            .raisedEyebrow: FaceShape(leftBrowGap: 0.4, rightBrowGap: 0.25),
            .duckFace: FaceShape(lipWidth: 0.58, lipHeight: 0.3),
            .smirk: FaceShape(cornerTilt: 0.13),
            .eyeRoll: FaceShape(gazeUp: 0.3),
        ]
        XCTAssertEqual(shapes.count, FaceCues.Cue.allCases.count)
        for (expected, shape) in shapes {
            XCTAssertEqual(mood(TestFaces.neutral, shape), expected, "\(expected)")
        }
        // Before the face's own rules: a smile with the tongue out, a surprised face winking.
        XCTAssertEqual(mood(TestFaces.smile, FaceShape(tongue: 0.45)), .tongueOut)
        XCTAssertEqual(mood(TestFaces.surprise, FaceShape(leftEyeOpen: 0, rightEyeOpen: 0.25)), .wink)
    }

    func testWithoutAClearCueTheFaceDecides() {
        XCTAssertEqual(mood(TestFaces.smile, nil), .happy)
        XCTAssertEqual(mood(TestFaces.smile, FaceShape(tongue: 0.3)), .happy)          // tongue out 0.4: not clear
        XCTAssertEqual(mood(TestFaces.surprise, FaceShape()), .shocked)
        XCTAssertEqual(mood(TestFaces.neutral, FaceShape(lipWidth: 0.8, lipHeight: 0.3, lipOpening: 0)), .unimpressed)
        // Against a rest that already shows that much lip color: (0.45 − 0.3 − 0.12) / 0.25 = 0.12.
        let ruddy = RestingBaseline(restShape: FaceShape(tongue: 0.3))
        XCTAssertEqual(mood(TestFaces.neutral, FaceShape(tongue: 0.45), baseline: ruddy), .unimpressed)
        XCTAssertEqual(mood(TestFaces.neutral, FaceShape(tongue: 0.45)), .tongueOut)
    }

    func testGesturesStillWinAndNoFaceIsStillAReaction() {
        let celebrating = TestPoses.features(TestPoses.both(TestPoses.up))
        XCTAssertEqual(mood(TestFaces.neutral, FaceShape(tongue: 0.45), pose: celebrating), .celebrate)
        XCTAssertEqual(mood(nil, FaceShape(tongue: 0.45)), .reaction)
    }
}
