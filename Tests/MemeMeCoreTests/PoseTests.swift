import Foundation
import XCTest
@testable import MemeMeCore

final class PoseDescriptorTests: XCTestCase {
    private func descriptor(_ joints: BodyJoints, hand: HandShape? = nil) throws -> PoseDescriptor {
        try XCTUnwrap(PoseDescriptor(joints, hand: hand))
    }

    private func assertSameValues(_ a: PoseDescriptor, _ b: PoseDescriptor, accuracy: Double = 0.002,
                                  file: StaticString = #filePath, line: UInt = #line) {
        for dimension in PoseDescriptor.Dimension.allCases {
            switch (a[dimension], b[dimension]) {
            case let (x?, y?):
                XCTAssertEqual(x, y, accuracy: accuracy, "\(dimension)", file: file, line: line)
            case (nil, nil):
                break
            default:
                XCTFail("\(dimension): \(String(describing: a[dimension])) vs \(String(describing: b[dimension]))", file: file, line: line)
            }
        }
    }

    func testRestingArmsAreNoGesture() throws {
        let rest = try descriptor(TestPoses.both(TestPoses.rest))
        XCTAssertEqual(try XCTUnwrap(rest[.leftLift]), 0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(rest[.leftHead]), 1, accuracy: 0.001)
        XCTAssertLessThan(rest.gestureStrength, 0.05)
        XCTAssertTrue(rest.showsArms)
    }

    func testRaisedArmsAreAClearGesture() throws {
        let up = try descriptor(TestPoses.both(TestPoses.up))
        XCTAssertEqual(try XCTUnwrap(up[.leftLift]), 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(up[.rightLift]), 1, accuracy: 1e-9)
        XCTAssertGreaterThan(try XCTUnwrap(up[.leftElbowLift]), 0.85)
        XCTAssertEqual(up.gestureStrength, 1, accuracy: 1e-9)
    }

    func testOneHandOnTheFaceIsAClearGesture() throws {
        let facepalm = try descriptor(TestPoses.body(left: TestPoses.onFace, right: TestPoses.rest.otherSide))
        XCTAssertLessThan(try XCTUnwrap(facepalm[.leftHead]), 0.22)
        XCTAssertGreaterThan(facepalm.gestureStrength, 0.9)
    }

    func testSizeAndPlaceInTheImageDontMatter() throws {
        let big = try descriptor(TestPoses.both(TestPoses.up, scale: 0.2))
        let small = try descriptor(TestPoses.body(left: TestPoses.up, right: TestPoses.up.otherSide, origin: (x: 0.3, y: 0.3), scale: 0.1))
        assertSameValues(big, small)
    }

    func testTheImagesAspectIsCorrected() throws {
        let joints = TestPoses.body(left: TestPoses.up, right: TestPoses.rest.otherSide)
        let aspect = 1920.0 / 1080.0
        var readings: [BodyJoint: JointReading] = [:]
        for (joint, point) in joints.points {
            readings[joint] = JointReading(x: point.x / aspect, y: point.y, confidence: 0.9)
        }
        readings[.neck] = JointReading(x: 0.1, y: 0.1, confidence: 0.1)   // too unsure: dropped
        let wide = BodyJoints(readings: readings, imageWidth: 1920, imageHeight: 1080)
        XCTAssertNil(wide[.neck])
        XCTAssertEqual(wide.shortSide, 1)
        XCTAssertEqual(wide.shoulderConfidence, 0.9, accuracy: 1e-9)
        assertSameValues(try descriptor(wide), try descriptor(joints))
    }

    func testTiltIsMeasuredAndTakenOut() throws {
        let straight = try descriptor(TestPoses.both(TestPoses.up))
        let tilted = try descriptor(TestPoses.both(TestPoses.up, roll: 20 * Double.pi / 180))
        XCTAssertEqual(try XCTUnwrap(tilted[.shoulderTilt]), 2.0 / 3.0, accuracy: 0.002)
        for dimension in PoseDescriptor.Dimension.allCases where dimension != .shoulderTilt {
            XCTAssertEqual(try XCTUnwrap(tilted[dimension]), try XCTUnwrap(straight[dimension]), accuracy: 0.002, "\(dimension)")
        }
    }

    func testAMirroredImageMatchesFully() {
        let pose = TestPoses.features(TestPoses.body(left: TestPoses.up, right: TestPoses.rest.otherSide))
        let flipped = TestPoses.features(TestPoses.body(left: TestPoses.up, right: TestPoses.rest.otherSide, mirrored: true))
        XCTAssertEqual(PoseFeatures.similarity(query: pose, item: flipped), 1, accuracy: 0.01)
    }

    func testTheOtherArmMatchesThroughMirroring() {
        let leftUp = TestPoses.features(TestPoses.body(left: TestPoses.up, right: TestPoses.rest.otherSide))
        let rightUp = TestPoses.features(TestPoses.body(left: TestPoses.rest, right: TestPoses.up.otherSide))
        XCTAssertEqual(PoseFeatures.similarity(query: leftUp, item: rightUp), 1, accuracy: 0.01)
        let direct = PoseDescriptor.compare(try! XCTUnwrap(leftUp.descriptor), try! XCTUnwrap(rightUp.descriptor))
        XCTAssertLessThan(direct.similarity, 0.8)
    }

    func testAnArmOutOfFrameLowersCoverageNotSimilarity() throws {
        let both = try descriptor(TestPoses.both(TestPoses.up))
        let oneArm = try descriptor(TestPoses.body(left: TestPoses.up, right: nil))
        XCTAssertNil(oneArm[.rightLift])
        XCTAssertNil(oneArm[.wristGap])
        let match = PoseDescriptor.compare(both, oneArm)
        XCTAssertEqual(match.similarity, 1, accuracy: 0.01)
        XCTAssertEqual(match.coverage, 8 / 16.5, accuracy: 1e-9)    // left arm 7 + tilt 0.5 + head rise 0.5 of 16.5
    }

    func testATinyBodyOrNoShouldersHasNoDescriptor() {
        XCTAssertNil(PoseDescriptor(TestPoses.both(TestPoses.rest, scale: 0.01)))
        XCTAssertNil(PoseDescriptor(TestPoses.body(left: TestPoses.up, right: TestPoses.up.otherSide, shoulders: false)))
    }

    func testAFaceWithShouldersShowsNoArms() throws {
        let shoulders = try descriptor(TestPoses.body(left: nil, right: nil))
        XCTAssertFalse(shoulders.showsArms)
        XCTAssertNotNil(shoulders[.headRise])
        XCTAssertEqual(shoulders.gestureStrength, 0)
        XCTAssertFalse(TestPoses.features(TestPoses.body(left: nil, right: nil)).showsArms)
    }

    func testAClearHandSignIsAGesture() throws {
        let sign = try descriptor(TestPoses.both(TestPoses.rest), hand: HandShape(thumbsUp: 0.9))
        XCTAssertEqual(sign.gestureStrength, 0.9, accuracy: 1e-9)
        let fist = try descriptor(TestPoses.both(TestPoses.rest), hand: HandShape(fist: 1))
        XCTAssertLessThan(fist.gestureStrength, 0.05)
    }

    func testPosesRoundTripAndOlderPosesStillLoad() throws {
        let pose = TestPoses.features(TestPoses.both(TestPoses.up), hand: HandShape(thumbsUp: 0.9))
        XCTAssertNotNil(pose.descriptor)
        let decoded = try JSONDecoder().decode(PoseFeatures.self, from: JSONEncoder().encode(pose))
        XCTAssertEqual(decoded, pose)

        let legacy = try JSONDecoder().decode(PoseFeatures.self, from: Data(#"{"handsRaised":1,"armsSpread":0,"bodyVisible":1}"#.utf8))
        XCTAssertEqual(legacy, PoseFeatures(handsRaised: 1, armsSpread: 0, bodyVisible: 1))
        XCTAssertNil(legacy.descriptor)
        XCTAssertEqual(legacy.gestureStrength, 1)

        let damaged = #"{"handsRaised":1,"armsSpread":0,"bodyVisible":1,"descriptor":{"values":"x"}}"#
        let partly = try JSONDecoder().decode(PoseFeatures.self, from: Data(damaged.utf8))
        XCTAssertEqual(partly.handsRaised, 1)
        XCTAssertEqual(partly.descriptor?.showsArms, false)
    }

    func testOlderItemsHaveNoPoseRevision() throws {
        let json = #"{"id": "\#(UUID().uuidString)", "fileURL": "file:///tmp/a.png", "contentHash": "h"}"#
        let item = try JSONDecoder().decode(LibraryItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.poseRevision, 0)

        var current = makeItem(name: "a")
        current.poseRevision = LibraryItem.currentPoseRevision
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LibraryItem.self, from: encoder.encode(current))
        XCTAssertEqual(decoded.poseRevision, LibraryItem.currentPoseRevision)
    }

    // MARK: Whose pose

    func testTheBodyWithTheFaceIsChosen() {
        let near = TestPoses.body(left: TestPoses.up, right: TestPoses.up.otherSide, origin: (x: 0.3, y: 0.45))
        let far = TestPoses.body(left: TestPoses.rest, right: TestPoses.rest.otherSide, origin: (x: 0.75, y: 0.45))
        let unsure = BodyJoints(points: near.points, shortSide: 1, shoulderConfidence: 0.5)
        let face = PoseBox(minX: 0.25, minY: 0.55, maxX: 0.35, maxY: 0.7)
        XCTAssertEqual(BodyJoints.primary(of: [far, unsure], faceBox: face), unsure)
        XCTAssertEqual(BodyJoints.primary(of: [far, unsure], faceBox: nil), far)
        XCTAssertNil(BodyJoints.primary(of: [], faceBox: face))
    }

    func testOnlyTheBodysOwnHandsCount() {
        let body = TestPoses.both(TestPoses.up)
        let leftWrist = body[.leftWrist]!
        let own = TestHands.thumbsUp(at: leftWrist)
        let stranger = TestHands.thumbsUp(at: PosePoint(x: 0.05, y: 0.05))
        XCTAssertEqual(body.ownHands([own, stranger]), [own])
        let armless = TestPoses.body(left: nil, right: nil)
        XCTAssertEqual(armless.ownHands([own, stranger]).count, 2)
    }

    func testFaceBoxesAreAspectCorrected() {
        let box = PoseBox(normalizedX: 0.25, y: 0.5, width: 0.5, height: 0.25, imageWidth: 200, imageHeight: 100)
        XCTAssertEqual(box, PoseBox(minX: 0.5, minY: 0.5, maxX: 1.5, maxY: 0.75))
        XCTAssertTrue(box.contains(PosePoint(x: 1, y: 0.6)))
        XCTAssertFalse(box.contains(PosePoint(x: 0.4, y: 0.6)))
        XCTAssertTrue(box.grown(by: 0.2).contains(PosePoint(x: 0.4, y: 0.6)))
    }
}

final class HandShapeTests: XCTestCase {
    func testThumbsUp() throws {
        let shape = try XCTUnwrap(HandShape(TestHands.thumbsUp()))
        XCTAssertGreaterThan(shape.thumbsUp, 0.9)
        XCTAssertLessThan(shape.point, 0.1)
        XCTAssertLessThan(shape.openPalm, 0.1)
        XCTAssertGreaterThan(shape.fist, 0.9)
    }

    func testPointing() throws {
        let shape = try XCTUnwrap(HandShape(TestHands.pointing()))
        XCTAssertGreaterThan(shape.point, 0.9)
        XCTAssertLessThan(shape.thumbsUp, 0.1)
        XCTAssertLessThan(shape.peace, 0.1)
        XCTAssertLessThan(shape.fist, 0.1)
    }

    func testOpenPalm() throws {
        let shape = try XCTUnwrap(HandShape(TestHands.openPalm()))
        XCTAssertGreaterThan(shape.openPalm, 0.9)
        XCTAssertLessThan(shape.fist, 0.1)
        XCTAssertLessThan(shape.point, 0.1)
        XCTAssertLessThan(shape.thumbsUp, 0.1)
        XCTAssertLessThan(shape.signStrength, 0.1)
    }

    func testTooLittleOfAHandIsNoShape() {
        XCTAssertNil(HandShape(HandJoints(points: [:])))
        XCTAssertNil(HandShape(HandJoints(points: [.wrist: PosePoint(x: 0, y: 0), .indexTip: PosePoint(x: 1, y: 1)])))
    }

    func testStrongestTakesTheMostOfEachSign() {
        let combined = HandShape.strongest([HandShape(thumbsUp: 0.8, fist: 0.2), HandShape(point: 0.6, fist: 0.9)])
        XCTAssertEqual(combined, HandShape(thumbsUp: 0.8, point: 0.6, fist: 0.9))
        XCTAssertNil(HandShape.strongest([]))
    }
}

final class PoseMoodTests: XCTestCase {
    private func classify(_ face: FaceFeatures?, _ joints: BodyJoints, hand: HandShape? = nil) -> Mood {
        MoodClassifier.mood(for: face, pose: TestPoses.features(joints, hand: hand), baseline: RestingBaseline())
    }

    func testBothArmsUpIsACelebration() {
        XCTAssertEqual(classify(TestFaces.neutral, TestPoses.both(TestPoses.up)), .celebrate)
        XCTAssertEqual(classify(makeFace(mouth: 0.5, smile: 0.7), TestPoses.both(TestPoses.up)), .celebrate)
        XCTAssertEqual(classify(nil, TestPoses.both(TestPoses.up)), .celebrate)
        // Hands out of the top of the frame: the upper arms say it.
        XCTAssertEqual(classify(TestFaces.neutral, TestPoses.both(TestPoses.elbowUp)), .celebrate)
    }

    func testBothArmsUpWithAnOpenMouthIsScreaming() {
        XCTAssertEqual(classify(makeFace(mouth: 0.5), TestPoses.both(TestPoses.up)), .screaming)
    }

    func testBothHandsAtTheHeadIsMindBlown() {
        XCTAssertEqual(classify(TestFaces.neutral, TestPoses.both(TestPoses.atHead)), .mindBlown)
        XCTAssertEqual(classify(makeFace(mouth: 0.5), TestPoses.both(TestPoses.atHead)), .screaming)
    }

    func testAHandOverShutEyesOrAHiddenFaceIsAFacepalm() {
        let facepalm = TestPoses.body(left: TestPoses.onFace, right: TestPoses.rest.otherSide)
        XCTAssertEqual(classify(makeFace(eye: 0.3), facepalm), .facepalm)
        XCTAssertEqual(classify(nil, facepalm), .facepalm)
        // Eyes open: a hand near the face alone isn't a facepalm.
        XCTAssertEqual(classify(TestFaces.neutral, facepalm), .unimpressed)
    }

    func testHandsTogetherIsClapping() {
        XCTAssertEqual(classify(TestFaces.neutral, TestPoses.both(TestPoses.clap)), .clapping)
    }

    func testBentArmsOutLowIsAShrug() {
        XCTAssertEqual(classify(TestFaces.neutral, TestPoses.both(TestPoses.shrug)), .shrug)
    }

    func testHandSigns() throws {
        let thumbs = try XCTUnwrap(HandShape(TestHands.thumbsUp()))
        XCTAssertEqual(classify(TestFaces.neutral, TestPoses.both(TestPoses.rest), hand: thumbs), .thumbsUp)
        let pointing = try XCTUnwrap(HandShape(TestHands.pointing()))
        XCTAssertEqual(classify(TestFaces.neutral, TestPoses.both(TestPoses.rest), hand: pointing), .pointing)
        let open = try XCTUnwrap(HandShape(TestHands.openPalm()))
        XCTAssertEqual(classify(TestFaces.neutral, TestPoses.both(TestPoses.rest), hand: open), .unimpressed)
    }

    func testArmsAtRestOrNotSeenLeaveItToTheFace() {
        XCTAssertEqual(classify(TestFaces.neutral, TestPoses.both(TestPoses.rest)), .unimpressed)
        XCTAssertEqual(classify(makeFace(smile: 0.7), TestPoses.both(TestPoses.rest)), .happy)
        XCTAssertEqual(classify(TestFaces.neutral, TestPoses.body(left: nil, right: nil)), .unimpressed)
        XCTAssertEqual(classify(nil, TestPoses.body(left: nil, right: nil)), .reaction)
        XCTAssertEqual(classify(nil, TestPoses.both(TestPoses.rest)), .reaction)
    }
}

final class PoseRankingTests: XCTestCase {
    private let ranker = Ranker()

    func testAMatchingPoseBeatsAnUnknownOneWhichBeatsArmsAtRest() {
        let face = TestFaces.surprise
        let target = RestingBaseline().intensity(of: face)
        let celebrating = TestPoses.features(TestPoses.both(TestPoses.up))
        let query = ExpressionSample(face: face, pose: celebrating, timestamp: 0)
        let weights = FeatureWeights.automatic(deviation: RestingBaseline().deviation(of: face), poseStrength: celebrating.gestureStrength)
        XCTAssertEqual(weights.pose, 0.6, accuracy: 1e-9)

        let matching = makeItem(name: "matching", kind: .pack, face: face, pose: celebrating, intensity: target)
        let unknown = makeItem(name: "unknown", kind: .pack, face: face, intensity: target)
        let atRest = makeItem(name: "rest", kind: .pack, face: face, pose: TestPoses.features(TestPoses.both(TestPoses.rest)), intensity: target)
        let results = ranker.rank([atRest, unknown, matching], query: .expression(query, weights: weights))
        XCTAssertEqual(results.map { $0.item.displayName }, ["matching", "unknown", "rest"])
        XCTAssertEqual(results[0].score, 1, accuracy: 0.01)
        XCTAssertEqual(results[1].score, 0.706, accuracy: 0.001)   // 0.7 × (0.4 + 0.6 × 0.3) + 0.3
    }

    func testAPlainFaceBarelyMindsThePose() {
        let face = TestFaces.surprise
        let target = RestingBaseline().intensity(of: face)
        let query = ExpressionSample(face: face, pose: TestPoses.features(TestPoses.body(left: nil, right: nil)), timestamp: 0)
        let weights = FeatureWeights.automatic(deviation: RestingBaseline().deviation(of: face), poseStrength: 0)
        let posing = makeItem(name: "posing", kind: .pack, face: face, pose: TestPoses.features(TestPoses.both(TestPoses.up)), intensity: target)
        let plain = makeItem(name: "plain", kind: .pack, face: face, intensity: target)
        let posingScore = ranker.expressionScore(item: posing, sample: query, weights: weights)
        let plainScore = ranker.expressionScore(item: plain, sample: query, weights: weights)
        XCTAssertEqual(plainScore, 1, accuracy: 1e-9)
        XCTAssertLessThan(posingScore, plainScore)
        XCTAssertGreaterThan(posingScore, 0.96)    // at most 0.7 × 0.05 lower
    }

    func testAHiddenFaceIsMatchedByItsPose() {
        let facepalm = TestPoses.features(TestPoses.body(left: TestPoses.onFace, right: TestPoses.rest.otherSide))
        let query = ExpressionSample(face: nil, pose: facepalm, timestamp: 0)
        let weights = FeatureWeights.automatic(deviation: [:], poseStrength: facepalm.gestureStrength)
        let same = makeItem(name: "same", kind: .pack, pose: facepalm, intensity: 0.3)
        let other = makeItem(name: "other", kind: .pack, pose: TestPoses.features(TestPoses.both(TestPoses.up)), intensity: 0.3)
        let noBody = makeItem(name: "noBody", kind: .pack, intensity: 0.3)
        let sameScore = ranker.expressionScore(item: same, sample: query, weights: weights)
        XCTAssertEqual(sameScore, 0.86, accuracy: 0.005)     // 0.7 × (0.4 × 0.5 + 0.6 × 1) + 0.3
        XCTAssertGreaterThan(sameScore, ranker.expressionScore(item: other, sample: query, weights: weights))
        XCTAssertGreaterThan(sameScore, ranker.expressionScore(item: noBody, sample: query, weights: weights))
    }
}

final class PoseTrackingTests: XCTestCase {
    private func frame(_ face: FaceFeatures?, _ step: Int, pose: PoseFeatures?) -> ExpressionSample {
        ExpressionSample(face: face, pose: pose, timestamp: Double(step) / 10)
    }

    private let facepalm = TestPoses.features(TestPoses.body(left: TestPoses.onFace, right: TestPoses.rest.otherSide))
    private let celebrating = TestPoses.features(TestPoses.both(TestPoses.up))

    func testAGestureHidingTheFaceCanBeTheQuery() {
        let tracker = PeakHoldTracker(baseline: RestingBaseline(sampleCount: 100))
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(nil, step, pose: facepalm)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(nil, 4, pose: facepalm)))
        XCTAssertNil(tracker.query?.face)
        XCTAssertEqual(tracker.queryIntensity, 0.8, accuracy: 1e-9)
        XCTAssertNil(tracker.lastFaceTimestamp)
        XCTAssertEqual(tracker.lastSeenTimestamp, 0.4)
        XCTAssertEqual(MoodClassifier.mood(for: nil, pose: tracker.query?.pose, baseline: tracker.baseline), .facepalm)
    }

    func testNoFaceAndNoClearGestureHoldsNothing() {
        let tracker = PeakHoldTracker(baseline: RestingBaseline(sampleCount: 100))
        let resting = TestPoses.features(TestPoses.both(TestPoses.rest))
        for step in 1...6 {
            XCTAssertFalse(tracker.ingest(frame(nil, step, pose: resting)))
        }
        XCTAssertNil(tracker.query)
        XCTAssertNil(tracker.candidate)
        XCTAssertNil(tracker.lastSeenTimestamp)
    }

    func testADifferentGestureIsANewExpression() {
        let tracker = PeakHoldTracker(baseline: RestingBaseline(sampleCount: 100))
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, step, pose: celebrating)))
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.neutral, 4, pose: celebrating)))
        XCTAssertEqual(tracker.query?.pose, celebrating)

        // Same face, another gesture: held for the full second a new expression needs.
        XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, 5, pose: facepalm)))
        XCTAssertTrue(tracker.candidateIsNewExpression)
        for step in 6...14 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, step, pose: facepalm)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.neutral, 15, pose: facepalm)))
        XCTAssertEqual(tracker.query?.pose, facepalm)
    }
}
