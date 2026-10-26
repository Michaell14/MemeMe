import Foundation
import XCTest
@testable import MemeMeCore

final class FaceFeaturesTests: XCTestCase {
    func testPopulationNeutralAndVectorOrder() {
        XCTAssertEqual(FaceFeatures.populationNeutral.vector, [0.45, 0.45, 0.05, 0.45, 0.5, 0.0, 0.1])
        let face = FaceFeatures(browRaise: 0.1, eyeOpenness: 0.2, mouthOpenness: 0.3, mouthWidth: 0.4,
                                smile: 0.5, headTilt: 0.6, gazeSide: 0.7)
        XCTAssertEqual(face.vector, [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7])
    }

    func testRegionIndices() {
        XCTAssertEqual(FaceRegion.allCases, [.brows, .eyes, .mouth])
        XCTAssertEqual(FaceFeatures.indices(for: .brows), [0])
        XCTAssertEqual(FaceFeatures.indices(for: .eyes), [1, 6])
        XCTAssertEqual(FaceFeatures.indices(for: .mouth), [2, 3, 4])
    }

    func testClampedLimitsEveryFieldToUnitRange() {
        let wild = FaceFeatures(browRaise: -0.5, eyeOpenness: 1.5, mouthOpenness: 0.3, mouthWidth: 2,
                                smile: -1, headTilt: 0.25, gazeSide: Double.nan)
        XCTAssertEqual(wild.clamped().vector, [0, 1, 0.3, 1, 0, 0.25, 0])
        XCTAssertEqual(TestFaces.surprise.clamped(), TestFaces.surprise)
    }

    func testVectorInitializerFallsBackToNeutral() {
        let partial = FaceFeatures(vector: [0.9, 0.8])
        XCTAssertEqual(partial.browRaise, 0.9)
        XCTAssertEqual(partial.eyeOpenness, 0.8)
        XCTAssertEqual(partial.mouthOpenness, 0.05)
        XCTAssertEqual(partial.gazeSide, 0.1)
        XCTAssertEqual(FaceFeatures(vector: TestFaces.smile.vector), TestFaces.smile)
    }

    func testPoseActivity() {
        XCTAssertEqual(PoseFeatures(handsRaised: 0.8, armsSpread: 0.4, bodyVisible: 0.5).activity, 0.4, accuracy: 1e-12)
        XCTAssertEqual(PoseFeatures(handsRaised: 0.2, armsSpread: 0.9, bodyVisible: 1).activity, 0.9, accuracy: 1e-12)
        XCTAssertEqual(PoseFeatures(handsRaised: 2, armsSpread: 0, bodyVisible: 1).activity, 1)
        XCTAssertEqual(PoseFeatures(handsRaised: 1, armsSpread: 1, bodyVisible: 0).activity, 0)
        XCTAssertEqual(PoseFeatures.none.activity, 0)
        XCTAssertEqual(PoseFeatures.none, PoseFeatures(handsRaised: 0, armsSpread: 0, bodyVisible: 0))
    }

    func testExpressionSampleDefaults() {
        let sample = ExpressionSample(face: nil, timestamp: 3)
        XCTAssertNil(sample.face)
        XCTAssertNil(sample.pose)
        XCTAssertEqual(sample.timestamp, 3)
        XCTAssertEqual(sample.sharpness, 1)
    }

    func testCodableRoundTrip() throws {
        let sample = ExpressionSample(face: TestFaces.surprise,
                                      pose: PoseFeatures(handsRaised: 1, armsSpread: 0.5, bodyVisible: 0.9),
                                      timestamp: 12.5,
                                      sharpness: 0.7)
        let data = try JSONEncoder().encode(sample)
        XCTAssertEqual(try JSONDecoder().decode(ExpressionSample.self, from: data), sample)
        let region = try JSONDecoder().decode([FaceRegion].self, from: Data(#"["mouth", "eyes"]"#.utf8))
        XCTAssertEqual(region, [.mouth, .eyes])
    }
}
