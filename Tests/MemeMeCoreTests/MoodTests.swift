import Foundation
import XCTest
@testable import MemeMeCore

final class MoodTests: XCTestCase {
    private func classify(_ face: FaceFeatures?, pose: PoseFeatures? = nil,
                          baseline: RestingBaseline = RestingBaseline()) -> Mood {
        MoodClassifier.mood(for: face, pose: pose, baseline: baseline)
    }

    private func pose(hands: Double = 0, arms: Double = 0, body: Double = 1) -> PoseFeatures {
        PoseFeatures(handsRaised: hands, armsSpread: arms, bodyVisible: body)
    }

    func testRule1NoFaceIsAGenericReaction() {
        XCTAssertEqual(classify(nil), .reaction)
        XCTAssertEqual(classify(nil, pose: pose(hands: 1)), .reaction)
    }

    func testRule2HandsUpWithAnOpenMouthIsScreaming() {
        XCTAssertEqual(classify(makeFace(mouth: 0.4), pose: pose(hands: 0.6)), .screaming)
        // handsRaised alone decides, even when the body confidence is low.
        XCTAssertEqual(classify(makeFace(mouth: 0.4), pose: pose(hands: 0.6, body: 0)), .screaming)
    }

    func testRule2ActiveBodyWithASmileIsExcited() {
        XCTAssertEqual(classify(makeFace(mouth: 0.1, smile: 0.7), pose: pose(hands: 0.6)), .excited)
        XCTAssertEqual(classify(makeFace(mouth: 0.1, smile: 0.7), pose: pose(arms: 0.8)), .excited)
        // activity = 0.6 × 0.5 = 0.3 is not enough: falls through to rule 7.
        XCTAssertEqual(classify(makeFace(mouth: 0.1, smile: 0.7), pose: pose(hands: 0.6, body: 0.5)), .happy)
    }

    func testRule3OpenMouthWithWideEyesOrRaisedBrowsIsShocked() {
        XCTAssertEqual(classify(makeFace(eye: 0.6, mouth: 0.5)), .shocked)
        XCTAssertEqual(classify(makeFace(brow: 0.6, mouth: 0.5)), .shocked)
    }

    func testRule3VeryOpenMouthIsScreaming() {
        XCTAssertEqual(classify(makeFace(eye: 0.6, mouth: 0.8)), .screaming)
    }

    func testRule3NeedsEyesOrBrowsAndNoSmile() {
        XCTAssertEqual(classify(makeFace(mouth: 0.5)), .unimpressed)
        // Smiling with the same open mouth is laughter (rule 4), not shock.
        XCTAssertEqual(classify(makeFace(eye: 0.6, mouth: 0.5, smile: 0.6)), .laughing)
    }

    func testRule4OpenMouthSmileIsLaughing() {
        XCTAssertEqual(classify(makeFace(mouth: 0.3, smile: 0.65)), .laughing)
    }

    func testRule5WideEyesAndRaisedBrowsAreShocked() {
        XCTAssertEqual(classify(makeFace(brow: 0.6, eye: 0.62)), .shocked)
    }

    func testRule6SideEye() {
        XCTAssertEqual(classify(makeFace(gaze: 0.6)), .sideEye)
        XCTAssertEqual(classify(makeFace(smile: 0.7, gaze: 0.6)), .sideEye)     // before the smile rules
    }

    func testRule7SmileIsHappyOrSmug() {
        XCTAssertEqual(classify(makeFace(smile: 0.7)), .happy)
        XCTAssertEqual(classify(makeFace(eye: 0.3, smile: 0.7)), .smug)
    }

    func testRule8FrownIsCryingOrSad() {
        XCTAssertEqual(classify(makeFace(brow: 0.55, smile: 0.35)), .crying)
        XCTAssertEqual(classify(makeFace(smile: 0.35)), .sad)
    }

    func testRule9RaisedBrowsWithSlightFrownAreNervous() {
        XCTAssertEqual(classify(makeFace(brow: 0.6, smile: 0.45)), .nervous)
    }

    func testRule10LoweredBrowsAreAngry() {
        XCTAssertEqual(classify(makeFace(brow: 0.3)), .angry)
    }

    func testRule11HeadTiltIsConfused() {
        XCTAssertEqual(classify(makeFace(tilt: 0.4)), .confused)
    }

    func testRule12EverythingElseIsUnimpressed() {
        XCTAssertEqual(classify(TestFaces.neutral), .unimpressed)
        XCTAssertEqual(classify(TestFaces.neutral, pose: PoseFeatures.none), .unimpressed)
    }

    func testDeviationIsMeasuredFromTheUsersOwnRestingFace() {
        let face = makeFace(brow: 0.45, eye: 0.5)
        let droopy = RestingBaseline(neutral: makeFace(brow: 0.3, eye: 0.3))
        XCTAssertEqual(classify(face, baseline: droopy), .shocked)       // eyes +0.2, brows +0.15 for this user
        XCTAssertEqual(classify(face), .unimpressed)                     // barely moved for the average face
    }

    func testSearchQueries() {
        let expected: [Mood: String] = [
            .shocked: "shocked reaction",
            .screaming: "screaming reaction",
            .laughing: "laughing reaction",
            .happy: "happy reaction",
            .smug: "smug reaction",
            .sideEye: "side eye",
            .crying: "crying reaction",
            .sad: "sad reaction",
            .angry: "angry reaction",
            .confused: "confused reaction",
            .unimpressed: "unimpressed",
            .nervous: "nervous reaction",
            .excited: "excited reaction",
            .reaction: "reaction",
        ]
        XCTAssertEqual(expected.count, Mood.allCases.count)
        for mood in Mood.allCases {
            XCTAssertEqual(mood.searchQuery, expected[mood], "\(mood)")
        }
    }

    func testLabels() {
        XCTAssertEqual(Mood.shocked.label, "shocked")
        XCTAssertEqual(Mood.sideEye.label, "side eye")
        XCTAssertEqual(Mood.unimpressed.label, "unimpressed")
        XCTAssertEqual(Mood.reaction.label, "reaction")
        for mood in Mood.allCases {
            XCTAssertFalse(mood.label.isEmpty)
            XCTAssertEqual(mood.label, mood.label.lowercased())
        }
    }

    func testRawValuesAreStable() {
        XCTAssertEqual(Mood.sideEye.rawValue, "sideEye")
    }
}
