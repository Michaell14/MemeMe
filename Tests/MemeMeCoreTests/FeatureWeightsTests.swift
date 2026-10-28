import Foundation
import XCTest
@testable import MemeMeCore

final class FeatureWeightsTests: XCTestCase {
    func testDefaultsAndUniform() {
        let weights = FeatureWeights()
        XCTAssertEqual(weights.brows, 1)
        XCTAssertEqual(weights.eyes, 1)
        XCTAssertEqual(weights.mouth, 1)
        XCTAssertEqual(weights.pose, 0.15)
        XCTAssertEqual(FeatureWeights.uniform, FeatureWeights(brows: 1, eyes: 1, mouth: 1, pose: 0.15))
    }

    func testSubscriptReadsAndWritesRegions() {
        var weights = FeatureWeights(brows: 2, eyes: 3, mouth: 4, pose: 0.2)
        XCTAssertEqual(weights[.brows], 2)
        XCTAssertEqual(weights[.eyes], 3)
        XCTAssertEqual(weights[.mouth], 4)
        weights[.eyes] = 5
        XCTAssertEqual(weights.eyes, 5)
        XCTAssertEqual(weights.brows, 2)
        XCTAssertEqual(weights.pose, 0.2)
    }

    func testAutomaticScalesByTheLargestDeviation() {
        let weights = FeatureWeights.automatic(deviation: [.brows: 0.1, .eyes: 0.2, .mouth: 0.4], poseStrength: 0)
        XCTAssertEqual(weights.brows, 1.5, accuracy: 1e-9)    // 1 + 2 × 0.1 / 0.4
        XCTAssertEqual(weights.eyes, 2.0, accuracy: 1e-9)
        XCTAssertEqual(weights.mouth, 3.0, accuracy: 1e-9)
        XCTAssertEqual(weights.pose, 0.05, accuracy: 1e-12)    // a plain face leaves the pose a small say
    }

    func testAutomaticIsUniformForSmallDeviations() {
        let weights = FeatureWeights.automatic(deviation: [.brows: 0.01, .eyes: 0.02, .mouth: 0.04], poseStrength: 0.5)
        XCTAssertEqual(weights.brows, 1)
        XCTAssertEqual(weights.eyes, 1)
        XCTAssertEqual(weights.mouth, 1)
        XCTAssertEqual(weights.pose, 0.325, accuracy: 1e-12)  // 0.05 + 0.55 × 0.5
    }

    func testAutomaticThresholdAndMissingRegions() {
        let weights = FeatureWeights.automatic(deviation: [.brows: 0.05], poseStrength: 0.2)
        XCTAssertEqual(weights.brows, 3, accuracy: 1e-9)      // m = 0.05 is not below the threshold
        XCTAssertEqual(weights.eyes, 1, accuracy: 1e-9)       // missing regions count as 0
        XCTAssertEqual(weights.mouth, 1, accuracy: 1e-9)
        XCTAssertEqual(weights.pose, 0.16, accuracy: 1e-12)   // 0.05 + 0.55 × 0.2
    }

    func testAutomaticPoseShareIsClamped() {
        XCTAssertEqual(FeatureWeights.automatic(deviation: [:], poseStrength: 1).pose, 0.6, accuracy: 1e-12)
        XCTAssertEqual(FeatureWeights.automatic(deviation: [:], poseStrength: 2).pose, 0.6, accuracy: 1e-12)
        XCTAssertEqual(FeatureWeights.automatic(deviation: [:], poseStrength: 0.95).pose, 0.5725, accuracy: 1e-12)
        XCTAssertEqual(FeatureWeights.automatic(deviation: [:], poseStrength: 0).pose, 0.05, accuracy: 1e-12)
        XCTAssertEqual(FeatureWeights.automatic(deviation: [:], poseStrength: -1).pose, 0.05, accuracy: 1e-12)
        XCTAssertEqual(FeatureWeights.automatic(deviation: [:], poseStrength: .nan).pose, 0.05, accuracy: 1e-12)
    }

    func testAutomaticFromABaselineDeviation() {
        let deviation = RestingBaseline().deviation(of: makeFace(mouth: 0.65))   // mouth 0.4, others 0
        let weights = FeatureWeights.automatic(deviation: deviation, poseStrength: 0)
        XCTAssertEqual(weights.mouth, 3, accuracy: 1e-9)
        XCTAssertEqual(weights.brows, 1, accuracy: 1e-9)
        XCTAssertEqual(weights.eyes, 1, accuracy: 1e-9)
    }

    func testPinningSetsSixAndKeepsTheRest() {
        let base = FeatureWeights(brows: 1.5, eyes: 2, mouth: 3, pose: 0.3)
        let mouth = base.pinning([.mouth])
        XCTAssertEqual(mouth.mouth, 6)
        XCTAssertEqual(mouth.brows, 1.5)
        XCTAssertEqual(mouth.eyes, 2)
        XCTAssertEqual(mouth.pose, 0.3)

        let both = base.pinning([.eyes, .mouth])
        XCTAssertEqual(both.eyes, 6)
        XCTAssertEqual(both.mouth, 6)
        XCTAssertEqual(both.brows, 1.5)

        XCTAssertEqual(base.pinning([]), base)
    }
}
