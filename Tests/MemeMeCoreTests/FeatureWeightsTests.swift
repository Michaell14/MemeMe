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

    func testOverridingSetsTheEditorsWeightsAndKeepsTheRest() {
        let base = FeatureWeights(brows: 1.5, eyes: 2, mouth: 3, pose: 0.3)
        let edited = base.overriding([.mouth: 5, .brows: 0])
        XCTAssertEqual(edited.mouth, 5)
        XCTAssertEqual(edited.brows, 0)
        XCTAssertEqual(edited.eyes, 2)
        XCTAssertEqual(edited.pose, 0.3, "the pose's share stays")

        XCTAssertEqual(base.overriding([.eyes: -1]).eyes, 0, "never below 0")
        XCTAssertEqual(base.overriding([.eyes: .nan]).eyes, 0)
        XCTAssertEqual(base.overriding([:]), base)
    }

    func testAnIgnoredRegionLeavesTheRanking() {
        let query = makeFace(brow: 0.9, mouth: 0.05).vector
        let item = makeFace(brow: 0.1, mouth: 0.05).vector
        let all = Ranker.featureSimilarity(query, item, weights: .uniform)
        let browsIgnored = Ranker.featureSimilarity(query, item, weights: FeatureWeights.uniform.overriding([.brows: 0]))
        XCTAssertLessThan(all, 1)
        XCTAssertEqual(browsIgnored, 1, accuracy: 1e-9, "only the brows differ, and they don't count")
    }

    func testSummaryNamesWhatCounts() {
        XCTAssertEqual(FeatureWeights.summary(of: [.brows: 3, .eyes: 1.2, .mouth: 1.3]), "mostly your brows")
        XCTAssertEqual(FeatureWeights.summary(of: [.brows: 1, .eyes: 1, .mouth: 1.2]), "your whole face")
        XCTAssertEqual(FeatureWeights.summary(of: [.brows: 0, .eyes: 1, .mouth: 1]), "your eyes and mouth")
        XCTAssertEqual(FeatureWeights.summary(of: [.brows: 0, .eyes: 0, .mouth: 2]), "only your mouth")
        XCTAssertEqual(FeatureWeights.summary(of: [.brows: 0, .eyes: 1, .mouth: 4]),
                       "mostly your mouth · ignoring your brows")
        XCTAssertEqual(FeatureWeights.summary(of: [.brows: 5, .eyes: 0, .mouth: 0]), "only your brows")
        XCTAssertEqual(FeatureWeights.summary(of: [.brows: 0, .eyes: 0, .mouth: 0]), "every part ignored")
        XCTAssertEqual(FeatureWeights.summary(of: [:]), "every part ignored")
    }
}
