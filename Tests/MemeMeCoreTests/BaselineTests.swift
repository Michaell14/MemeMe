import Foundation
import XCTest
@testable import MemeMeCore

final class BaselineTests: XCTestCase {
    func testDefaultsToPopulationNeutral() {
        let baseline = RestingBaseline()
        XCTAssertEqual(baseline.neutral, FaceFeatures.populationNeutral)
        XCTAssertEqual(baseline.sampleCount, 0)
        XCTAssertEqual(baseline.intensity(of: FaceFeatures.populationNeutral), 0)
        XCTAssertEqual(baseline.signedDeviation(of: FaceFeatures.populationNeutral), [0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(RestingBaseline(sampleCount: -4).sampleCount, 0)
    }

    func testSignedDeviationRegionDeviationAndIntensity() {
        let baseline = RestingBaseline()
        let face = makeFace(mouth: 0.55)
        assertVectorsEqual(baseline.signedDeviation(of: face), [0, 0, 0.5, 0, 0, 0, 0])
        let regions = baseline.deviation(of: face)
        XCTAssertEqual(regions.count, 3)
        XCTAssertEqual(regions[.brows] ?? -1, 0, accuracy: 1e-12)
        XCTAssertEqual(regions[.eyes] ?? -1, 0, accuracy: 1e-12)
        XCTAssertEqual(regions[.mouth] ?? -1, 1.0 / 3.0, accuracy: 1e-9)     // 2 × mean(0.5, 0, 0)
        XCTAssertEqual(baseline.intensity(of: face), 2 * (0.25 / 7).squareRoot(), accuracy: 1e-9)   // ≈ 0.378
    }

    func testSignedDeviationKeepsDirection() {
        let deviation = RestingBaseline().signedDeviation(of: makeFace(brow: 0.3, smile: 0.7))
        XCTAssertEqual(deviation[0], -0.15, accuracy: 1e-9)
        XCTAssertEqual(deviation[4], 0.2, accuracy: 1e-9)
    }

    func testEyeRegionAveragesOpennessAndGaze() {
        let regions = RestingBaseline().deviation(of: makeFace(eye: 0.65, gaze: 0.4))
        XCTAssertEqual(regions[.eyes] ?? -1, 0.5, accuracy: 1e-9)    // 2 × mean(0.2, 0.3)
        XCTAssertEqual(regions[.brows] ?? -1, 0, accuracy: 1e-12)
        XCTAssertEqual(regions[.mouth] ?? -1, 0, accuracy: 1e-12)
    }

    func testDeviationAndIntensityAreCappedAtOne() {
        let extreme = FaceFeatures(browRaise: 1, eyeOpenness: 1, mouthOpenness: 1, mouthWidth: 1,
                                   smile: 1, headTilt: 1, gazeSide: 1)
        let baseline = RestingBaseline()
        XCTAssertEqual(baseline.intensity(of: extreme), 1)
        let regions = baseline.deviation(of: extreme)
        for region in FaceRegion.allCases {
            XCTAssertEqual(regions[region] ?? -1, 1, "\(region)")
        }
    }

    func testObserveWarmUpUsesFastAverage() {
        var baseline = RestingBaseline()
        baseline.observe(makeFace(brow: 0.55))     // intensity ≈ 0.076 < 0.25: calm
        XCTAssertEqual(baseline.sampleCount, 1)
        XCTAssertEqual(baseline.neutral.browRaise, 0.47, accuracy: 1e-9)    // 0.45 + 0.2 × 0.1
        XCTAssertEqual(baseline.neutral.eyeOpenness, 0.45, accuracy: 1e-12)
        XCTAssertEqual(baseline.neutral.mouthOpenness, 0.05, accuracy: 1e-12)
        XCTAssertEqual(baseline.neutral.gazeSide, 0.1, accuracy: 1e-12)
    }

    func testObserveIgnoresExpressiveFrames() {
        var baseline = RestingBaseline()
        baseline.observe(makeFace(mouth: 0.55))    // intensity ≈ 0.378 ≥ 0.25
        XCTAssertEqual(baseline, RestingBaseline())
    }

    func testObserveAfterWarmUpIsSlowAndStricter() {
        var settled = RestingBaseline(sampleCount: 30)
        settled.observe(makeFace(brow: 0.55))      // ≈ 0.076 < 0.08: calm
        XCTAssertEqual(settled.sampleCount, 31)
        XCTAssertEqual(settled.neutral.browRaise, 0.455, accuracy: 1e-9)   // 0.45 + 0.05 × 0.1

        var strict = RestingBaseline(sampleCount: 30)
        strict.observe(makeFace(brow: 0.57))       // ≈ 0.091 ≥ 0.08: not calm once settled
        XCTAssertEqual(strict.sampleCount, 30)
        XCTAssertEqual(strict.neutral, FaceFeatures.populationNeutral)

        var warming = RestingBaseline(sampleCount: 29)
        warming.observe(makeFace(brow: 0.57))      // still warming up: calm below 0.25, alpha 0.2
        XCTAssertEqual(warming.sampleCount, 30)
        XCTAssertEqual(warming.neutral.browRaise, 0.474, accuracy: 1e-9)
    }

    func testRepeatedCalmFramesConverge() {
        var baseline = RestingBaseline()
        for _ in 0..<3 {
            baseline.observe(makeFace(brow: 0.55))
        }
        XCTAssertEqual(baseline.sampleCount, 3)
        XCTAssertEqual(baseline.neutral.browRaise, 0.4988, accuracy: 1e-9)   // 0.47, 0.486, 0.4988
    }

    func testDeviationIsRelativeToTheLearnedNeutral() {
        let baseline = RestingBaseline(neutral: makeFace(brow: 0.3, eye: 0.3))
        assertVectorsEqual(baseline.signedDeviation(of: FaceFeatures.populationNeutral), [0.15, 0.15, 0, 0, 0, 0, 0])
        XCTAssertEqual(baseline.intensity(of: makeFace(brow: 0.3, eye: 0.3)), 0)
    }

    func testCodableRoundTripAndLenientDecoding() throws {
        let baseline = RestingBaseline(neutral: makeFace(brow: 0.5, smile: 0.55), sampleCount: 42)
        let data = try JSONEncoder().encode(baseline)
        XCTAssertEqual(try JSONDecoder().decode(RestingBaseline.self, from: data), baseline)

        let empty = try JSONDecoder().decode(RestingBaseline.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, RestingBaseline())

        let partial = try JSONDecoder().decode(RestingBaseline.self, from: Data(#"{"sampleCount": 7}"#.utf8))
        XCTAssertEqual(partial.sampleCount, 7)
        XCTAssertEqual(partial.neutral, FaceFeatures.populationNeutral)
        XCTAssertNil(partial.restShape)
    }

    func testCalmFramesTeachTheRestingShape() {
        var baseline = RestingBaseline()
        let rest = FaceShape(lipWidth: 0.8, lowerLip: 0.1, tongue: 0.05)
        baseline.observe(TestFaces.neutral, shape: rest)
        XCTAssertEqual(baseline.restShape, rest)       // the first one is taken as it is
        XCTAssertEqual(baseline.sampleCount, 1)

        // Then each field moves 0.2 of the way (still warming up); a field the rest lacks is taken, one the frame
        // lacks stays.
        baseline.observe(TestFaces.neutral, shape: FaceShape(lipWidth: 0.81, gazeUp: 0.05))
        XCTAssertEqual(baseline.sampleCount, 2)
        XCTAssertEqual(baseline.restShape?.lipWidth ?? 0, 0.802, accuracy: 1e-9)      // 0.8 + 0.2 × 0.01
        XCTAssertEqual(baseline.restShape?.gazeUp ?? 0, 0.05, accuracy: 1e-12)
        XCTAssertEqual(baseline.restShape?.lowerLip ?? 0, 0.1, accuracy: 1e-12)
        XCTAssertEqual(baseline.restShape?.tongue ?? 0, 0.05, accuracy: 1e-12)
        XCTAssertNil(baseline.restShape?.leftEyeOpen)

        // A frame without a shape teaches the seven numbers only.
        baseline.observe(TestFaces.neutral)
        XCTAssertEqual(baseline.sampleCount, 3)
        XCTAssertEqual(baseline.restShape?.lipWidth ?? 0, 0.802, accuracy: 1e-9)

        // Settled: 0.05 of the way.
        var settled = RestingBaseline(sampleCount: 30, restShape: rest)
        settled.observe(TestFaces.neutral, shape: FaceShape(lipWidth: 0.82))
        XCTAssertEqual(settled.restShape?.lipWidth ?? 0, 0.801, accuracy: 1e-9)      // 0.8 + 0.05 × 0.02
    }

    func testAFrameShowingACueTeachesTheRestOnlySlowly() {
        // With no rest yet, the first shape is the rest whatever it shows (a wrong one catches up, below).
        var fresh = RestingBaseline()
        fresh.observe(TestFaces.neutral, shape: FaceShape(tongue: 0.45))      // tongue out 1 against the fixed value
        XCTAssertEqual(fresh, RestingBaseline(sampleCount: 1, restShape: FaceShape(tongue: 0.45)))

        // A held tongue (tongue out 0.52) moves the rest only 0.01 of the way.
        let rest = FaceShape(lowerLip: 0.1, tongue: 0.05)
        var learned = RestingBaseline(restShape: rest)
        learned.observe(TestFaces.neutral, shape: FaceShape(lowerLip: 0.1, tongue: 0.3))
        XCTAssertEqual(learned.sampleCount, 1)
        XCTAssertEqual(learned.restShape?.tongue ?? 0, 0.0525, accuracy: 1e-12)      // 0.05 + 0.01 × 0.25
        XCTAssertEqual(learned.restShape?.lowerLip ?? 0, 0.1, accuracy: 1e-12)

        // Under the limit (tongue out (0.21 − 0.0525 − 0.12) / 0.25 = 0.15) is calm: 0.2 of the way (warming up).
        learned.observe(TestFaces.neutral, shape: FaceShape(lowerLip: 0.1, tongue: 0.21))
        XCTAssertEqual(learned.sampleCount, 2)
        XCTAssertEqual(learned.restShape?.tongue ?? 0, 0.084, accuracy: 1e-9)      // 0.0525 + 0.2 × 0.1575

        // A rest that no longer fits (a smirk of 1 on a level face) catches up instead of locking.
        let level = FaceShape(cornerTilt: 0)
        var stale = RestingBaseline(sampleCount: 30, restShape: FaceShape(cornerTilt: 0.15))
        XCTAssertEqual(stale.cues(of: level).clearCue, .smirk)
        for _ in 0..<200 {
            stale.observe(TestFaces.neutral, shape: level)
        }
        XCTAssertEqual(stale.sampleCount, 230)
        XCTAssertLessThan(stale.restShape?.cornerTilt ?? 1, 0.01)
        XCTAssertNil(stale.cues(of: level).clearCue)

        // An expressive face teaches nothing, its shape included.
        var expressive = RestingBaseline()
        expressive.observe(makeFace(mouth: 0.55), shape: rest)
        XCTAssertEqual(expressive, RestingBaseline())
    }

    func testTheRestingShapeIsSavedAndOldSettingsStillLoad() throws {
        let baseline = RestingBaseline(neutral: makeFace(brow: 0.5), sampleCount: 42,
                                       restShape: FaceShape(leftEyeOpen: 0.25, rightEyeOpen: 0.24, lipWidth: 0.8, tongue: 0.05))
        let data = try JSONEncoder().encode(baseline)
        XCTAssertEqual(try JSONDecoder().decode(RestingBaseline.self, from: data), baseline)

        // Settings saved before the resting shape existed.
        let old = Data(#"""
        {"neutral": {"browRaise": 0.5, "eyeOpenness": 0.45, "mouthOpenness": 0.05, "mouthWidth": 0.45, "smile": 0.5,
                     "headTilt": 0, "gazeSide": 0.1},
         "sampleCount": 42}
        """#.utf8)
        let decoded = try JSONDecoder().decode(RestingBaseline.self, from: old)
        XCTAssertEqual(decoded, RestingBaseline(neutral: makeFace(brow: 0.5), sampleCount: 42))
        XCTAssertNil(decoded.restShape)

        // A resting shape that doesn't decode is dropped; one with a bad field keeps the others.
        let broken = try JSONDecoder().decode(RestingBaseline.self, from: Data(#"{"sampleCount": 3, "restShape": "x"}"#.utf8))
        XCTAssertEqual(broken.sampleCount, 3)
        XCTAssertNil(broken.restShape)
        let partial = try JSONDecoder().decode(RestingBaseline.self,
                                               from: Data(#"{"restShape": {"tongue": "x", "lipWidth": 0.8}}"#.utf8))
        XCTAssertEqual(partial.restShape, FaceShape(lipWidth: 0.8))
    }
}
