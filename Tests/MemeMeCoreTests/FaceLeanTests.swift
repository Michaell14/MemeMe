import Foundation
import XCTest
@testable import MemeMeCore

final class FaceLeanTests: XCTestCase {
    func testTheLeanedPartCountsMostAndThePoseKeepsItsShare() {
        let base = FeatureWeights(brows: 2, eyes: 1, mouth: 3, pose: 0.3)
        let leaned = FaceLean.weights(base, leaningOn: .eyes)
        XCTAssertEqual(leaned.eyes, FaceLean.leanedWeight)
        XCTAssertEqual(leaned.brows, FaceLean.otherWeight)
        XCTAssertEqual(leaned.mouth, FaceLean.otherWeight)
        XCTAssertEqual(leaned.pose, 0.3)
    }

    func testTheWordIsReadFromTheLeanedPartWithTheRestAtRest() {
        let rest = FaceFeatures.populationNeutral
        let face = FaceFeatures(browRaise: 0.9, eyeOpenness: 0.85, mouthOpenness: 0.5, mouthWidth: 0.7, smile: 0.8,
                                headTilt: 0.4, gazeSide: 0.6)

        let mouth = FaceLean.face(face, leaningOn: .mouth, rest: rest)
        XCTAssertEqual(mouth.mouthOpenness, 0.5)
        XCTAssertEqual(mouth.mouthWidth, 0.7)
        XCTAssertEqual(mouth.smile, 0.8)
        XCTAssertEqual(mouth.browRaise, rest.browRaise)
        XCTAssertEqual(mouth.eyeOpenness, rest.eyeOpenness)
        XCTAssertEqual(mouth.gazeSide, rest.gazeSide)
        XCTAssertEqual(mouth.headTilt, rest.headTilt, "the head's tilt belongs to no part")

        let eyes = FaceLean.face(face, leaningOn: .eyes, rest: rest)
        XCTAssertEqual(eyes.eyeOpenness, 0.85)
        XCTAssertEqual(eyes.gazeSide, 0.6, "where you look is the eyes'")
        XCTAssertEqual(eyes.smile, rest.smile)

        let brows = FaceLean.face(face, leaningOn: .brows, rest: rest)
        XCTAssertEqual(brows.browRaise, 0.9)
        XCTAssertEqual(brows.mouthOpenness, rest.mouthOpenness)
    }

    func testLeaningOnTheMouthOfALaughReadsALaugh() {
        let baseline = RestingBaseline()
        let face = FaceFeatures(browRaise: 0.45, eyeOpenness: 0.2, mouthOpenness: 0.5, mouthWidth: 0.7, smile: 0.8,
                                headTilt: 0, gazeSide: 0.1)
        let sample = ExpressionSample(face: face, timestamp: 3)
        let leaned = FaceLean.sample(sample, leaningOn: .mouth, baseline: baseline)
        XCTAssertEqual(leaned.timestamp, 3)
        XCTAssertEqual(MoodClassifier.mood(for: leaned.face, pose: leaned.pose, shape: leaned.shape, baseline: baseline),
                       .laughing)
    }

    func testEachDetailBelongsToAPart() {
        XCTAssertEqual(FaceLean.region(of: .wink), .eyes)
        XCTAssertEqual(FaceLean.region(of: .eyeRoll), .eyes)
        XCTAssertEqual(FaceLean.region(of: .raisedBrow), .brows)
        XCTAssertEqual(FaceLean.region(of: .tongueOut), .mouth)
        XCTAssertEqual(FaceLean.region(of: .pucker), .mouth)
        XCTAssertEqual(FaceLean.region(of: .smirk), .mouth)
    }

    func testWithoutAFaceTheSampleStaysAsItIs() {
        let sample = ExpressionSample(face: nil, pose: .none, timestamp: 1)
        XCTAssertEqual(FaceLean.sample(sample, leaningOn: .brows, baseline: RestingBaseline()), sample)
        XCTAssertNil(FaceLean.shape(nil, leaningOn: .mouth, baseline: RestingBaseline()))
    }
}
