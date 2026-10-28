import Foundation
import XCTest
@testable import MemeMeCore

final class PeakHoldTrackerTests: XCTestCase {
    /// A baseline past warm-up, so expressive frames never leak into it.
    private func makeTracker() -> PeakHoldTracker {
        PeakHoldTracker(baseline: RestingBaseline(sampleCount: 100))
    }

    /// Frame `step` of a 10 fps stream (timestamp = step / 10 s).
    private func frame(_ face: FaceFeatures?, _ step: Int, sharpness: Double = 1, pose: PoseFeatures? = nil) -> ExpressionSample {
        ExpressionSample(face: face, pose: pose, timestamp: Double(step) / 10, sharpness: sharpness)
    }

    /// Holds the surprise face on steps 1...4; it becomes the query on step 4 (0.3 s after step 1).
    private func establishSurprise(_ tracker: PeakHoldTracker, file: StaticString = #filePath, line: UInt = #line) {
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, step)), file: file, line: line)
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.surprise, 4)), file: file, line: line)
        XCTAssertEqual(tracker.query?.timestamp, 0.4, file: file, line: line)
    }

    func testConfigDefaults() {
        let config = PeakHoldConfig()
        XCTAssertEqual(config.holdDuration, 0.3)
        XCTAssertEqual(config.newExpressionHold, 1.0)
        XCTAssertEqual(config.strongerRatio, 1.15)
        XCTAssertEqual(config.sameDirectionCosine, 0.85)
        XCTAssertEqual(config.minimumIntensity, 0.12)
        XCTAssertEqual(config.bufferWindow, 0.5)
    }

    func testInitialHoldTakesThreeHundredMilliseconds() {
        let tracker = makeTracker()
        XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, 0)))
        XCTAssertNil(tracker.query)
        XCTAssertEqual(tracker.queryIntensity, 0)
        XCTAssertEqual(tracker.holdProgress, 0)

        XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, 1)))
        XCTAssertEqual(tracker.holdProgress, 0, accuracy: 1e-9)
        XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, 2)))
        XCTAssertEqual(tracker.holdProgress, 1.0 / 3.0, accuracy: 1e-6)
        XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, 3)))
        XCTAssertEqual(tracker.holdProgress, 2.0 / 3.0, accuracy: 1e-6)
        XCTAssertFalse(tracker.candidateIsNewExpression)
        XCTAssertNil(tracker.query)

        XCTAssertTrue(tracker.ingest(frame(TestFaces.surprise, 4)))
        XCTAssertEqual(tracker.query?.face, TestFaces.surprise)
        XCTAssertEqual(tracker.query?.timestamp, 0.4)
        XCTAssertEqual(tracker.queryIntensity, RestingBaseline().intensity(of: TestFaces.surprise), accuracy: 1e-12)
        XCTAssertEqual(tracker.holdProgress, 0)
        XCTAssertFalse(tracker.candidateIsNewExpression)
    }

    func testTheCandidateIsTheStrongestFrameBeingHeld() {
        let tracker = makeTracker()
        tracker.ingest(frame(TestFaces.neutral, 0))
        XCTAssertNil(tracker.candidate)
        tracker.ingest(frame(TestFaces.mildSurprise, 1))
        XCTAssertEqual(tracker.candidate?.timestamp, 0.1)
        tracker.ingest(frame(TestFaces.surprise, 2))
        XCTAssertEqual(tracker.candidate?.face, TestFaces.surprise)
        tracker.ingest(frame(TestFaces.mildSurprise, 3))
        XCTAssertEqual(tracker.candidate?.timestamp, 0.2)
        // Becoming the query, relaxing and losing the face all clear it.
        XCTAssertTrue(tracker.ingest(frame(TestFaces.surprise, 4)))
        XCTAssertNil(tracker.candidate)
        tracker.ingest(frame(TestFaces.smile, 5))
        XCTAssertNotNil(tracker.candidate)
        tracker.ingest(frame(TestFaces.neutral, 6))
        XCTAssertNil(tracker.candidate)
        tracker.ingest(frame(TestFaces.smile, 7))
        XCTAssertNotNil(tracker.candidate)
        tracker.ingest(frame(nil, 8))
        XCTAssertNil(tracker.candidate)
    }

    func testTheSharpestFrameOfTheHoldBecomesTheQuery() {
        let tracker = makeTracker()
        let sharpness = [0.5, 1.0, 0.6, 0.7]
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, step, sharpness: sharpness[step - 1])))
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.surprise, 4, sharpness: sharpness[3])))
        XCTAssertEqual(tracker.query?.timestamp, 0.2)
        XCTAssertEqual(tracker.query?.sharpness, 1.0)
    }

    func testADifferentExpressionMustBeHeldForOneSecond() {
        let tracker = makeTracker()
        establishSurprise(tracker)

        XCTAssertFalse(tracker.ingest(frame(TestFaces.smile, 5)))
        XCTAssertTrue(tracker.candidateIsNewExpression)
        XCTAssertEqual(tracker.holdProgress, 0, accuracy: 1e-9)
        for step in 6...14 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.smile, step)), "step \(step)")
            XCTAssertTrue(tracker.candidateIsNewExpression, "step \(step)")
            XCTAssertEqual(tracker.query?.face, TestFaces.surprise, "step \(step)")
        }
        XCTAssertEqual(tracker.holdProgress, 0.9, accuracy: 1e-6)

        XCTAssertTrue(tracker.ingest(frame(TestFaces.smile, 15)))
        XCTAssertEqual(tracker.query?.face, TestFaces.smile)
        XCTAssertEqual(tracker.query?.timestamp, 1.5)
        XCTAssertEqual(tracker.queryIntensity, RestingBaseline().intensity(of: TestFaces.smile), accuracy: 1e-12)
        XCTAssertFalse(tracker.candidateIsNewExpression)
        XCTAssertEqual(tracker.holdProgress, 0)
    }

    func testThePeakIsChosenFromTheLastHalfSecondOnly() {
        let tracker = makeTracker()
        establishSurprise(tracker)
        // The first smile frame is the sharpest, but it is more than 0.5 s old when the hold completes.
        for step in 10...19 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.smile, step, sharpness: step == 10 ? 1 : 0.5)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.smile, 20, sharpness: 0.5)))
        XCTAssertEqual(tracker.query?.timestamp, 2.0)
        XCTAssertEqual(tracker.query?.sharpness, 0.5)
    }

    func testAStrongerVersionOfTheSameExpressionReplacesAfterTheShortHold() {
        let tracker = makeTracker()
        establishSurprise(tracker)
        let firstIntensity = tracker.queryIntensity

        for step in 5...7 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.strongSurprise, step)), "step \(step)")
            XCTAssertFalse(tracker.candidateIsNewExpression, "step \(step)")
        }
        XCTAssertEqual(tracker.holdProgress, 2.0 / 3.0, accuracy: 1e-6)
        XCTAssertEqual(tracker.query?.face, TestFaces.surprise)

        XCTAssertTrue(tracker.ingest(frame(TestFaces.strongSurprise, 8)))
        XCTAssertEqual(tracker.query?.face, TestFaces.strongSurprise)
        XCTAssertEqual(tracker.query?.timestamp, 0.8)
        XCTAssertEqual(tracker.queryIntensity, firstIntensity * 1.5, accuracy: 1e-9)
    }

    func testAWeakerOrEqualVersionOfTheSameExpressionIsIgnored() {
        let tracker = makeTracker()
        establishSurprise(tracker)

        for step in 5...20 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.slightlyStrongerSurprise, step)), "step \(step)")   // only 1.1×
            XCTAssertEqual(tracker.holdProgress, 0, "step \(step)")
            XCTAssertFalse(tracker.candidateIsNewExpression, "step \(step)")
        }
        for step in 21...40 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, step)), "step \(step)")
            XCTAssertEqual(tracker.holdProgress, 0, "step \(step)")
        }
        XCTAssertEqual(tracker.query?.face, TestFaces.surprise)
        XCTAssertEqual(tracker.query?.timestamp, 0.4)
    }

    func testSnapMakesEvenANeutralFaceTheQuery() {
        let tracker = makeTracker()
        XCTAssertFalse(tracker.snap())                         // no face seen yet
        XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, 1)))
        XCTAssertNil(tracker.query)

        XCTAssertTrue(tracker.snap())
        XCTAssertEqual(tracker.query?.face, TestFaces.neutral)
        XCTAssertEqual(tracker.query?.timestamp, 0.1)
        XCTAssertEqual(tracker.queryIntensity, 0)
        XCTAssertFalse(tracker.snap())                         // already the query

        // Any expression now differs from the deadpan query, so it needs the long hold.
        XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, 2)))
        XCTAssertTrue(tracker.candidateIsNewExpression)
        for step in 3...11 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, step)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.surprise, 12)))
        XCTAssertEqual(tracker.query?.face, TestFaces.surprise)
        XCTAssertEqual(tracker.query?.timestamp, 1.2)
    }

    func testSnapUsesTheLastFrameThatHadAFace() {
        let tracker = makeTracker()
        XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, 1)))
        XCTAssertFalse(tracker.ingest(frame(nil, 2)))
        XCTAssertTrue(tracker.snap())
        XCTAssertEqual(tracker.query?.timestamp, 0.1)
        XCTAssertEqual(tracker.queryIntensity, RestingBaseline().intensity(of: TestFaces.surprise), accuracy: 1e-12)
        XCTAssertEqual(tracker.lastSample?.timestamp, 0.2)
    }

    func testLosingTheFaceClearsHoldProgress() {
        let tracker = makeTracker()
        XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, 1)))
        XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, 2)))
        XCTAssertGreaterThan(tracker.holdProgress, 0)

        XCTAssertFalse(tracker.ingest(frame(nil, 3)))
        XCTAssertEqual(tracker.holdProgress, 0)
        XCTAssertNotNil(tracker.lastSample)
        XCTAssertNil(tracker.lastSample?.face)
        XCTAssertEqual(tracker.lastSample?.timestamp, 0.3)
        XCTAssertEqual(tracker.lastFaceTimestamp, 0.2)

        // The hold starts over from the next face.
        XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, 4)))
        XCTAssertEqual(tracker.holdProgress, 0, accuracy: 1e-9)
        XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, 5)))
        XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, 6)))
        XCTAssertNil(tracker.query)
        XCTAssertTrue(tracker.ingest(frame(TestFaces.surprise, 7)))
        XCTAssertEqual(tracker.query?.timestamp, 0.7)
        XCTAssertEqual(tracker.lastFaceTimestamp, 0.7)
    }

    func testRelaxingBelowTheMinimumClearsTheCandidate() {
        let tracker = makeTracker()
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, step)))
        }
        XCTAssertEqual(tracker.holdProgress, 2.0 / 3.0, accuracy: 1e-6)
        XCTAssertFalse(tracker.ingest(frame(makeFace(brow: 0.5), 4)))      // intensity ≈ 0.038 < 0.12
        XCTAssertEqual(tracker.holdProgress, 0)
        XCTAssertNil(tracker.query)

        for step in 5...7 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, step)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.surprise, 8)))
        XCTAssertEqual(tracker.query?.timestamp, 0.8)
    }

    func testBodyLanguageAloneCanBeTheExpression() {
        let tracker = makeTracker()
        let handsUp = PoseFeatures(handsRaised: 1, armsSpread: 0, bodyVisible: 1)
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, step, pose: handsUp)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.neutral, 4, pose: handsUp)))
        XCTAssertEqual(tracker.queryIntensity, 0.8, accuracy: 1e-12)     // 0.8 × activity (a pose measured the old way)
        XCTAssertEqual(tracker.query?.pose, handsUp)
    }

    func testCalmFramesTeachTheBaseline() {
        let tracker = PeakHoldTracker()
        XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, 1)))
        XCTAssertEqual(tracker.baseline.sampleCount, 1)
        XCTAssertFalse(tracker.ingest(frame(makeFace(brow: 0.55), 2)))
        XCTAssertEqual(tracker.baseline.sampleCount, 2)
        XCTAssertEqual(tracker.baseline.neutral.browRaise, 0.47, accuracy: 1e-9)
        XCTAssertFalse(tracker.ingest(frame(TestFaces.smile, 3)))          // expressive: not learned
        XCTAssertEqual(tracker.baseline.sampleCount, 2)
    }

    func testResetClearsQueryAndCandidateButKeepsTheBaseline() {
        let tracker = PeakHoldTracker()
        XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, 0)))
        establishSurprise(tracker)
        XCTAssertFalse(tracker.ingest(frame(TestFaces.smile, 5)))
        XCTAssertTrue(tracker.candidateIsNewExpression)
        let learned = tracker.baseline

        tracker.reset()
        XCTAssertNil(tracker.query)
        XCTAssertEqual(tracker.queryIntensity, 0)
        XCTAssertEqual(tracker.holdProgress, 0)
        XCTAssertFalse(tracker.candidateIsNewExpression)
        XCTAssertEqual(tracker.baseline, learned)
        XCTAssertEqual(tracker.baseline.sampleCount, 1)

        // With no query, the next held face only needs the short hold.
        for step in 6...8 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.smile, step)), "step \(step)")
            XCTAssertFalse(tracker.candidateIsNewExpression, "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.smile, 9)))
        XCTAssertEqual(tracker.query?.face, TestFaces.smile)
    }

    func testCustomConfiguration() {
        var config = PeakHoldConfig()
        config.holdDuration = 0.1
        let tracker = PeakHoldTracker(baseline: RestingBaseline(sampleCount: 100), config: config)
        XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, 1)))
        XCTAssertTrue(tracker.ingest(frame(TestFaces.surprise, 2)))
        XCTAssertEqual(tracker.config.holdDuration, 0.1)
    }
}
