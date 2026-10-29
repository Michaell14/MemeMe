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
        XCTAssertNil(straight[.torsoLength], "no hips")
        for dimension in PoseDescriptor.Dimension.allCases where dimension != .shoulderTilt && dimension != .torsoLength {
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
        // Left arm 7 + tilt 0.5 + head rise 0.5 + left cross 1, elbow out 0.5 and forearm 0.5, of 16.5 + both arms' 4.
        XCTAssertEqual(match.coverage, 10 / 20.5, accuracy: 1e-9)
    }

    func testATinyBodyOrNoShouldersHasNoDescriptor() {
        XCTAssertNil(PoseDescriptor(TestPoses.both(TestPoses.rest, scale: 0.01)))
        XCTAssertNil(PoseDescriptor(TestPoses.body(left: TestPoses.up, right: TestPoses.up.otherSide, shoulders: false)))
    }

    func testASideOnBodyAtRestIsNoGesture() throws {
        // Turned to the side: the shoulders almost overlap, one eye and one ear show, the arms hang down.
        let points: [BodyJoint: PosePoint] = [
            .leftShoulder: PosePoint(x: 0.50, y: 0.50), .rightShoulder: PosePoint(x: 0.49, y: 0.48),
            .nose: PosePoint(x: 0.56, y: 0.66), .leftEye: PosePoint(x: 0.53, y: 0.68), .leftEar: PosePoint(x: 0.47, y: 0.67),
            .leftElbow: PosePoint(x: 0.50, y: 0.34), .rightElbow: PosePoint(x: 0.49, y: 0.33),
            .leftWrist: PosePoint(x: 0.51, y: 0.20), .rightWrist: PosePoint(x: 0.50, y: 0.19),
        ]
        let side = try descriptor(BodyJoints(points: points))
        XCTAssertNil(side[.shoulderTilt])          // a foreshortened shoulder line says nothing about tilt
        XCTAssertLessThan(side.gestureStrength, 0.2)
        XCTAssertLessThan(try XCTUnwrap(side[.leftLift]), 0.1)
    }

    func testForearmsOnADeskAndHandsBehindTheHeadAreRest() throws {
        let onDesk = try descriptor(TestPoses.both(TestArm(elbow: (x: 0.6, y: -0.8), wrist: (x: 0.3, y: -0.85))))
        XCTAssertEqual(onDesk.gestureStrength, 0)
        // Wrists hidden behind the head, elbows up and out: not arms raised out of frame.
        let behindHead = try descriptor(TestPoses.both(TestArm(elbow: (x: 0.95, y: 0.75), wrist: nil)))
        XCTAssertLessThan(try XCTUnwrap(behindHead[.leftElbowLift]), PoseDescriptor.elbowOnlyUp)
        XCTAssertEqual(behindHead.gestureStrength, 0)
        // Upper arms near vertical with the hands out of the top of the frame still count.
        XCTAssertEqual(try descriptor(TestPoses.both(TestPoses.elbowUp)).gestureStrength, 1, accuracy: 1e-9)
        // Two resting poses match whatever their shape.
        let desk = TestPoses.features(TestPoses.both(TestArm(elbow: (x: 0.6, y: -0.8), wrist: (x: 0.3, y: -0.85))))
        let hanging = TestPoses.features(TestPoses.both(TestPoses.rest))
        XCTAssertEqual(PoseFeatures.similarity(query: desk, item: hanging), 1, accuracy: 1e-9)
    }

    func testAPhoneOrMugAtTheChestIsRestAndTheStrengthNeverJumps() throws {
        let phone = TestArm(elbow: (x: 0.55, y: -0.9), wrist: (x: 0.15, y: -0.45))
        XCTAssertEqual(try descriptor(TestPoses.body(left: phone, right: nil)).gestureStrength, 0)
        XCTAssertEqual(try descriptor(TestPoses.both(phone)).gestureStrength, 0)
        // Raised a little more, it eases in rather than jumping to a full gesture.
        let higher = try descriptor(TestPoses.both(TestArm(elbow: (x: 0.55, y: -0.9), wrist: (x: 0.15, y: -0.3))))
        XCTAssertGreaterThan(higher.gestureStrength, 0.2)
        XCTAssertLessThan(higher.gestureStrength, 0.8)
        // The other arm hanging or on the mouse doesn't undo the rest of the hand holding the phone.
        XCTAssertLessThan(try descriptor(TestPoses.body(left: phone, right: TestPoses.rest.otherSide)).gestureStrength, 0.05)
        let mouse = TestArm(elbow: (x: 0.6, y: -0.8), wrist: (x: 0.7, y: -0.9))
        XCTAssertLessThan(try descriptor(TestPoses.body(left: phone, right: mouse.otherSide)).gestureStrength, 0.05)
        // An arm raised out of the top of the frame still counts with the other forearm on the desk.
        let desk = TestArm(elbow: (x: 0.6, y: -0.8), wrist: (x: 0.3, y: -0.85))
        XCTAssertGreaterThan(try descriptor(TestPoses.body(left: TestPoses.elbowUp, right: desk.otherSide)).gestureStrength, 0.5)
        // The hand holding the phone is no sign when it reads as a finger pattern (three fingers along its back, the
        // little finger under it), nor are fingers on a mouse: which hand made the pattern isn't known, so a wrist
        // resting is enough.
        let grip = HandShape(fingers: [0.79, 1, 1, 1, 0])
        XCTAssertGreaterThanOrEqual(grip.patternStrength, 0.7)
        XCTAssertEqual(try descriptor(TestPoses.body(left: phone, right: nil), hand: grip).gestureStrength, 0)
        XCTAssertEqual(try descriptor(TestPoses.both(phone), hand: grip).gestureStrength, 0)
        XCTAssertLessThan(try descriptor(TestPoses.body(left: phone, right: TestPoses.rest.otherSide), hand: grip).gestureStrength, 0.05)
        XCTAssertLessThan(try descriptor(TestPoses.body(left: phone, right: mouse.otherSide), hand: grip).gestureStrength, 0.05)
        XCTAssertEqual(try descriptor(TestPoses.both(phone), hand: grip).gestureDirection.last ?? 1, 0, accuracy: 1e-9)
        // Named signs still count there, and the same fingers with the arms hanging are a sign.
        XCTAssertEqual(try descriptor(TestPoses.both(phone), hand: HandShape(thumbsUp: 0.9)).gestureStrength, 0.9, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(try descriptor(TestPoses.both(TestPoses.rest), hand: grip).gestureStrength, 0.7)
        // An arm hanging straight with its wrist under the shoulder rests as much as the phone's (lift 0, out 0.2), but
        // holds nothing: the fingers are a sign there too, with both arms or one.
        let hanging = TestArm(elbow: (x: 0.5, y: -0.8), wrist: (x: 0.5, y: -1.5))
        XCTAssertGreaterThanOrEqual(try descriptor(TestPoses.both(hanging), hand: grip).gestureStrength, 0.7)
        XCTAssertGreaterThanOrEqual(try descriptor(TestPoses.both(hanging), hand: try XCTUnwrap(HandShape(TestHands.rockOn())))
            .gestureStrength, 0.7)
        XCTAssertEqual(try descriptor(TestPoses.both(hanging), hand: grip).gestureDirection.last ?? 0, 1, accuracy: 1e-9)
        // A phone held low toward the camera (the forearm foreshortened, so the elbow reads nearly straight) still
        // holds: its wrist is above the waist.
        let lowPhone = TestArm(elbow: (x: 0.55, y: -0.9), wrist: (x: 0.5, y: -1.0))
        XCTAssertLessThan(try descriptor(TestPoses.body(left: lowPhone, right: hanging.otherSide), hand: grip).gestureStrength, 0.05)
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

    func testTheGestureDirectionTellsOtherFingerPatternsLast() throws {
        let rest = TestPoses.both(TestPoses.rest)
        let pointing = try descriptor(rest, hand: try XCTUnwrap(HandShape(TestHands.pointing())))
        let rockOn = try descriptor(rest, hand: try XCTUnwrap(HandShape(TestHands.rockOn())))
        XCTAssertEqual(try descriptor(rest).gestureDirection.count, 10)
        XCTAssertEqual(pointing.gestureDirection.count, 10)
        XCTAssertEqual(pointing.gestureDirection[7], 1, accuracy: 1e-9, "pointing has a number of its own")
        XCTAssertEqual(pointing.gestureDirection[9], 0, accuracy: 1e-9, "…and isn't told again as a pattern")
        XCTAssertEqual(rockOn.gestureDirection[9], 1, accuracy: 1e-9, "horns are the pattern no named sign tells")
        XCTAssertEqual(try descriptor(rest, hand: HandShape(thumbsUp: 1)).gestureDirection[9], 0, accuracy: 1e-9,
                       "a hand without its fingers kept")
        // Horns with the arms down point their own way, not just away from rest.
        XCTAssertGreaterThan(VectorMath.cosine(rockOn.gestureDirection, [0, 0, 0, 0, 0, 0, 0, 0, 0, 1]), 0.99)
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

    func testAFingerOrThumbOnTheFaceIsNoSign() throws {
        // The index finger up the cheek (thinking, "shh") isn't pointing; a thumb along the jaw isn't a thumbs up.
        let pointing = TestHands.pointing()
        let aroundIndexTip = PoseBox(minX: 1.5, minY: 0, maxX: 2, maxY: 1)
        XCTAssertGreaterThan(try XCTUnwrap(HandShape(pointing)).point, 0.9)
        XCTAssertEqual(try XCTUnwrap(HandShape(pointing, faceBox: aroundIndexTip)).point, 0)
        let thumbs = TestHands.thumbsUp()
        let aroundThumbTip = PoseBox(minX: 0.3, minY: 1, maxX: 0.8, maxY: 1.5)
        XCTAssertEqual(try XCTUnwrap(HandShape(thumbs, faceBox: aroundThumbTip)).thumbsUp, 0)
        // A face elsewhere changes nothing.
        let elsewhere = PoseBox(minX: 5, minY: 5, maxX: 6, maxY: 6)
        XCTAssertGreaterThan(try XCTUnwrap(HandShape(thumbs, faceBox: elsewhere)).thumbsUp, 0.9)
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

    // MARK: Fingers

    func testHowStraightEachFingerIs() throws {
        let pointing = try XCTUnwrap(HandShape(TestHands.pointing()))
        XCTAssertEqual(pointing.fingers?.count, 5, "thumb first, then index, middle, ring and little")
        XCTAssertGreaterThan(try XCTUnwrap(pointing[.index]), 0.9, "the pointing finger is straight")
        for finger in [HandShape.Finger.thumb, .middle, .ring, .little] {
            XCTAssertLessThan(try XCTUnwrap(pointing[finger]), 0.1, "pointing: \(finger) is curled (the thumb tucked along them)")
        }
        let open = try XCTUnwrap(HandShape(TestHands.openPalm()))
        for finger in HandShape.Finger.allCases {
            XCTAssertGreaterThan(try XCTUnwrap(open[finger]), 0.7, "open palm: \(finger) is straight")
        }
        let fist = try XCTUnwrap(HandShape(TestHands.fist()))
        XCTAssertGreaterThan(fist.fist, 0.9)
        for finger in HandShape.Finger.allCases {
            XCTAssertLessThan(try XCTUnwrap(fist[finger]), 0.1, "fist: \(finger) is curled")
        }
        XCTAssertNil(HandShape(point: 1)[.index], "a hand read before fingers were kept knows none")
        XCTAssertNil(HandShape(fingers: [1, 0])[.ring], "nor a finger past those kept")
    }

    func testARockOnHandIsAFingerPattern() throws {
        let rockOn = try XCTUnwrap(HandShape(TestHands.rockOn()))
        XCTAssertGreaterThan(try XCTUnwrap(rockOn[.index]), 0.9)
        XCTAssertGreaterThan(try XCTUnwrap(rockOn[.little]), 0.9)
        XCTAssertLessThan(try XCTUnwrap(rockOn[.middle]), 0.1)
        XCTAssertLessThan(try XCTUnwrap(rockOn[.ring]), 0.1)
        // None of the named signs (pointing needs the little finger curled)…
        XCTAssertLessThan(max(rockOn.thumbsUp, rockOn.point, rockOn.peace), 0.1)
        // …but a deliberate pattern all the same, which is a sign: it starts a search with the arms down.
        XCTAssertGreaterThanOrEqual(rockOn.patternStrength, 0.7)
        XCTAssertGreaterThanOrEqual(rockOn.signStrength, 0.7)
        let pose = try XCTUnwrap(PoseDescriptor(TestPoses.both(TestPoses.rest), hand: rockOn))
        XCTAssertGreaterThanOrEqual(pose.gestureStrength, 0.7)
        // Pointing is a pattern too; a thumb alone out of a fist isn't (a thumb round a mug stands out as far), and a
        // thumbs up is told by its own score.
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(HandShape(TestHands.pointing())).patternStrength, 0.7)
        let thumbs = try XCTUnwrap(HandShape(TestHands.thumbsUp()))
        XCTAssertGreaterThan(try XCTUnwrap(thumbs[.thumb]), 0.9, "the thumb reads straight")
        XCTAssertEqual(thumbs.patternStrength, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(thumbs.signStrength, 0.9)
    }

    func testAFistAnOpenPalmOrALooseHandIsNoPattern() throws {
        XCTAssertEqual(try XCTUnwrap(HandShape(TestHands.fist())).patternStrength, 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(HandShape(TestHands.openPalm())).patternStrength, 0, accuracy: 1e-9)
        // An open palm with the thumb tucked against it: only the four fingers' curl counts.
        var points = TestHands.openPalm().points
        points[.thumbTip] = PosePoint(x: -0.2, y: 0.5)
        points[.thumbIP] = PosePoint(x: -0.15, y: 0.3)
        let tucked = try XCTUnwrap(HandShape(HandJoints(points: points)))
        XCTAssertLessThan(try XCTUnwrap(tucked[.thumb]), 0.3, "the thumb reads curled")
        XCTAssertGreaterThan(tucked.openPalm, 0.9)
        XCTAssertEqual(tucked.patternStrength, 0, accuracy: 1e-9)
        XCTAssertLessThan(tucked.signStrength, 0.1)
        // A thumb opposed round a mug, the fingers curled round it, is no pattern either.
        XCTAssertEqual(HandShape(fingers: [0.83, 0, 0, 0, 0]).patternStrength, 0, accuracy: 1e-9)
        // Every finger half bent is no clear pattern; too few fingers seen, or none kept, is none at all.
        XCTAssertLessThan(HandShape(fingers: [0.5, 0.55, 0.5, 0.45, 0.5]).patternStrength, 0.7)
        XCTAssertEqual(HandShape(fingers: [nil, 1, 0, nil, nil]).patternStrength, 0)
        XCTAssertEqual(HandShape(point: 1).patternStrength, 0)
    }

    func testAFingerPatternOnTheFaceIsNoSignButKeepsItsFingers() throws {
        // A finger up the cheek while thinking: the fingertip lies in the face's box.
        let aroundIndexTip = PoseBox(minX: 1.5, minY: 0, maxX: 2, maxY: 1)
        let onFace = try XCTUnwrap(HandShape(TestHands.rockOn(), faceBox: aroundIndexTip))
        XCTAssertEqual(onFace.patternStrength, 0)
        XCTAssertEqual(onFace.signStrength, 0)
        XCTAssertGreaterThan(try XCTUnwrap(onFace[.index]), 0.9, "the fingers are still told")
        XCTAssertGreaterThan(try XCTUnwrap(onFace[.little]), 0.9)
        // Stored in a pose (rounded), still no sign.
        let pose = try XCTUnwrap(PoseDescriptor(TestPoses.both(TestPoses.rest), hand: onFace))
        XCTAssertEqual(try XCTUnwrap(pose.hand).patternStrength, 0)
        XCTAssertLessThan(pose.gestureStrength, 0.05)
        // A face elsewhere changes nothing.
        let elsewhere = PoseBox(minX: 5, minY: 5, maxX: 6, maxY: 6)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(HandShape(TestHands.rockOn(), faceBox: elsewhere)).patternStrength, 0.7)
    }

    func testHandsStoredBeforeFingersStillLoadAndFingersRoundTrip() throws {
        let stored = #"{"thumbsUp":0.9,"point":0,"openPalm":0,"fist":0.8,"peace":0}"#
        let decoded = try JSONDecoder().decode(HandShape.self, from: Data(stored.utf8))
        XCTAssertEqual(decoded, HandShape(thumbsUp: 0.9, fist: 0.8))
        XCTAssertNil(decoded.fingers)
        XCTAssertEqual(decoded.patternStrength, 0)

        let rockOn = try XCTUnwrap(HandShape(TestHands.rockOn()))
        XCTAssertEqual(try JSONDecoder().decode(HandShape.self, from: JSONEncoder().encode(rockOn)), rockOn)
        let partly = HandShape(point: 0.8, fingers: [nil, 1, 0.25, 0, 0])
        let partlyDecoded = try JSONDecoder().decode(HandShape.self, from: JSONEncoder().encode(partly))
        XCTAssertEqual(partlyDecoded, partly)
        XCTAssertNil(partlyDecoded[.thumb], "a finger not seen stays unseen")
        // In a stored pose too.
        let pose = TestPoses.features(TestPoses.both(TestPoses.rest), hand: rockOn)
        XCTAssertEqual(try JSONDecoder().decode(PoseFeatures.self, from: JSONEncoder().encode(pose)), pose)
        XCTAssertEqual(pose.descriptor?.hand?.fingers, rockOn.fingers)
    }

    func testRoundingKeepsTheFingers() {
        let shape = HandShape(point: 0.12345, fingers: [0.12345, nil, 1, 0, 0.98765])
        XCTAssertEqual(shape.rounded(), HandShape(point: 0.123, fingers: [0.123, nil, 1, 0, 0.988]))
    }

    func testStrongestKeepsTheFingersOfTheHandMakingTheSign() throws {
        let open = try XCTUnwrap(HandShape(TestHands.openPalm()))
        let rockOn = try XCTUnwrap(HandShape(TestHands.rockOn()))
        for hands in [[open, rockOn], [rockOn, open]] {
            let combined = try XCTUnwrap(HandShape.strongest(hands))
            XCTAssertEqual(combined.fingers, rockOn.fingers, "the horns' fingers, whichever hand came first")
            XCTAssertGreaterThanOrEqual(combined.signStrength, 0.7, "so the horns stay a sign beside an open hand")
            XCTAssertGreaterThan(combined.openPalm, 0.9, "the scores are still the most of each")
        }
        // Without a sign: the clearer fist or open palm, the first on a tie; a hand without fingers lends none.
        let fist = try XCTUnwrap(HandShape(TestHands.fist()))
        XCTAssertEqual(HandShape.strongest([fist, open])?.fingers, fist.fingers)
        XCTAssertEqual(HandShape.strongest([open, fist])?.fingers, open.fingers)
        XCTAssertEqual(HandShape.strongest([HandShape(fist: 1), open])?.fingers, open.fingers)
        // A pattern on the face stays no sign once combined.
        let onFace = try XCTUnwrap(HandShape(TestHands.rockOn(), faceBox: PoseBox(minX: 1.5, minY: 0, maxX: 2, maxY: 1)))
        XCTAssertEqual(try XCTUnwrap(HandShape.strongest([onFace])).patternStrength, 0)
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
        XCTAssertEqual(classify(makeFace(eye: 0.15), facepalm), .facepalm)
        // Heavy lids on a propped head aren't shut eyes.
        XCTAssertEqual(classify(makeFace(eye: 0.33), facepalm), .unimpressed)
        XCTAssertEqual(classify(nil, facepalm), .facepalm)
        // Eyes open: a hand near the face alone isn't a facepalm.
        XCTAssertEqual(classify(TestFaces.neutral, facepalm), .unimpressed)
        // A smile narrows the eyes too: smug or laughing with the head propped on a hand stays smug or laughing.
        XCTAssertEqual(classify(makeFace(eye: 0.3, smile: 0.7), facepalm), .smug)
        XCTAssertEqual(classify(makeFace(eye: 0.3, mouth: 0.3, smile: 0.65), facepalm), .laughing)
    }

    func testHandsTogetherIsClapping() {
        XCTAssertEqual(classify(TestFaces.neutral, TestPoses.both(TestPoses.clap)), .clapping)
    }

    func testRestingYourChinOrFaceOnYourHandsIsNotClappingOrMindBlown() {
        let chinRest = TestArm(elbow: (x: 0.45, y: -0.55), wrist: (x: 0.08, y: 0.2))
        XCTAssertEqual(classify(TestFaces.neutral, TestPoses.both(chinRest)), .unimpressed)
        let underChin = TestArm(elbow: (x: 0.45, y: -0.5), wrist: (x: 0.1, y: 0.3))
        XCTAssertEqual(classify(TestFaces.neutral, TestPoses.both(underChin)), .unimpressed)
        // Face buried in both hands, face hidden: a facepalm, not mind blown.
        let faceInHands = TestArm(elbow: (x: 0.45, y: -0.5), wrist: (x: 0.15, y: 0.45))
        XCTAssertEqual(classify(nil, TestPoses.both(faceInHands)), .facepalm)
    }

    func testHandsTogetherAreAClapOnlyWithOpenHands() {
        XCTAssertEqual(classify(TestFaces.neutral, TestPoses.both(TestPoses.clap), hand: HandShape(fist: 1)), .unimpressed)
        XCTAssertEqual(classify(TestFaces.neutral, TestPoses.both(TestPoses.clap), hand: HandShape(openPalm: 1)), .clapping)
    }

    func testHandsClaspedBehindTheHeadAreNotACelebration() {
        let behindHead = TestArm(elbow: (x: 0.95, y: 0.75), wrist: nil)
        XCTAssertEqual(classify(TestFaces.neutral, TestPoses.both(behindHead)), .unimpressed)
        XCTAssertEqual(classify(makeFace(smile: 0.7), TestPoses.both(behindHead)), .happy)
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

    func testMemesMeasuredTheOldWayAreUnknownToADetailedPose() {
        let celebrating = TestPoses.features(TestPoses.both(TestPoses.up))
        let legacy = PoseFeatures(handsRaised: 1, armsSpread: 0, bodyVisible: 0.9)
        XCTAssertEqual(PoseFeatures.similarity(query: celebrating, item: legacy), 0.3, accuracy: 1e-9)   // 1 − 0.7 × 1
        // Two old-style poses still compare by activity.
        XCTAssertEqual(PoseFeatures.similarity(query: legacy, item: legacy), 1, accuracy: 1e-9)
        // A faceless old-style meme doesn't take the hidden-face branch.
        let query = ExpressionSample(face: nil, pose: celebrating, timestamp: 0)
        let weights = FeatureWeights.automatic(deviation: [:], poseStrength: 1)
        let faceless = makeItem(name: "old", kind: .pack, pose: legacy, intensity: 0.3)
        XCTAssertEqual(ranker.expressionScore(item: faceless, sample: query, weights: weights), 0.55, accuracy: 1e-9)
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

    func testArmsOnTheDeskComingAndGoingDontChangeTheExpression() {
        let tracker = PeakHoldTracker(baseline: RestingBaseline(sampleCount: 100))
        let smile = makeFace(width: 0.6, smile: 0.65)   // a mild smile, intensity ≈ 0.16
        let onDesk = TestPoses.features(TestPoses.both(TestArm(elbow: (x: 0.6, y: -0.8), wrist: (x: 0.3, y: -0.85))))
        let outOfFrame = TestPoses.features(TestPoses.both(TestArm(elbow: (x: 0.6, y: -0.8), wrist: nil)))
        XCTAssertLessThan(onDesk.gestureStrength, 0.4)
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(smile, step, pose: onDesk)))
        }
        XCTAssertTrue(tracker.ingest(frame(smile, 4, pose: onDesk)))
        // The wrists leave the frame; the face doesn't change: no new expression, no new query.
        for step in 5...20 {
            XCTAssertFalse(tracker.ingest(frame(smile, step, pose: outOfFrame)), "step \(step)")
            XCTAssertFalse(tracker.candidateIsNewExpression, "step \(step)")
        }
    }

    func testANeutralFaceWithRestingArmsIsNeverHeld() {
        let tracker = PeakHoldTracker(baseline: RestingBaseline(sampleCount: 100))
        let onDesk = TestPoses.features(TestPoses.both(TestArm(elbow: (x: 0.6, y: -0.8), wrist: (x: 0.3, y: -0.85))))
        // Arms a little out from the sides: a weak gesture (about 0.22), not a held expression.
        let halfRaised = TestPoses.features(TestPoses.both(TestArm(elbow: (x: 0.75, y: -0.65), wrist: (x: 0.9, y: -0.7))))
        XCTAssertGreaterThan(halfRaised.gestureStrength, 0.1)
        XCTAssertLessThan(halfRaised.gestureStrength, Ranker.gestureWithoutFace)
        for step in 1...20 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, step, pose: step % 2 == 0 ? onDesk : halfRaised)), "step \(step)")
            XCTAssertNil(tracker.candidate, "step \(step)")
        }
        XCTAssertNil(tracker.query)
    }

    func testRelaxingWithArmsOnTheDeskKeepsTheHeldFace() {
        let tracker = PeakHoldTracker(baseline: RestingBaseline(sampleCount: 100))
        let onDesk = TestPoses.features(TestPoses.both(TestArm(elbow: (x: 0.6, y: -0.8), wrist: (x: 0.3, y: -0.85))))
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, step, pose: onDesk)))
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.surprise, 4, pose: onDesk)))
        for step in 5...25 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, step, pose: onDesk)), "step \(step)")
        }
        XCTAssertEqual(tracker.query?.face, TestFaces.surprise)
    }

    func testRaisingTheOtherArmTooIsANewExpression() {
        let tracker = PeakHoldTracker(baseline: RestingBaseline(sampleCount: 100))
        let oneUp = TestPoses.features(TestPoses.body(left: TestPoses.up, right: nil))   // the other hand below the frame
        let bothUp = TestPoses.features(TestPoses.both(TestPoses.up))
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, step, pose: oneUp)))
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.neutral, 4, pose: oneUp)))
        XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, 5, pose: bothUp)))
        XCTAssertTrue(tracker.candidateIsNewExpression)
        for step in 6...14 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, step, pose: bothUp)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.neutral, 15, pose: bothUp)))
        XCTAssertEqual(MoodClassifier.mood(for: TestFaces.neutral, pose: tracker.query?.pose, baseline: tracker.baseline), .celebrate)
    }

    func testAFlickeringRestingWristDoesntRestartTheHold() {
        let tracker = PeakHoldTracker(baseline: RestingBaseline(sampleCount: 100))
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, step, pose: nil)))
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.surprise, 4, pose: nil)))
        // A facepalm while the resting hand at the frame's edge is seen on some frames and not on others.
        let otherSeen = TestPoses.features(TestPoses.body(left: TestPoses.onFace, right: TestPoses.rest.otherSide))
        let otherUnseen = TestPoses.features(TestPoses.body(left: TestPoses.onFace, right: nil))
        for step in 5...14 {
            let pose = (step / 2) % 2 == 0 ? otherSeen : otherUnseen
            XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, step, pose: pose)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.neutral, 15, pose: otherSeen)))
    }

    /// Hands rising from the desk to the face over a second (the face hidden for the last fifth), then held there
    /// for two seconds: one hand (the other below the frame) or both.
    private func raiseHandsToTheFace(_ tracker: PeakHoldTracker, both: Bool, to end: TestArm) {
        func between(_ from: (x: Double, y: Double), _ to: (x: Double, y: Double)?, _ u: Double) -> (x: Double, y: Double) {
            guard let to else { return from }
            return (x: from.x + (to.x - from.x) * u, y: from.y + (to.y - from.y) * u)
        }
        func pose(_ arm: TestArm) -> PoseFeatures {
            TestPoses.features(both ? TestPoses.both(arm) : TestPoses.body(left: arm, right: nil))
        }
        var step = 0
        for tenth in 0...10 {
            let u = Double(tenth) / 10
            let arm = TestArm(elbow: between((x: 0.6, y: -0.8), end.elbow, u), wrist: between((x: 0.3, y: -0.85), end.wrist, u))
            step += 1
            tracker.ingest(frame(u >= 0.8 ? nil : TestFaces.neutral, step, pose: pose(arm)))
        }
        for _ in 0..<20 {
            step += 1
            tracker.ingest(frame(nil, step, pose: pose(end)))
        }
    }

    func testFinishingAGestureReplacesTheFrameCaughtOnTheWay() throws {
        // The hold catches the arm on its way up, already at full strength but with no word for it yet; the facepalm
        // it ends in is no stronger, and still replaces it once held for a second.
        let tracker = PeakHoldTracker(baseline: RestingBaseline(sampleCount: 100))
        raiseHandsToTheFace(tracker, both: false, to: TestPoses.onFace)
        let query = try XCTUnwrap(tracker.query)
        XCTAssertNil(query.face)
        XCTAssertEqual(MoodClassifier.mood(for: nil, pose: query.pose, baseline: tracker.baseline), .facepalm)
    }

    func testFaceInHandsReplacesTheClapCaughtOnTheWay() throws {
        // Both hands on the way up pass through clapping (wrists together in front of the chest), and the hold can
        // catch them there; the face in hands that follows has its own word.
        let tracker = PeakHoldTracker(baseline: RestingBaseline(sampleCount: 100))
        raiseHandsToTheFace(tracker, both: true, to: TestArm(elbow: (x: 0.4, y: -0.6), wrist: (x: 0.12, y: 0.45)))
        let query = try XCTUnwrap(tracker.query)
        XCTAssertNil(query.face)
        XCTAssertEqual(MoodClassifier.mood(for: nil, pose: query.pose, baseline: tracker.baseline), .facepalm)
    }

    func testOneGestureWordAfterAnotherIsANewExpression() {
        // A clap, then hands at the head: both at full strength and pointing much the same way, told apart by their word.
        let tracker = PeakHoldTracker(baseline: RestingBaseline(sampleCount: 100))
        let clapping = TestPoses.features(TestPoses.both(TestPoses.clap))
        let atHead = TestPoses.features(TestPoses.both(TestPoses.atHead))
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, step, pose: clapping)))
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.neutral, 4, pose: clapping)))
        XCTAssertEqual(MoodClassifier.mood(for: TestFaces.neutral, pose: tracker.query?.pose, baseline: tracker.baseline), .clapping)
        XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, 5, pose: atHead)))
        XCTAssertTrue(tracker.candidateIsNewExpression)
        for step in 6...14 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, step, pose: atHead)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.neutral, 15, pose: atHead)))
        XCTAssertEqual(MoodClassifier.mood(for: TestFaces.neutral, pose: tracker.query?.pose, baseline: tracker.baseline), .mindBlown)
    }

    func testAWeakGestureWithAWordDoesntTakeOverAHeldFace() throws {
        let tracker = PeakHoldTracker(baseline: RestingBaseline(sampleCount: 100))
        let onDesk = TestPoses.features(TestPoses.both(TestArm(elbow: (x: 0.6, y: -0.8), wrist: (x: 0.3, y: -0.85))))
        // Forearms out on the chair's armrests: a shrug's shape, but too weak to be a gesture.
        let armrests = TestPoses.features(TestPoses.both(TestArm(elbow: (x: 0.7, y: -0.8), wrist: (x: 0.8, y: -0.75))))
        XCTAssertLessThan(armrests.gestureStrength, Ranker.gestureWithoutFace)
        XCTAssertEqual(MoodClassifier.gestureMood(try XCTUnwrap(armrests.descriptor), face: TestFaces.surprise, baseline: tracker.baseline), .shrug)
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, step, pose: onDesk)))
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.surprise, 4, pose: onDesk)))
        for step in 5...15 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, step, pose: armrests)), "step \(step)")
        }
        XCTAssertEqual(tracker.query?.timestamp, 0.4)
        XCTAssertEqual(tracker.query?.pose, onDesk)
    }

    func testAShrugAfterAHeldSmileBecomesTheQuery() throws {
        // The face is quicker than the arms: the smile is held first, then the shoulders shrug while the smile eases a
        // little. The shrug is weaker than the smile on its own, and still replaces the resting arms.
        let tracker = PeakHoldTracker(baseline: RestingBaseline(sampleCount: 100))
        let resting = TestPoses.features(TestPoses.both(TestPoses.rest))
        let shrugging = TestPoses.features(TestPoses.both(TestPoses.shrug))
        let easedSmile = makeFace(width: 0.73, smile: 0.88)
        XCTAssertGreaterThanOrEqual(shrugging.gestureStrength, Ranker.gestureWithoutFace)
        XCTAssertLessThan(0.8 * shrugging.gestureStrength, tracker.baseline.intensity(of: easedSmile))
        XCTAssertLessThan(tracker.baseline.intensity(of: easedSmile), tracker.baseline.intensity(of: TestFaces.smile))
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.smile, step, pose: resting)))
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.smile, 4, pose: resting)))
        for step in 5...20 {
            tracker.ingest(frame(easedSmile, step, pose: shrugging))
        }
        let query = try XCTUnwrap(tracker.query)
        XCTAssertEqual(query.pose, shrugging)
        XCTAssertEqual(MoodClassifier.mood(for: query.face, pose: query.pose, baseline: tracker.baseline), .shrug)
    }

    func testSnapDuringAGestureHidingTheFaceKeepsTheGesture() {
        let tracker = PeakHoldTracker(baseline: RestingBaseline(sampleCount: 100))
        XCTAssertFalse(tracker.ingest(frame(TestFaces.surprise, 1, pose: nil)))
        XCTAssertFalse(tracker.ingest(frame(nil, 2, pose: facepalm)))
        XCTAssertTrue(tracker.snap())
        XCTAssertNil(tracker.query?.face)
        XCTAssertEqual(tracker.query?.timestamp, 0.2)
        XCTAssertEqual(tracker.queryIntensity, 0.8, accuracy: 1e-9)
        // A frame with neither a face nor a clear gesture isn't snapped.
        XCTAssertFalse(tracker.ingest(frame(nil, 3, pose: nil)))
        XCTAssertFalse(tracker.snap())
        XCTAssertEqual(tracker.query?.timestamp, 0.2)
    }

    func testSwitchingHandSignsIsANewExpression() {
        let tracker = PeakHoldTracker(baseline: RestingBaseline(sampleCount: 100))
        let thumbsUp = TestPoses.features(TestPoses.both(TestPoses.rest), hand: HandShape(thumbsUp: 1))
        let pointing = TestPoses.features(TestPoses.both(TestPoses.rest), hand: HandShape(point: 1))
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, step, pose: thumbsUp)))
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.neutral, 4, pose: thumbsUp)))

        // Same arm, another sign: a new expression, held for a second.
        XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, 5, pose: pointing)))
        XCTAssertTrue(tracker.candidateIsNewExpression)
        for step in 6...14 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, step, pose: pointing)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.neutral, 15, pose: pointing)))
        XCTAssertEqual(tracker.query?.pose, pointing)
        XCTAssertEqual(MoodClassifier.mood(for: TestFaces.neutral, pose: pointing, baseline: tracker.baseline), .pointing)
    }

    func testHornsWithTheArmsDownAreHeldAndReplacePointing() throws {
        let tracker = PeakHoldTracker(baseline: RestingBaseline(sampleCount: 100))
        let pointing = TestPoses.features(TestPoses.both(TestPoses.rest), hand: try XCTUnwrap(HandShape(TestHands.pointing())))
        let horns = TestPoses.features(TestPoses.both(TestPoses.rest), hand: try XCTUnwrap(HandShape(TestHands.rockOn())))
        // A finger pattern is a gesture of its own, the arms at rest.
        XCTAssertGreaterThanOrEqual(horns.gestureStrength, 0.7)
        for step in 1...3 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, step, pose: pointing)))
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.neutral, 4, pose: pointing)))

        // Same arms, horns: no word, but another sign — a new expression, held for a second.
        XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, 5, pose: horns)))
        XCTAssertTrue(tracker.candidateIsNewExpression)
        for step in 6...14 {
            XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, step, pose: horns)), "step \(step)")
        }
        XCTAssertTrue(tracker.ingest(frame(TestFaces.neutral, 15, pose: horns)))
        XCTAssertEqual(tracker.query?.pose, horns)
    }

    func testAnotherFingerPatternAfterHornsIsANewExpression() throws {
        // Both arms hanging; and standing back, one hand raised at the head with the other arm hanging straight, its
        // wrist under the shoulder (resting, but holding nothing).
        let hanging = TestArm(elbow: (x: 0.5, y: -0.8), wrist: (x: 0.5, y: -1.5))
        let bodies = [("arms hanging", TestPoses.both(TestPoses.rest)),
                      ("one hand raised", TestPoses.body(left: TestPoses.atHead, right: hanging.otherSide))]
        for (name, arms) in bodies {
            let tracker = PeakHoldTracker(baseline: RestingBaseline(sampleCount: 100))
            let horns = TestPoses.features(arms, hand: try XCTUnwrap(HandShape(TestHands.rockOn())))
            let hangLoose = TestPoses.features(arms, hand: HandShape(fingers: [1, 0, 0, 0, 1]))
            // Neither has a word, and the arms, the five sign scores and the gesture direction read the same: only the
            // fingers tell them apart.
            XCTAssertNil(MoodClassifier.gestureMood(try XCTUnwrap(horns.descriptor), face: TestFaces.neutral,
                                                    baseline: tracker.baseline), name)
            XCTAssertEqual(horns.descriptor?.gestureDirection, hangLoose.descriptor?.gestureDirection, name)
            XCTAssertEqual(PoseDescriptor.compare(try XCTUnwrap(horns.descriptor), try XCTUnwrap(hangLoose.descriptor)).similarity,
                           1, accuracy: 1e-9, name)
            for step in 1...3 {
                XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, step, pose: horns)), name)
            }
            XCTAssertTrue(tracker.ingest(frame(TestFaces.neutral, 4, pose: horns)), name)

            // Hang loose after horns: a new expression, held for a second.
            XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, 5, pose: hangLoose)), name)
            XCTAssertTrue(tracker.candidateIsNewExpression, name)
            for step in 6...14 {
                XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, step, pose: hangLoose)), "\(name), step \(step)")
            }
            XCTAssertTrue(tracker.ingest(frame(TestFaces.neutral, 15, pose: hangLoose)), name)
            XCTAssertEqual(tracker.query?.pose, hangLoose, name)
            // The same pattern held on is the same expression.
            XCTAssertFalse(tracker.ingest(frame(TestFaces.neutral, 16, pose: hangLoose)), name)
            XCTAssertFalse(tracker.candidateIsNewExpression, name)
        }
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
