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
    }
}
