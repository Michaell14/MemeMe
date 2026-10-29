import Foundation
import XCTest
@testable import MemeMeCore

final class PoseDescriptionTests: XCTestCase {
    /// `FullBodyPoses.flex`'s arm on one side only, the other hanging: one arm flexed beside the head.
    private static let flexedArm = TestArm(elbow: (x: 1.25, y: 0.1), wrist: (x: 1.0, y: 0.85))
    private let oneArmFlexed = TestPoses.body(left: TestPoses.rest, right: PoseDescriptionTests.flexedArm.otherSide)
    private let baseline = RestingBaseline()

    private func sample(_ joints: BodyJoints, hand: HandShape? = nil, face: FaceFeatures? = nil) -> ExpressionSample {
        ExpressionSample(face: face, pose: TestPoses.features(joints, hand: hand), timestamp: 0)
    }

    private func describe(_ joints: BodyJoints, hand: HandShape? = nil, face: FaceFeatures? = nil,
                          file: StaticString = #filePath, line: UInt = #line) throws -> PoseDescription {
        try XCTUnwrap(PoseDescription.of(sample(joints, hand: hand, face: face), baseline: baseline),
                      "a clear gesture with no word is described", file: file, line: line)
    }

    /// Never a side: Vision's sides aren't checked against the mirror, and memes may be flipped.
    private func assertNoSides(_ description: PoseDescription, file: StaticString = #filePath, line: UInt = #line) {
        let words = description.key.lowercased().split(whereSeparator: { !$0.isLetter }).map { String($0) }
        XCTAssertFalse(words.contains("left"), description.key, file: file, line: line)
        XCTAssertFalse(words.contains("right"), description.key, file: file, line: line)
    }

    // MARK: Describing

    func testOneArmFlexedBesideTheHeadIsFlexingWithAFistOrNoHandRead() throws {
        let hands: [(String, HandShape?)] = [
            ("no hand read", nil),
            ("a fist", HandShape(fist: 1)),
            ("a fist read from its joints", try XCTUnwrap(HandShape(TestHands.fist()))),
        ]
        for (name, hand) in hands {
            XCTAssertNil(try XCTUnwrap(PoseDescriptor(oneArmFlexed, hand: hand)).bodyShape, "\(name): hello needs an open palm")
            XCTAssertEqual(PoseBadge.of(sample(oneArmFlexed, hand: hand), baseline: baseline), .pose, "\(name): a pose without a word")
            let description = try describe(oneArmFlexed, hand: hand)
            XCTAssertEqual(description.phrase, "flexing", name)
            XCTAssertTrue(description.facts.contains { $0.contains("bent") && $0.contains("head") },
                          "\(name): the arm's fact tells the bent elbow and the head: \(description.key)")
            XCTAssertEqual(description.facts.first?.hasPrefix("One arm:"), true, "\(name): the flexed arm first: \(description.key)")
            XCTAssertTrue(description.facts.contains("The other arm hangs at the side."), "\(name): \(description.key)")
            assertNoSides(description)
        }
        XCTAssertTrue(try describe(oneArmFlexed).facts.contains("Hands: not seen."))
        XCTAssertTrue(try describe(oneArmFlexed, hand: HandShape(fist: 1)).facts.contains("One hand: a fist."))
    }

    func testARelaxedOpenHandHangingLowDoesntMakeAFlexHello() throws {
        // The flexed arm's hand up by the head, the other hand hanging open by the hip.
        let raisedWrist = try XCTUnwrap(oneArmFlexed[.rightWrist])
        let hangingOpen = TestHands.placed(TestHands.openPalm(), at: try XCTUnwrap(oneArmFlexed[.leftWrist]))
        let fist = TestHands.placed(TestHands.fist(), at: raisedWrist)
        // A loose fist (fist ≈ 0.68, no finger straight) is no clearer than the open hand below: its fingers still tell.
        let ratios = [0.8, 0.78, 0.82, 0.88]
        let joints: [(HandJoint, HandJoint, Double)] = [(.indexPIP, .indexTip, 0.3), (.middlePIP, .middleTip, 0.1),
                                                         (.ringPIP, .ringTip, -0.1), (.littlePIP, .littleTip, -0.3)]
        var loosePoints: [HandJoint: PosePoint] = [.wrist: PosePoint(x: 0, y: 0)]
        for ((pip, tip, y), ratio) in zip(joints, ratios) {
            loosePoints[pip] = PosePoint(x: 1, y: y)
            loosePoints[tip] = PosePoint(x: ratio, y: ratio * y)
        }
        let looseFist = TestHands.placed(HandJoints(points: loosePoints), at: raisedWrist)
        // A fist whose fingertips weren't seen can't be read at all.
        let unreadFist = HandJoints(points: [.wrist: raisedWrist, .indexPIP: PosePoint(x: raisedWrist.x + 0.06, y: raisedWrist.y),
                                             .indexTip: PosePoint(x: raisedWrist.x + 0.04, y: raisedWrist.y)])
        XCTAssertNil(HandShape(unreadFist))
        let cases: [(String, [HandJoints])] = [
            ("both read", [hangingOpen, fist]), ("both read, the raised one last", [fist, hangingOpen]),
            ("a loose fist", [hangingOpen, looseFist]), ("the fist not read", [unreadFist, hangingOpen]),
            ("the fist not found", [hangingOpen]),
        ]
        for (name, hands) in cases {
            let hand = try XCTUnwrap(HandShape.strongest(of: hands, on: oneArmFlexed), name)
            XCTAssertLessThan(hand.openPalm, 0.5, "\(name): the raised hand tells, not the open hand hanging below it")
            XCTAssertNil(try XCTUnwrap(PoseDescriptor(oneArmFlexed, hand: hand)).bodyShape, "\(name): no hello")
            let description = try describe(oneArmFlexed, hand: hand)
            XCTAssertEqual(description.phrase, "flexing", name)
            XCTAssertFalse(description.key.contains("open palm"), "\(name): the hanging hand isn't the one told: \(description.key)")
        }
        XCTAssertGreaterThan(try XCTUnwrap(HandShape.strongest(of: [hangingOpen, fist], on: oneArmFlexed)).fist, 0.9)
        let loose = try XCTUnwrap(HandShape.strongest(of: [hangingOpen, looseFist], on: oneArmFlexed))
        XCTAssertEqual(loose.fingers, HandShape(looseFist)?.fingers)
        XCTAssertTrue(try describe(oneArmFlexed, hand: loose).facts.contains("One hand: a fist."))
        // Waving with the other hand hanging open too is still hello.
        let palm = TestHands.placed(TestHands.openPalm(), at: raisedWrist)
        let waving = try XCTUnwrap(HandShape.strongest(of: [hangingOpen, palm], on: oneArmFlexed))
        XCTAssertEqual(PoseDescriptor(oneArmFlexed, hand: waving)?.bodyShape, .hello)
        // A clear sign made with the hand below still tells its fingers beside a raised fist.
        let horns = TestHands.placed(TestHands.rockOn(), at: try XCTUnwrap(oneArmFlexed[.leftWrist]))
        let withHorns = try XCTUnwrap(HandShape.strongest(of: [fist, horns], on: oneArmFlexed))
        XCTAssertEqual(withHorns.fingers, HandShape(horns)?.fingers)
        XCTAssertGreaterThan(withHorns.fist, 0.9)
    }

    func testBothHandsCountAlikeWhenTheWristsAreLevel() throws {
        // Clapping, the hand behind a hair higher and only two of its fingers seen: the open hand in front still tells.
        let behind = TestArm(elbow: (x: -0.6, y: -0.5), wrist: (x: -0.03, y: 0.12))
        let clap = TestPoses.body(left: TestPoses.clap, right: behind)
        let front = TestHands.placed(TestHands.openPalm(), at: try XCTUnwrap(clap[.leftWrist]))
        let seen: Set<HandJoint> = [.wrist, .indexPIP, .indexTip, .middlePIP, .middleTip]
        let twoFingers = HandJoints(points: TestHands.openPalm().points.filter { seen.contains($0.key) })
        let hidden = TestHands.placed(twoFingers, at: try XCTUnwrap(clap[.rightWrist]))
        XCTAssertEqual(try XCTUnwrap(HandShape(hidden)).openPalm, 0, "too few fingers to tell")
        let hand = try XCTUnwrap(HandShape.strongest(of: [hidden, front], on: clap))
        XCTAssertGreaterThan(hand.openPalm, 0.9)
        let mood = MoodClassifier.mood(for: TestFaces.neutral, pose: TestPoses.features(clap, hand: hand), baseline: baseline)
        XCTAssertEqual(mood, .clapping)
    }

    func testAFistPressedToTheHeadIsFlexing() throws {
        // One arm flexed with the fist against the temple: the wrist is as close to the head as a hand on the chin, and
        // below the head's centre, but a fist there is a flex (a hand on the chin hangs its elbow low; a salute or a
        // hand on the head is flat).
        let fistAtTheTemple = TestArm(elbow: (x: 1.05, y: 0.35), wrist: (x: 0.28, y: 0.55))
        let joints = TestPoses.body(left: TestPoses.rest, right: fistAtTheTemple.otherSide)
        let fists = [HandShape(fist: 1), try XCTUnwrap(HandShape(TestHands.fist()))]
        for hand in fists {
            let description = try describe(joints, hand: hand, face: TestFaces.neutral)
            XCTAssertEqual(description.phrase, "flexing", description.key)
            XCTAssertTrue(description.key.contains("hand on the face at the chin"), description.key)
        }
    }

    func testTheSameArmWithAnOpenPalmSaysHello() throws {
        let palm = try XCTUnwrap(HandShape(TestHands.openPalm()))
        XCTAssertEqual(PoseDescriptor(oneArmFlexed, hand: palm)?.bodyShape, .hello)
        XCTAssertEqual(PoseBadge.of(sample(oneArmFlexed, hand: palm), baseline: baseline), .word(.hello))
        XCTAssertNil(PoseDescription.of(sample(oneArmFlexed, hand: palm), baseline: baseline), "a pose with a word isn't described")
    }

    func testEitherArmAndAFlippedImageReadTheSame() throws {
        let flexed = try describe(oneArmFlexed)
        let otherArm = try describe(TestPoses.body(left: PoseDescriptionTests.flexedArm, right: TestPoses.rest.otherSide))
        let flipped = try describe(TestPoses.body(left: TestPoses.rest, right: PoseDescriptionTests.flexedArm.otherSide,
                                                  mirrored: true))
        XCTAssertEqual(otherArm, flexed)
        XCTAssertEqual(flipped, flexed)
    }

    func testAHandOnTheChinIsThinking() throws {
        // A hand on the face below the head's centre, the eyes open (shut, it would be a facepalm, which has its word).
        let chin = TestPoses.body(left: TestPoses.onFace, right: TestPoses.rest.otherSide)
        let description = try describe(chin, face: TestFaces.neutral)
        XCTAssertEqual(description.phrase, "thinking")
        XCTAssertTrue(description.facts.contains { $0.contains("hand on the face at the chin") }, description.key)
        XCTAssertFalse(description.key.contains("Face:"), "a calm face says nothing: \(description.key)")
        assertNoSides(description)
        XCTAssertNil(PoseDescription.of(sample(chin, face: makeFace(eye: 0.15)), baseline: baseline), "a facepalm")
    }

    func testAHandOnTopOfTheHeadIsHandOnHead() throws {
        // Oh no's arm on one side only.
        let description = try describe(TestPoses.body(left: TestArm(elbow: (x: 1.0, y: 0.75), wrist: (x: 0.18, y: 1.15)),
                                                      right: TestPoses.rest.otherSide), face: TestFaces.neutral)
        XCTAssertEqual(description.phrase, "hand on head")
        XCTAssertTrue(description.key.contains("hand on top of the head"), description.key)
    }

    func testArmsOutInFrontAreDescribed() throws {
        let description = try describe(FullBodyPoses.zombie, face: TestFaces.neutral)
        XCTAssertFalse(description.phrase.isEmpty)
        XCTAssertEqual(description.phrase, "strike a pose", "no rule names it; the model may")
        XCTAssertEqual(description.facts.first, "Both arms: arm straight, reaching toward the camera, hand at shoulder height.")
        assertNoSides(description)
    }

    func testPosesWithAWordAndRestingArmsAreNotDescribed() {
        XCTAssertNil(PoseDescription.of(sample(FullBodyPoses.tPose), baseline: baseline), "a t-pose has its word")
        XCTAssertNil(PoseDescription.of(sample(FullBodyPoses.flex), baseline: baseline), "both arms flexed is flex")
        XCTAssertNil(PoseDescription.of(sample(TestPoses.both(TestPoses.rest), hand: HandShape(point: 1)), baseline: baseline),
                     "pointing has its word")
        XCTAssertNil(PoseDescription.of(sample(TestPoses.both(TestPoses.rest), face: TestFaces.neutral), baseline: baseline),
                     "arms at rest are no gesture")
        XCTAssertNil(PoseDescription.of(ExpressionSample(face: TestFaces.surprise, timestamp: 0), baseline: baseline), "a face alone")
    }

    // MARK: Hands

    func testHornsAreRockOn() throws {
        let rockOn = try XCTUnwrap(HandShape(TestHands.rockOn()))
        let description = try describe(TestPoses.both(TestPoses.rest), hand: rockOn, face: TestFaces.neutral)
        XCTAssertEqual(description.phrase, "rock on")
        XCTAssertEqual(description.facts.first, "One hand: index and little fingers straight, the others curled.",
                       "the hand tells the most, so it comes first")
        XCTAssertTrue(description.facts.contains("Both arms hang at the side."), description.key)
        assertNoSides(description)
        // Fingertips on the face (a finger up the cheek) are no sign: with the arms down, no gesture at all.
        let onFace = try XCTUnwrap(HandShape(TestHands.rockOn(), faceBox: PoseBox(minX: 1.5, minY: 0, maxX: 2, maxY: 1)))
        XCTAssertNil(PoseDescription.of(sample(TestPoses.both(TestPoses.rest), hand: onFace, face: TestFaces.neutral),
                                        baseline: baseline))
    }

    func testOtherFingerPatternsAndTheirWords() throws {
        let cases: [(fingers: [Double?], phrase: String, fact: String)] = [
            ([1, 0, 0, 0, 1], "hang loose", "One hand: thumb and little finger straight, the others curled."),
            ([1, 1, 0, 0, 0], "finger guns", "One hand: thumb and index finger straight, the others curled."),
            ([1, 1, 0, 0, 1], "love you", "One hand: thumb, index and little fingers straight, the others curled."),
            // Three fingers up has no phrase of its own: the arms (at rest) give none either.
            ([0, 1, 1, 1, 0], "strike a pose", "One hand: index, middle and ring fingers straight, the others curled."),
            ([nil, 1, 0.5, 0, 0], "strike a pose", "One hand: index finger straight, middle finger half bent, ring and little fingers curled."),
        ]
        for (fingers, phrase, fact) in cases {
            let description = try describe(TestPoses.both(TestPoses.rest), hand: HandShape(fingers: fingers))
            XCTAssertEqual(description.phrase, phrase, fact)
            XCTAssertEqual(description.facts.first, fact)
        }
    }

    func testAThumbAloneOutOfAFistIsNoPoseOfItsOwn() {
        // A thumbs down, or a thumbs up tilted too far to be one, held low or in front of the chest: a thumb alone
        // stands as clear of a fist as one round a mug, so it is no finger pattern, and the face's mood is searched.
        let thumbOut = HandShape(fingers: [1, 0, 0, 0, 0])
        let atTheChest = TestPoses.body(left: TestArm(elbow: (x: 0.55, y: -0.9), wrist: (x: 0.2, y: -0.3)),
                                        right: TestPoses.rest.otherSide)
        for joints in [TestPoses.both(TestPoses.rest), atTheChest] {
            let thumb = sample(joints, hand: thumbOut, face: TestFaces.neutral)
            XCTAssertNil(PoseBadge.of(thumb, baseline: baseline))
            XCTAssertNil(PoseDescription.of(thumb, baseline: baseline))
        }
    }

    func testAPhonesGripBesideAFlexedArmIsNoFingerPattern() throws {
        // One arm flexed, the other hand holding a phone at the chest, its grip (thumb on the screen, index along the
        // back, the others round the edge) read as finger guns: a wrist that may be holding something makes no finger
        // pattern a sign, so the flexed arm names the pose, and the hand comes last.
        let phone = TestArm(elbow: (x: 0.55, y: -0.9), wrist: (x: 0.15, y: -0.45))
        let grip = HandShape(fingers: [1, 1, 0, 0, 0])
        let withPhone = TestPoses.body(left: phone, right: PoseDescriptionTests.flexedArm.otherSide)
        let description = try describe(withPhone, hand: grip, face: TestFaces.neutral)
        XCTAssertEqual(description.phrase, "flexing")
        XCTAssertEqual(description.facts.first?.hasPrefix("One arm:"), true, description.key)
        XCTAssertEqual(description.facts.last, "One hand: thumb and index finger straight, the others curled.", description.key)
        // The same fingers with the other arm hanging are finger guns.
        XCTAssertEqual(try describe(oneArmFlexed, hand: grip, face: TestFaces.neutral).phrase, "finger guns")
    }

    // MARK: Face, key and phrase

    func testTheFaceIsToldWhenSomethingAboutItStandsOut() throws {
        let shouting = try describe(oneArmFlexed, face: makeFace(brow: 0.6, mouth: 0.5))
        XCTAssertEqual(shouting.facts.last, "Face: mouth wide open, eyebrows raised.")
        XCTAssertEqual(shouting.phrase, "flexing", "the phrase is the pose's")
        XCTAssertFalse(try describe(oneArmFlexed, face: TestFaces.neutral).key.contains("Face:"), "a calm face says nothing")
        XCTAssertEqual(try describe(oneArmFlexed).facts.last, "Face: not seen.")
    }

    func testTheKeyIsTheSameForNearlyTheSamePose() throws {
        let flexed = try describe(oneArmFlexed)
        let nearly = try describe(TestPoses.body(left: TestPoses.rest,
                                                 right: TestArm(elbow: (x: 1.27, y: 0.12), wrist: (x: 1.02, y: 0.83)).otherSide))
        XCTAssertEqual(nearly.key, flexed.key)
        XCTAssertEqual(flexed.key, flexed.facts.joined(separator: "\n"))
        let thinking = try describe(TestPoses.body(left: TestPoses.onFace, right: TestPoses.rest.otherSide), face: TestFaces.neutral)
        XCTAssertNotEqual(thinking.key, flexed.key)
    }

    func testThePhraseIsNeverEmpty() {
        XCTAssertEqual(PoseDescription(facts: ["Both arms hang at the side."], phrase: "").phrase, "strike a pose")
        XCTAssertEqual(PoseDescription(facts: [], phrase: "flexing").phrase, "flexing")
    }

    // MARK: Cleaning a model's name

    func testAModelsNameIsCleanedToAFewLowercaseWords() {
        XCTAssertEqual(PoseDescription.cleanName("Flexing."), "flexing")
        let sentence = PoseDescription.cleanName("The person is flexing their bicep")
        XCTAssertEqual(sentence?.hasPrefix("flexing"), true, String(describing: sentence))
        XCTAssertLessThanOrEqual(sentence?.split(separator: " ").count ?? 99, 3, String(describing: sentence))
        XCTAssertEqual(PoseDescription.cleanName("\"rock on\""), "rock on")
        XCTAssertEqual(PoseDescription.cleanName("\u{201C}Rock on!\u{201D}"), "rock on")
        XCTAssertEqual(PoseDescription.cleanName("It\u{2019}s a salute."), "salute")
        XCTAssertEqual(PoseDescription.cleanName("  finger-guns  "), "finger-guns")
        XCTAssertEqual(PoseDescription.cleanName("Thinking\nThe person rests their chin on one hand."), "thinking",
                       "the first line only")
    }

    func testRefusalsAndScrapsAreNoName() {
        XCTAssertNil(PoseDescription.cleanName("Sorry, I can't help with that"))
        XCTAssertNil(PoseDescription.cleanName("I cannot identify people."))
        XCTAssertNil(PoseDescription.cleanName("As an AI, I am unable to see images."))
        XCTAssertNil(PoseDescription.cleanName(""))
        XCTAssertNil(PoseDescription.cleanName("ok"), "fewer than 3 letters")
        XCTAssertNil(PoseDescription.cleanName("..."))
        XCTAssertNil(PoseDescription.cleanName("supercalifragilistic expialidocious extravaganza"), "longer than 30 characters")
    }
}
