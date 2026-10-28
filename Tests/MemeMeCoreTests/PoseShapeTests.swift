import Foundation
import XCTest
@testable import MemeMeCore

/// Full-body poses, in shoulder widths from the middle of the shoulders (x toward the person's left, y up).
enum FullBodyPoses {
    /// The left hip; the right one mirrored.
    static let hips = (x: 0.32, y: -1.35)
    static let rest = TestPoses.rest

    static let tPose = TestPoses.both(TestArm(elbow: (x: 1.3, y: 0), wrist: (x: 2.05, y: 0)))
    static let flex = TestPoses.both(TestArm(elbow: (x: 1.25, y: 0.1), wrist: (x: 1.0, y: 0.85)))
    static let dab = TestPoses.body(left: TestArm(elbow: (x: 1.2, y: 0.6), wrist: (x: 1.9, y: 1.2)),
                                    right: TestArm(elbow: (x: -0.05, y: 0.55), wrist: (x: 0.7, y: 0.95)))
    static let handOnHip = TestArm(elbow: (x: 1.05, y: -0.58), wrist: (x: 0.55, y: -1.1))
    static let handsOnHips = TestPoses.body(left: handOnHip, right: handOnHip.otherSide, hips: hips)
    static let oneHandOnHip = TestPoses.body(left: handOnHip, right: rest.otherSide, hips: hips)
    static let crossedLeft = TestArm(elbow: (x: 0.62, y: -0.72), wrist: (x: -0.4, y: -0.55))
    static let crossedRight = TestArm(elbow: (x: -0.62, y: -0.72), wrist: (x: 0.42, y: -0.6))
    static let armsCrossed = TestPoses.body(left: crossedLeft, right: crossedRight, hips: hips)
    static let straightUp = TestArm(elbow: (x: 0.7, y: 0.85), wrist: (x: 0.8, y: 1.75))
    static let pickMe = TestPoses.body(left: straightUp, right: rest.otherSide)
    static let hello = TestPoses.body(left: TestArm(elbow: (x: 1.0, y: -0.05), wrist: (x: 1.05, y: 0.75)), right: rest.otherSide)
    static let ohNo = TestPoses.both(TestArm(elbow: (x: 1.0, y: 0.75), wrist: (x: 0.18, y: 1.15)))
    static let bow = TestPoses.both(TestArm(elbow: (x: 0.55, y: -0.6), wrist: (x: 0.5, y: -1.0)),
                                    hips: (x: 0.32, y: -0.55), head: (x: 0, y: -0.75))
    static let starJump = TestPoses.both(TestArm(elbow: (x: 1.0, y: 0.6), wrist: (x: 1.5, y: 1.25)))
    /// Arms straight out in front at shoulder height: a strong pose without a word.
    static let zombie = TestPoses.both(TestArm(elbow: (x: 0.72, y: -0.02), wrist: (x: 0.9, y: -0.02)))
}

extension TestPoses {
    /// Both arms the same way, with hips (nil: not seen) and the head moved.
    static func both(_ arm: TestArm, hips: (x: Double, y: Double)?, head: (x: Double, y: Double) = (x: 0, y: 0)) -> BodyJoints {
        body(left: arm, right: arm.otherSide, hips: hips, head: head)
    }
}

final class PoseShapeDescriptorTests: XCTestCase {
    private func descriptor(_ joints: BodyJoints) throws -> PoseDescriptor {
        try XCTUnwrap(PoseDescriptor(joints))
    }

    private func value(_ pose: PoseDescriptor, _ dimension: PoseDescriptor.Dimension) throws -> Double {
        try XCTUnwrap(pose[dimension], "\(dimension)")
    }

    func testTheNewNumbers() throws {
        let crossed = try descriptor(FullBodyPoses.armsCrossed)
        XCTAssertEqual(try value(crossed, .leftCross), 0.45, accuracy: 0.002)
        XCTAssertEqual(try value(crossed, .rightCross), 0.46, accuracy: 0.002)
        XCTAssertEqual(try value(crossed, .leftElbowOut), 0.248, accuracy: 0.002)
        XCTAssertEqual(try value(crossed, .torsoLength), 0.675, accuracy: 0.002)
        XCTAssertEqual(try value(crossed, .leftLift), 0.271, accuracy: 0.002)
        XCTAssertEqual(try value(crossed, .leftElbowBend), 0.605, accuracy: 0.002)
        XCTAssertEqual(try value(crossed, .leftForearmRise), 0.585, accuracy: 0.002)

        let akimbo = try descriptor(FullBodyPoses.handsOnHips)
        XCTAssertEqual(try value(akimbo, .leftElbowOut), 0.42, accuracy: 0.002)
        XCTAssertEqual(try value(akimbo, .leftOut), 0.22, accuracy: 0.002)
        XCTAssertEqual(try value(akimbo, .leftElbowLift), 0.242, accuracy: 0.002)
        XCTAssertEqual(try value(akimbo, .leftLift), 0.114, accuracy: 0.002)
        XCTAssertEqual(try value(akimbo, .torsoLength), 0.675, accuracy: 0.002)

        let dab = try descriptor(FullBodyPoses.dab)
        XCTAssertEqual(try value(dab, .rightCross), 0.6, accuracy: 0.002)
        XCTAssertEqual(try value(dab, .leftCross), 0, accuracy: 0.002)

        XCTAssertEqual(try value(try descriptor(FullBodyPoses.tPose), .leftElbowOut), 0.52, accuracy: 0.002)

        let bow = try descriptor(FullBodyPoses.bow)
        XCTAssertEqual(try value(bow, .torsoLength), 0.275, accuracy: 0.002)
        XCTAssertEqual(try value(bow, .headRise), 0.007, accuracy: 0.002)

        XCTAssertNil(try descriptor(FullBodyPoses.tPose)[.torsoLength], "no hips seen")
    }

    func testCrossingIsTheSameInAMirroredImageAndSwapsWithTheArms() throws {
        for joints in [FullBodyPoses.armsCrossed, FullBodyPoses.dab] {
            let pose = try descriptor(joints)
            var flippedPoints: [BodyJoint: PosePoint] = [:]
            for (joint, point) in joints.points {
                flippedPoints[joint] = PosePoint(x: 1 - point.x, y: point.y)
            }
            let flipped = try descriptor(BodyJoints(points: flippedPoints))
            for dimension in PoseDescriptor.Dimension.allCases {
                XCTAssertEqual(pose[dimension] ?? -1, flipped[dimension] ?? -1, accuracy: 0.002, "\(dimension)")
            }
        }
        let leftOverRight = try descriptor(TestPoses.body(left: FullBodyPoses.crossedLeft, right: TestPoses.rest.otherSide))
        let rightOverLeft = try descriptor(TestPoses.body(left: TestPoses.rest, right: FullBodyPoses.crossedLeft.otherSide))
        for dimension in PoseDescriptor.Dimension.allCases {
            XCTAssertEqual(leftOverRight.mirrored[dimension] ?? -1, rightOverLeft[dimension] ?? -1, accuracy: 0.002, "\(dimension)")
        }
    }

    func testEveryNumberHasAWeight() {
        XCTAssertEqual(PoseDescriptor.weights.count, PoseDescriptor.count)
        XCTAssertEqual(PoseDescriptor.count, 20)
    }

    func testDescriptorsStoredWithThirteenNumbersStillLoadAndCompare() throws {
        let current = try descriptor(FullBodyPoses.handsOnHips)
        let older = Array(current.values.prefix(13))
        let json = try JSONEncoder().encode(["values": older])
        let decoded = try JSONDecoder().decode(PoseDescriptor.self, from: json)
        XCTAssertEqual(decoded.values.count, PoseDescriptor.count)
        XCTAssertTrue(decoded.values[13...].allSatisfy { $0 == nil })
        XCTAssertEqual(PoseDescriptor.compare(current, current).coverage, 1, accuracy: 1e-9)
        // The torso counts only when both have it: what's missing is the crossing, the elbows and the forearms.
        let match = PoseDescriptor.compare(current, decoded)
        XCTAssertEqual(match.similarity, 1, accuracy: 1e-9)
        XCTAssertEqual(match.coverage, 16.5 / 20.5, accuracy: 1e-9)
    }

    func testShapesCloseToRestGetTheShapeStrength() throws {
        for joints in [FullBodyPoses.handsOnHips, FullBodyPoses.armsCrossed, FullBodyPoses.bow] {
            let pose = try descriptor(joints)
            XCTAssertLessThan(pose.armStrength, 0.4)
            XCTAssertEqual(pose.gestureStrength, PoseDescriptor.shapeStrength, accuracy: 1e-9)
        }
        let withoutHips = try descriptor(TestPoses.body(left: FullBodyPoses.handOnHip, right: FullBodyPoses.handOnHip.otherSide))
        XCTAssertNil(withoutHips.bodyShape, "elbows wide with the hands low could be on a desk")
        XCTAssertEqual(withoutHips.gestureStrength, 0, accuracy: 1e-9)
        XCTAssertEqual(try descriptor(FullBodyPoses.tPose).gestureStrength, 0.993, accuracy: 0.002)
        XCTAssertEqual(try descriptor(FullBodyPoses.hello).gestureStrength, 0.837, accuracy: 0.002)
        XCTAssertEqual(try descriptor(TestPoses.both(TestPoses.rest, hips: FullBodyPoses.hips)).gestureStrength, 0, accuracy: 1e-9)
    }
}

final class PoseShapeMoodTests: XCTestCase {
    private func gestureWord(_ face: FaceFeatures?, _ joints: BodyJoints, hand: HandShape? = nil) -> Mood? {
        guard let pose = PoseDescriptor(joints, hand: hand) else { return nil }
        return MoodClassifier.gestureMood(pose, face: face, baseline: RestingBaseline())
    }

    private func flipped(_ joints: BodyJoints) -> BodyJoints {
        var points: [BodyJoint: PosePoint] = [:]
        for (joint, point) in joints.points {
            points[joint] = PosePoint(x: 1 - point.x, y: point.y)
        }
        return BodyJoints(points: points)
    }

    func testFullBodyPosesHaveTheirOwnWords() {
        let cases: [(String, BodyJoints, Mood)] = [
            ("t-pose", FullBodyPoses.tPose, .tPose),
            ("flex", FullBodyPoses.flex, .flex),
            ("dab", FullBodyPoses.dab, .dab),
            ("hands on hips", FullBodyPoses.handsOnHips, .handsOnHips),
            ("one hand on a hip", FullBodyPoses.oneHandOnHip, .handsOnHips),
            ("arms crossed", FullBodyPoses.armsCrossed, .armsCrossed),
            ("arms crossed, no hips", TestPoses.body(left: FullBodyPoses.crossedLeft, right: FullBodyPoses.crossedRight), .armsCrossed),
            ("pick me", FullBodyPoses.pickMe, .pickMe),
            ("pick me, the other arm unseen", TestPoses.body(left: FullBodyPoses.straightUp, right: nil), .pickMe),
            ("hello", FullBodyPoses.hello, .hello),
            ("oh no", FullBodyPoses.ohNo, .ohNo),
            ("bow", FullBodyPoses.bow, .bow),
            ("star jump", FullBodyPoses.starJump, .celebrate),
        ]
        for (name, joints, word) in cases {
            XCTAssertEqual(gestureWord(TestFaces.neutral, joints), word, name)
            XCTAssertEqual(gestureWord(nil, joints), word, "\(name), no face")
            XCTAssertEqual(gestureWord(TestFaces.neutral, flipped(joints)), word, "\(name), mirrored image")
            XCTAssertEqual(MoodClassifier.mood(for: nil, pose: TestPoses.features(joints), baseline: RestingBaseline()), word, "\(name): the mood")
        }
        // The other arm doing it.
        XCTAssertEqual(gestureWord(TestFaces.neutral, TestPoses.body(left: TestPoses.rest, right: FullBodyPoses.straightUp.otherSide)), .pickMe)
        XCTAssertEqual(gestureWord(TestFaces.neutral, TestPoses.body(left: TestPoses.rest, right: FullBodyPoses.handOnHip.otherSide,
                                                                    hips: FullBodyPoses.hips)), .handsOnHips)
    }

    func testAPeaceSignIsPeace() {
        XCTAssertEqual(gestureWord(TestFaces.neutral, TestPoses.both(TestPoses.rest), hand: HandShape(peace: 1)), .peace)
        XCTAssertEqual(Mood.peace.searchQuery, "peace sign")
    }

    func testASmileDoesntTurnAPoseIntoExcitement() {
        XCTAssertEqual(gestureWord(makeFace(smile: 0.7), FullBodyPoses.tPose), .tPose)
    }

    func testAHandOverShutEyesIsStillAFacepalm() {
        let facepalm = TestPoses.body(left: TestPoses.onFace, right: TestPoses.rest.otherSide)
        XCTAssertEqual(gestureWord(makeFace(eye: 0.15), facepalm), .facepalm)
        XCTAssertEqual(gestureWord(nil, facepalm), .facepalm)
        // A slap on the forehead with the elbow out at shoulder height: raised, but not reaching across like a dab.
        let slap = TestPoses.body(left: TestArm(elbow: (x: 1.0, y: 0.1), wrist: (x: 0.25, y: 0.75)), right: TestPoses.rest.otherSide)
        XCTAssertEqual(gestureWord(makeFace(eye: 0.15), slap), .facepalm)
    }

    func testTwoFingersOnTheCheekAreNoPeaceSign() throws {
        var points = TestHands.pointing().points
        points[.middlePIP] = PosePoint(x: 1.35, y: 0.1)
        points[.middleDIP] = PosePoint(x: 1.6, y: 0.12)
        points[.middleTip] = PosePoint(x: 1.85, y: 0.12)
        let victory = HandJoints(points: points)
        XCTAssertGreaterThan(try XCTUnwrap(HandShape(victory)).peace, 0.9)
        let aroundTheFingertips = PoseBox(minX: 1.5, minY: 0, maxX: 2, maxY: 1)
        XCTAssertEqual(try XCTUnwrap(HandShape(victory, faceBox: aroundTheFingertips)).peace, 0)
    }

    func testAWeakArmShapeDoesntReplaceTheFacesMood() throws {
        // Forearms out on the chair's armrests have a shrug's shape, too weak to be a gesture: the face decides.
        let armrests = TestPoses.features(TestPoses.both(TestArm(elbow: (x: 0.7, y: -0.8), wrist: (x: 0.8, y: -0.75))))
        XCTAssertLessThan(armrests.gestureStrength, Ranker.gestureWithoutFace)
        XCTAssertEqual(MoodClassifier.mood(for: TestFaces.surprise, pose: armrests, baseline: RestingBaseline()), .shocked)
        XCTAssertNil(PoseBadge.of(ExpressionSample(face: TestFaces.surprise, pose: armrests, timestamp: 0), baseline: RestingBaseline()))
    }

    func testRestingPosturesHaveNoWord() {
        let cases: [(String, BodyJoints)] = [
            ("hands in pockets", TestPoses.both(TestArm(elbow: (x: 0.68, y: -0.75), wrist: (x: 0.4, y: -1.3)), hips: FullBodyPoses.hips)),
            ("hands clasped in front", TestPoses.both(TestArm(elbow: (x: 0.55, y: -0.85), wrist: (x: 0.08, y: -1.15)), hips: FullBodyPoses.hips)),
            ("arms hanging", TestPoses.both(TestPoses.rest, hips: FullBodyPoses.hips)),
            ("arms folded on a desk", TestPoses.body(left: TestArm(elbow: (x: 0.6, y: -0.75), wrist: (x: -0.35, y: -0.9)),
                                                     right: TestArm(elbow: (x: -0.6, y: -0.75), wrist: (x: 0.35, y: -0.95)))),
            ("elbows wide, hands together on a desk", TestPoses.both(TestArm(elbow: (x: 1.0, y: -0.7), wrist: (x: 0.3, y: -0.9)))),
            ("hands behind the head", TestPoses.both(TestArm(elbow: (x: 0.95, y: 0.75), wrist: nil))),
            ("a phone at the chest", TestPoses.both(TestArm(elbow: (x: 0.55, y: -0.9), wrist: (x: 0.15, y: -0.45)))),
            ("hands clasped behind the head, wrists seen", TestPoses.both(TestArm(elbow: (x: 0.95, y: 0.75), wrist: (x: 0.15, y: 0.9)))),
            ("leaning on forearms folded on a desk", TestPoses.body(left: TestArm(elbow: (x: 0.62, y: -0.5), wrist: (x: -0.35, y: -0.7)),
                                                                   right: TestArm(elbow: (x: -0.62, y: -0.5), wrist: (x: 0.35, y: -0.7)))),
        ]
        for (name, joints) in cases {
            XCTAssertNil(gestureWord(TestFaces.neutral, joints), name)
            // Eyes shut or the face hidden, no hand is on the face: not a facepalm.
            XCTAssertNil(gestureWord(makeFace(eye: 0.15), joints), name)
            XCTAssertNil(gestureWord(nil, joints), name)
            XCTAssertNil(PoseDescriptor(joints)?.bodyShape, name)
            XCTAssertEqual(MoodClassifier.mood(for: TestFaces.neutral, pose: TestPoses.features(joints), baseline: RestingBaseline()),
                           .unimpressed, name)
        }
    }

    func testTheNewWordsSearchAndRead() {
        let expected: [Mood: (label: String, query: String)] = [
            .tPose: ("t-pose", "t pose"), .flex: ("flex", "flex"), .dab: ("dab", "dab"),
            .handsOnHips: ("hands on hips", "hands on hips"), .armsCrossed: ("arms crossed", "arms crossed"),
            .pickMe: ("pick me", "pick me"), .hello: ("hello", "hello"), .ohNo: ("oh no", "oh no"),
            .peace: ("peace", "peace sign"), .bow: ("bow", "bowing"),
        ]
        for (mood, words) in expected {
            XCTAssertEqual(mood.label, words.label)
            XCTAssertEqual(mood.searchQuery, words.query)
        }
    }
}

final class PoseShapeTrackingTests: XCTestCase {
    private func frame(_ face: FaceFeatures?, _ step: Int, _ joints: BodyJoints) -> ExpressionSample {
        ExpressionSample(face: face, pose: TestPoses.features(joints), timestamp: Double(step) / 10)
    }

    private func word(_ tracker: PeakHoldTracker) -> Mood? {
        tracker.query.map { MoodClassifier.mood(for: $0.face, pose: $0.pose, baseline: tracker.baseline) }
    }

    private func makeTracker() -> PeakHoldTracker {
        PeakHoldTracker(baseline: RestingBaseline(sampleCount: 100))
    }

    func testHandsOnHipsAloneIsHeldForASecond() {
        let tracker = makeTracker()
        for step in 1...10 {
            XCTAssertFalse(tracker.ingest(frame(nil, step, FullBodyPoses.handsOnHips)), "step \(step)")
        }
        XCTAssertEqual(tracker.holdProgress, 0.9, accuracy: 1e-6)
        XCTAssertTrue(tracker.ingest(frame(nil, 11, FullBodyPoses.handsOnHips)))
        XCTAssertEqual(tracker.queryIntensity, 0.48, accuracy: 1e-9)
        XCTAssertEqual(word(tracker), .handsOnHips)
    }

    func testOneMissedFrameDoesntBreakAHold() {
        let tracker = makeTracker()
        let resting = TestPoses.both(TestPoses.rest, hips: FullBodyPoses.hips)
        XCTAssertFalse(tracker.ingest(frame(nil, 1, FullBodyPoses.tPose)))
        XCTAssertFalse(tracker.ingest(frame(nil, 2, FullBodyPoses.tPose)))
        XCTAssertFalse(tracker.ingest(frame(nil, 3, resting)))
        XCTAssertEqual(tracker.holdProgress, 1.0 / 3.0, accuracy: 1e-6)
        XCTAssertNotNil(tracker.candidate)
        XCTAssertTrue(tracker.ingest(frame(nil, 4, FullBodyPoses.tPose)))
        XCTAssertEqual(word(tracker), .tPose)
    }

    func testALongerGapEndsTheHold() {
        let tracker = makeTracker()
        let resting = TestPoses.both(TestPoses.rest, hips: FullBodyPoses.hips)
        XCTAssertFalse(tracker.ingest(frame(nil, 1, FullBodyPoses.tPose)))
        XCTAssertFalse(tracker.ingest(frame(nil, 2, FullBodyPoses.tPose)))
        for step in 3...6 {
            XCTAssertFalse(tracker.ingest(frame(nil, step, resting)), "step \(step)")
        }
        XCTAssertEqual(tracker.holdProgress, 0)
        XCTAssertNil(tracker.candidate)
        for step in 7...9 {
            XCTAssertFalse(tracker.ingest(frame(nil, step, FullBodyPoses.tPose)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(nil, 10, FullBodyPoses.tPose)))
    }

    func testAPoseWithANewWordAfterAHeldOneIsANewExpression() {
        let tracker = makeTracker()
        let armsUp = TestPoses.both(TestPoses.up)
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(nil, step, armsUp)))
        }
        XCTAssertTrue(tracker.ingest(frame(nil, 4, armsUp)))
        XCTAssertEqual(word(tracker), .celebrate)
        XCTAssertFalse(tracker.ingest(frame(nil, 5, FullBodyPoses.flex)))
        XCTAssertTrue(tracker.candidateIsNewExpression)
        for step in 6...14 {
            XCTAssertFalse(tracker.ingest(frame(nil, step, FullBodyPoses.flex)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(nil, 15, FullBodyPoses.flex)))
        XCTAssertEqual(word(tracker), .flex)
    }

    func testANewShapeWithTheSameWordIsANewExpression() {
        // A star jump and arms straight up are both "celebrate", and point the same way.
        let tracker = makeTracker()
        let armsUp = TestPoses.both(TestPoses.up)
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(nil, step, FullBodyPoses.starJump)))
        }
        XCTAssertTrue(tracker.ingest(frame(nil, 4, FullBodyPoses.starJump)))
        for step in 5...14 {
            XCTAssertFalse(tracker.ingest(frame(nil, step, armsUp)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(nil, 15, armsUp)))
        XCTAssertEqual(tracker.query?.pose, TestPoses.features(armsUp))
    }

    func testAFlickeringFaceDoesntBreakAShapesHold() {
        let tracker = makeTracker()
        let faces = Array(repeating: makeFace(brow: 0.55), count: 4) + Array(repeating: makeFace(eye: 0.35), count: 4)
            + Array(repeating: makeFace(brow: 0.55), count: 4)
        for step in 1...10 {
            XCTAssertFalse(tracker.ingest(frame(faces[step - 1], step, FullBodyPoses.handsOnHips)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(faces[10], 11, FullBodyPoses.handsOnHips)))
        XCTAssertEqual(word(tracker), .handsOnHips)
    }

    func testAFaceSeenAndLostDoesntBreakAShapesHold() {
        // A far face reads a little off rest: its frames point elsewhere than the face-less ones.
        let tracker = makeTracker()
        for step in 1...10 {
            let face: FaceFeatures? = (step - 1) % 6 < 3 ? makeFace(brow: 0.55, gaze: 0.2) : nil
            XCTAssertFalse(tracker.ingest(frame(face, step, FullBodyPoses.handsOnHips)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(nil, 11, FullBodyPoses.handsOnHips)))
        XCTAssertEqual(word(tracker), .handsOnHips)
    }

    func testMostFramesDecideTheWord() {
        // Three T-pose frames, then one strong frame in the same direction with no word: the query is a T-pose.
        let tracker = makeTracker()
        let drifting = TestPoses.both(TestArm(elbow: (x: 1.3, y: 0), wrist: (x: 2.0, y: 0.75)))
        XCTAssertNil(PoseDescriptor(drifting).flatMap { MoodClassifier.gestureMood($0, face: nil, baseline: RestingBaseline()) })
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(nil, step, FullBodyPoses.tPose)))
        }
        XCTAssertTrue(tracker.ingest(frame(nil, 4, drifting)))
        XCTAssertEqual(word(tracker), .tPose)
    }

    func testAShapeCloseToRestAfterAStrongPose() {
        let tracker = makeTracker()
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(nil, step, FullBodyPoses.tPose)))
        }
        XCTAssertTrue(tracker.ingest(frame(nil, 4, FullBodyPoses.tPose)))
        for step in 5...14 {
            XCTAssertFalse(tracker.ingest(frame(nil, step, FullBodyPoses.handsOnHips)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(nil, 15, FullBodyPoses.handsOnHips)))
        XCTAssertEqual(word(tracker), .handsOnHips)
        XCTAssertEqual(tracker.queryIntensity, 0.48, accuracy: 1e-9)
    }

    func testAFaceCanChangeWhileAShapeIsHeld() {
        // Arms crossed at the desk (no hips in view): a surprised face makes the search, then a smile replaces it.
        let tracker = makeTracker()
        let crossed = TestPoses.body(left: FullBodyPoses.crossedLeft, right: FullBodyPoses.crossedRight)
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, step, crossed)))
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.surprise, 4, crossed)))
        for step in 5...14 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.smile, step, crossed)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.smile, 15, crossed)))
        XCTAssertEqual(tracker.query?.face, TestFaces.smile)
    }

    func testAMildFaceCanReplaceAShapeHeldWithACalmFace() {
        // Arms crossed with a calm face became the search; a smile weaker than the shape's strength still replaces it.
        let tracker = makeTracker()
        let crossed = TestPoses.body(left: FullBodyPoses.crossedLeft, right: FullBodyPoses.crossedRight)
        for step in 1...10 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, step, crossed)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.neutral, 11, crossed)))
        for step in 12...21 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.smile, step, crossed)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.smile, 22, crossed)))
        XCTAssertEqual(tracker.query?.face, TestFaces.smile)
    }

    func testArmsCaughtRisingTakeTheWordTheyArriveAt() {
        // Straight arms rising in front (strong, no word yet) for three frames, then up: the hold ends on "celebrate".
        let tracker = makeTracker()
        let rising = TestPoses.both(TestArm(elbow: (x: 0.72, y: 0.2), wrist: (x: 0.9, y: 0.5)))
        XCTAssertNil(PoseDescriptor(rising).flatMap { MoodClassifier.gestureMood($0, face: nil, baseline: RestingBaseline()) })
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(nil, step, rising)))
        }
        XCTAssertTrue(tracker.ingest(frame(nil, 4, TestPoses.both(TestPoses.up))))
        XCTAssertEqual(word(tracker), .celebrate)
    }

    func testAFaceHasNoGrace() {
        // A face being held still starts over on a frame that misses it.
        let tracker = makeTracker()
        XCTAssertFalse(tracker.ingest(ExpressionSample(face: TestFaces.surprise, timestamp: 0.1)))
        XCTAssertFalse(tracker.ingest(ExpressionSample(face: TestFaces.surprise, timestamp: 0.2)))
        XCTAssertFalse(tracker.ingest(ExpressionSample(face: TestFaces.neutral, timestamp: 0.3)))
        XCTAssertEqual(tracker.holdProgress, 0)
        XCTAssertNil(tracker.candidate)
    }

    func testFramesSkippedInAGraceLeadOnlyIntoTheirOwnLook() {
        // A T-pose held 0.2 s, then a surprised face: the frames skipped in the pose's grace count toward its hold.
        let tracker = makeTracker()
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(nil, step, FullBodyPoses.tPose)))
        }
        for step in 4...6 {
            XCTAssertFalse(tracker.ingest(ExpressionSample(face: TestFaces.surprise, timestamp: Double(step) / 10)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(ExpressionSample(face: TestFaces.surprise, timestamp: 0.7)))
        XCTAssertEqual(tracker.query?.face, TestFaces.surprise)

        // A face flickering between two looks after it never becomes the search.
        let flicker = makeTracker()
        for step in 1...3 {
            XCTAssertFalse(flicker.ingest(frame(nil, step, FullBodyPoses.tPose)))
        }
        for step in 4...12 {
            let face = step % 2 == 0 ? TestFaces.surprise : TestFaces.smile
            XCTAssertFalse(flicker.ingest(ExpressionSample(face: face, timestamp: Double(step) / 10)), "step \(step)")
        }
        XCTAssertNil(flicker.query)
    }
}

final class PoseBadgeTests: XCTestCase {
    func testTheBadgeNamesThePose() {
        let baseline = RestingBaseline()
        let tPose = ExpressionSample(face: nil, pose: TestPoses.features(FullBodyPoses.tPose), timestamp: 0)
        XCTAssertEqual(PoseBadge.of(tPose, baseline: baseline), .word(.tPose))
        XCTAssertEqual(PoseBadge.of(tPose, baseline: baseline)?.label, "t-pose")

        let zombie = TestPoses.features(FullBodyPoses.zombie)
        XCTAssertGreaterThan(zombie.gestureStrength, 0.4)
        let wordless = ExpressionSample(face: TestFaces.neutral, pose: zombie, timestamp: 0)
        XCTAssertEqual(PoseBadge.of(wordless, baseline: baseline), .pose)
        XCTAssertEqual(PoseBadge.of(wordless, baseline: baseline)?.label, "your pose")

        let resting = ExpressionSample(face: TestFaces.neutral, pose: TestPoses.features(TestPoses.both(TestPoses.rest)), timestamp: 0)
        XCTAssertNil(PoseBadge.of(resting, baseline: baseline))
        XCTAssertNil(PoseBadge.of(ExpressionSample(face: TestFaces.surprise, timestamp: 0), baseline: baseline))
    }
}

final class StandingBackDetectorTests: XCTestCase {
    func testStandingBackTurnsOnAfterASecondAndAHalf() {
        var detector = StandingBackDetector()
        for step in 0...14 {
            XCTAssertFalse(detector.observe(bodyWidth: 0.12, at: Double(step) / 10), "t \(Double(step) / 10)")
        }
        XCTAssertTrue(detector.observe(bodyWidth: 0.12, at: 1.5))
        // In between changes nothing.
        for step in 16...40 {
            XCTAssertTrue(detector.observe(bodyWidth: 0.22, at: Double(step) / 10))
        }
    }

    func testComingCloseOrLeavingTurnsItOff() {
        var detector = StandingBackDetector()
        for step in 0...15 {
            detector.observe(bodyWidth: 0.12, at: Double(step) / 10)
        }
        XCTAssertTrue(detector.isStandingBack)
        for step in 16...25 {
            XCTAssertTrue(detector.observe(bodyWidth: 0.3, at: Double(step) / 10), "t \(Double(step) / 10)")
        }
        XCTAssertFalse(detector.observe(bodyWidth: 0.3, at: 2.6))

        for step in 30...45 {
            detector.observe(bodyWidth: 0.12, at: Double(step) / 10)
        }
        XCTAssertTrue(detector.isStandingBack)
        for step in 46...60 {
            XCTAssertTrue(detector.observe(bodyWidth: nil, at: Double(step) / 10), "t \(Double(step) / 10)")
        }
        XCTAssertFalse(detector.observe(bodyWidth: nil, at: 6.1))
    }

    func testTheBodysWidthInTheImage() throws {
        // Shoulders 0.2 apart in a 4:3 image's corrected units (x up to 4/3): 0.15 of its width.
        let width = try XCTUnwrap(FullBodyPoses.tPose.widthInImage(aspect: 4.0 / 3.0))
        XCTAssertEqual(width, 0.2 / (4.0 / 3.0), accuracy: 1e-9)
        XCTAssertNil(BodyJoints(points: [:]).widthInImage(aspect: 4.0 / 3.0))
    }
}
