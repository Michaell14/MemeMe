import Foundation
import XCTest
@testable import MemeMeCore

final class PeakHoldTrackerTests: XCTestCase {
    /// A baseline past warm-up, so expressive frames never leak into it.
    private func makeTracker() -> PeakHoldTracker {
        PeakHoldTracker(baseline: RestingBaseline(sampleCount: 100))
    }

    /// Frame `step` of a 10 fps stream (timestamp = step / 10 s).
    private func frame(_ face: FaceFeatures?, _ step: Int, sharpness: Double = 1, pose: PoseFeatures? = nil,
                       shape: FaceShape? = nil) -> ExpressionSample {
        ExpressionSample(face: face, pose: pose, shape: shape, timestamp: Double(step) / 10, sharpness: sharpness)
    }

    /// A resting mouth's shape: a little lip color under the lower lip, the lip 0.1 eye distances thick.
    private let restingMouth = FaceShape(lowerLip: 0.1, tongue: 0.05)
    /// The tongue out over it: (0.3 − 0.05 − 0.12) / 0.25 = 0.52, + 0.3 for the lower lip twice as thick = 0.82.
    private let tongueOut = FaceShape(lowerLip: 0.2, tongue: 0.3)

    /// Calm frames (the resting face) on `steps`.
    private func relax(_ tracker: PeakHoldTracker, _ steps: ClosedRange<Int>, file: StaticString = #filePath, line: UInt = #line) {
        for step in steps {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, step)), "step \(step)", file: file, line: line)
        }
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
        XCTAssertEqual(config.newFaceHold, 0.6)
        XCTAssertEqual(config.rearmAfterCalm, 0.4)
        XCTAssertEqual(config.strongerRatio, 1.15)
        XCTAssertEqual(config.sameDirectionCosine, 0.85)
        XCTAssertEqual(config.minimumIntensity, 0.12)
        XCTAssertEqual(config.bufferWindow, 0.5)
        XCTAssertEqual(config.minimumGestureWithoutFace, 0.5)
        XCTAssertEqual(config.gestureGrace, 0.3)
        XCTAssertEqual(config.newPoseSimilarity, 0.6)
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

    func testADifferentFaceMustBeHeldForSixTenthsOfASecond() {
        let tracker = makeTracker()
        establishSurprise(tracker)

        XCTAssertFalse(tracker.ingest(frame(TestFaces.smile, 5)))
        XCTAssertTrue(tracker.candidateIsNewExpression)
        XCTAssertEqual(tracker.holdProgress, 0, accuracy: 1e-9)
        for step in 6...10 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.smile, step)), "step \(step)")
            XCTAssertTrue(tracker.candidateIsNewExpression, "step \(step)")
            XCTAssertEqual(tracker.query?.face, TestFaces.surprise, "step \(step)")
        }
        XCTAssertEqual(tracker.holdProgress, 0.5 / 0.6, accuracy: 1e-6)

        XCTAssertTrue(tracker.ingest(frame(TestFaces.smile, 11)))
        XCTAssertEqual(tracker.query?.face, TestFaces.smile)
        XCTAssertEqual(tracker.query?.timestamp, 1.1)
        XCTAssertEqual(tracker.queryIntensity, RestingBaseline().intensity(of: TestFaces.smile), accuracy: 1e-12)
        XCTAssertFalse(tracker.candidateIsNewExpression)
        XCTAssertEqual(tracker.holdProgress, 0)
    }

    func testThePeakIsChosenFromTheLastHalfSecondOnly() {
        let tracker = makeTracker()
        establishSurprise(tracker)
        // The first smile frame is the sharpest, but it is more than 0.5 s old when the hold completes (0.6 s).
        for step in 10...15 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.smile, step, sharpness: step == 10 ? 1 : 0.5)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.smile, 16, sharpness: 0.5)))
        XCTAssertEqual(tracker.query?.timestamp, 1.6)
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

        // Any expression now differs from the deadpan query, so it needs a new face's hold (0.6 s).
        XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, 2)))
        XCTAssertTrue(tracker.candidateIsNewExpression)
        for step in 3...7 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, step)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.surprise, 8)))
        XCTAssertEqual(tracker.query?.face, TestFaces.surprise)
        XCTAssertEqual(tracker.query?.timestamp, 0.8)
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

    func testClearHoldStartsTheNextHoldOver() {
        let tracker = makeTracker()
        XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, 1)))
        XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, 2)))
        XCTAssertGreaterThan(tracker.holdProgress, 0)

        // The capture view was open for a while; the same face afterwards is held for the full 0.3 s again.
        tracker.clearHold()
        XCTAssertEqual(tracker.holdProgress, 0)
        XCTAssertNil(tracker.candidate)
        for step in 30...32 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, step)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.surprise, 33)))
        XCTAssertEqual(tracker.query?.timestamp, 3.3)
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

    // MARK: Face cues

    func testATongueOutStartsASearchAfterTheShortHold() throws {
        // The seven numbers barely move (intensity ≈ 0.038, under the gate); the tongue cue 0.82 against the resting
        // shape makes the frame's intensity 0.8 × 0.82.
        let tracker = PeakHoldTracker(baseline: RestingBaseline(sampleCount: 100, restShape: restingMouth))
        let face = makeFace(mouth: 0.1)
        XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, 0, shape: restingMouth)))
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(face, step, shape: tongueOut)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(face, 4, shape: tongueOut)))
        let query = try XCTUnwrap(tracker.query)
        XCTAssertEqual(query.shape, tongueOut)
        XCTAssertEqual(tracker.queryIntensity, 0.656, accuracy: 1e-9)
        XCTAssertEqual(MoodClassifier.mood(for: query.face, pose: query.pose, shape: query.shape, baseline: tracker.baseline),
                       .tongueOut)

        // The same face without its shape is never held.
        let blind = makeTracker()
        for step in 1...10 {
            XCTAssertFalse(blind.ingest(frame(face, step)), "step \(step)")
            XCTAssertNil(blind.candidate, "step \(step)")
        }
        XCTAssertNil(blind.query)
    }

    func testCalmFramesTeachTheRestingShapeAndATongueOutBarelyMovesIt() {
        let tracker = makeTracker()
        XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, 1, shape: restingMouth)))
        XCTAssertEqual(tracker.baseline.restShape, restingMouth)
        XCTAssertEqual(tracker.baseline.sampleCount, 101)
        XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, 2, shape: tongueOut)))
        XCTAssertEqual(tracker.baseline.restShape?.tongue ?? 0, 0.0525, accuracy: 1e-12)       // 0.05 + 0.01 × 0.25
        XCTAssertEqual(tracker.baseline.restShape?.lowerLip ?? 0, 0.101, accuracy: 1e-12)      // 0.1 + 0.01 × 0.1
        XCTAssertEqual(tracker.baseline.sampleCount, 102)
    }

    func testATongueOutOnAHeldSmileIsANewExpression() {
        let tracker = PeakHoldTracker(baseline: RestingBaseline(sampleCount: 100, restShape: restingMouth))
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.smile, step, shape: restingMouth)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.smile, 4, shape: restingMouth)))

        // Still smiling, tongue out: a new expression of the face, held for 0.6 s.
        XCTAssertFalse(tracker.ingest(frame(TestFaces.smile, 5, shape: tongueOut)))
        XCTAssertTrue(tracker.candidateIsNewExpression)
        for step in 6...10 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.smile, step, shape: tongueOut)), "step \(step)")
            XCTAssertTrue(tracker.candidateIsNewExpression, "step \(step)")
            XCTAssertEqual(tracker.query?.shape, restingMouth, "step \(step)")
        }
        XCTAssertEqual(tracker.holdProgress, 0.5 / 0.6, accuracy: 1e-6)
        XCTAssertTrue(tracker.ingest(frame(TestFaces.smile, 11, shape: tongueOut)))
        XCTAssertEqual(tracker.query?.shape, tongueOut)
        XCTAssertEqual(tracker.query?.timestamp, 1.1)
        XCTAssertEqual(tracker.queryIntensity, 0.656, accuracy: 1e-9)
    }

    func testAClearCueOnAStrongHeldFaceIsANewExpression() {
        // A smirk (0.6 against the fixed values) on a strong surprise: the direction barely moves (cosine ≈ 0.90) and
        // the intensity stays the face's, so only the cue tells it apart.
        let smirk = FaceShape(cornerTilt: 0.13)
        let tracker = makeTracker()
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.strongSurprise, step)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.strongSurprise, 4)))
        for step in 5...10 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.strongSurprise, step, shape: smirk)), "step \(step)")
            XCTAssertTrue(tracker.candidateIsNewExpression, "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.strongSurprise, 11, shape: smirk)))
        XCTAssertEqual(tracker.query?.shape, smirk)

        // The query's own cue on the same face, even a stronger one (1), is the same expression, not 15 % stronger.
        for step in 12...30 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.strongSurprise, step, shape: FaceShape(cornerTilt: 0.2))), "step \(step)")
            XCTAssertEqual(tracker.holdProgress, 0, "step \(step)")
            XCTAssertFalse(tracker.candidateIsNewExpression, "step \(step)")
        }
        XCTAssertEqual(tracker.query?.timestamp, 1.1)
    }

    // MARK: Relaxing in between

    func testOneFrameOfACueDoesntNameAFaceHeldWithoutIt() {
        // A smile is the search; a strong surprise is held from 1.0 s; at 1.6 s, just when its 0.6 s are up, one frame
        // shows a smirk (0.6 against the fixed values). That frame starts a run of its own, so neither it nor the
        // surprise becomes the search then; the surprise, held again from 1.7 s, does at 2.3 s.
        let tracker = makeTracker()
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.smile, step)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.smile, 4)))
        for step in 10...15 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.strongSurprise, step)), "step \(step)")
        }
        XCTAssertFalse(tracker.ingest(frame(TestFaces.strongSurprise, 16, shape: FaceShape(cornerTilt: 0.13))))
        XCTAssertEqual(tracker.query?.face, TestFaces.smile)
        XCTAssertEqual(tracker.holdProgress, 0)
        for step in 17...22 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.strongSurprise, step)), "step \(step)")
            XCTAssertEqual(tracker.query?.face, TestFaces.smile, "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.strongSurprise, 23)))
        XCTAssertEqual(tracker.query?.face, TestFaces.strongSurprise)
        XCTAssertNil(tracker.query?.shape)
    }

    func testRelaxingFirstLetsTheNextFaceReplaceAfterTheShortHold() {
        let tracker = makeTracker()
        establishSurprise(tracker)
        // Calm for 0.4 s (steps 5...9), then a smile: it replaces the query after 0.3 s, as the first one did.
        relax(tracker, 5...9)
        for step in 10...12 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.smile, step)), "step \(step)")
            XCTAssertTrue(tracker.candidateIsNewExpression, "step \(step)")
        }
        XCTAssertEqual(tracker.holdProgress, 2.0 / 3.0, accuracy: 1e-6)
        XCTAssertTrue(tracker.ingest(frame(TestFaces.smile, 13)))
        XCTAssertEqual(tracker.query?.face, TestFaces.smile)
        XCTAssertEqual(tracker.query?.timestamp, 1.3)

        // A new query needs the face to relax again: the next face straight after it is held for 0.6 s.
        for step in 14...19 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, step)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.surprise, 20)))
        XCTAssertEqual(tracker.query?.face, TestFaces.surprise)
    }

    func testRelaxingTooBrieflyKeepsANewFacesHold() {
        let tracker = makeTracker()
        establishSurprise(tracker)
        relax(tracker, 5...8)      // 0.3 s
        for step in 9...14 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.smile, step)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.smile, 15)))
        XCTAssertEqual(tracker.query?.timestamp, 1.5)
    }

    func testRelaxingDoesntMakeTheSameFaceNewAndLastsUntilTheNextQuery() {
        let tracker = makeTracker()
        establishSurprise(tracker)
        relax(tracker, 5...9)
        // The same face again, no stronger: still ignored.
        for step in 10...19 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, step)), "step \(step)")
            XCTAssertEqual(tracker.holdProgress, 0, "step \(step)")
            XCTAssertFalse(tracker.candidateIsNewExpression, "step \(step)")
        }
        XCTAssertEqual(tracker.query?.timestamp, 0.4)
        // Holding it didn't use up the relaxing: a smile after it still needs only 0.3 s.
        for step in 20...22 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.smile, step)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.smile, 23)))
        XCTAssertEqual(tracker.query?.timestamp, 2.3)
    }

    func testSnapNeedsTheFaceToRelaxAgain() {
        let tracker = makeTracker()
        establishSurprise(tracker)
        relax(tracker, 5...9)
        XCTAssertTrue(tracker.snap())
        XCTAssertEqual(tracker.query?.timestamp, 0.9)
        for step in 10...15 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, step)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.surprise, 16)))
        XCTAssertEqual(tracker.query?.face, TestFaces.surprise)
    }

    func testTalkingNeverReplacesTheQuery() {
        let tracker = makeTracker()
        establishSurprise(tracker)
        let open = makeFace(mouth: 0.35)      // intensity ≈ 0.227
        // Relaxed long enough to re-arm, then talking: the mouth open for three frames at most, closed in between.
        relax(tracker, 5...9)
        for step in 10...60 {
            XCTAssertFalse(tracker.ingest(frame(step % 4 == 0 ? TestFaces.neutral : open, step)), "step \(step)")
        }
        XCTAssertEqual(tracker.query?.face, TestFaces.surprise)
        XCTAssertEqual(tracker.query?.timestamp, 0.4)
    }

    func testANewGestureIsHeldForASecondUnlessTheFaceRelaxedFirst() {
        let celebrating = TestPoses.features(TestPoses.both(TestPoses.up))
        let facepalm = TestPoses.features(TestPoses.body(left: TestPoses.onFace, right: TestPoses.rest.otherSide))
        let resting = TestPoses.features(TestPoses.both(TestPoses.rest))

        // Arms up, then straight into a facepalm hiding the face: a gesture after a gesture, held for a second.
        let tracker = makeTracker()
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, step, pose: celebrating)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.neutral, 4, pose: celebrating)))
        for step in 5...14 {
            XCTAssertFalse(tracker.ingest(frame(nil, step, pose: facepalm)), "step \(step)")
            XCTAssertTrue(tracker.candidateIsNewExpression, "step \(step)")
        }
        XCTAssertEqual(tracker.holdProgress, 0.9, accuracy: 1e-6)
        XCTAssertTrue(tracker.ingest(frame(nil, 15, pose: facepalm)))
        XCTAssertEqual(tracker.query?.pose, facepalm)

        // Arms down and the face calm for 0.4 s first: the facepalm replaces the query after 0.3 s.
        let relaxed = makeTracker()
        for step in 1...3 {
            XCTAssertFalse(relaxed.ingest(frame(TestFaces.neutral, step, pose: celebrating)), "step \(step)")
        }
        XCTAssertTrue(relaxed.ingest(frame(TestFaces.neutral, 4, pose: celebrating)))
        for step in 5...9 {
            XCTAssertFalse(relaxed.ingest(frame(TestFaces.neutral, step, pose: resting)), "step \(step)")
        }
        for step in 10...12 {
            XCTAssertFalse(relaxed.ingest(frame(nil, step, pose: facepalm)), "step \(step)")
        }
        XCTAssertTrue(relaxed.ingest(frame(nil, 13, pose: facepalm)))
        XCTAssertEqual(relaxed.query?.pose, facepalm)
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
