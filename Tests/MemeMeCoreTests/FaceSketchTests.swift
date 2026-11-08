import Foundation
import XCTest
@testable import MemeMeCore

final class FaceSketchTests: XCTestCase {
    func testFeaturesMoveByTheirTravelPerUnit() {
        let neutral = FaceSketch(face: TestFaces.neutral)

        let open = FaceSketch(face: makeFace(mouth: 0.55))
        XCTAssertEqual(open.lowerLipPoint.y - neutral.lowerLipPoint.y, 0.5 * FaceSketch.openTravel, accuracy: 1e-9)

        let wide = FaceSketch(face: makeFace(eye: 0.65))
        XCTAssertEqual(wide.eyeRadiusY - neutral.eyeRadiusY, 0.2 * FaceSketch.lidTravel, accuracy: 1e-9)

        let smiling = FaceSketch(face: makeFace(smile: 0.75))
        XCTAssertEqual(neutral.mouthLeft.y - smiling.mouthLeft.y, 0.25 * FaceSketch.smileTravel, accuracy: 1e-9)

        let wider = FaceSketch(face: makeFace(width: 0.55))
        XCTAssertEqual(wider.mouthRight.x - neutral.mouthRight.x, 0.1 * FaceSketch.widthTravel, accuracy: 1e-9)
        XCTAssertEqual(neutral.mouthLeft.x - wider.mouthLeft.x, 0.1 * FaceSketch.widthTravel, accuracy: 1e-9)

        let sideways = FaceSketch(face: makeFace(gaze: 0.6))
        XCTAssertEqual(sideways.pupilOffset - neutral.pupilOffset, 0.5 * FaceSketch.gazeTravel, accuracy: 1e-9)

        let raised = FaceSketch(face: makeFace(brow: 0.65))
        XCTAssertLessThan(raised.brow(.left).point(at: 0.5).y, neutral.brow(.left).point(at: 0.5).y, "raised brows go up")
        let lowered = FaceSketch(face: makeFace(brow: 0.15))
        XCTAssertGreaterThan(lowered.leftBrow.end.y, lowered.leftBrow.start.y, "lowered brows pull their inner ends down")
        XCTAssertLessThan(lowered.leftBrow.end.y, FaceSketch.eyeY - lowered.eyeRadiusY, "but never into the eyes")
    }

    func testTheMouthOpensBelowItsLine() {
        let sketch = FaceSketch(face: makeFace(mouth: 0.85))
        XCTAssertLessThan(sketch.upperLipPoint.y, FaceSketch.mouthY)
        XCTAssertEqual(sketch.lowerLipPoint.y - FaceSketch.mouthY, 3 * (FaceSketch.mouthY - sketch.upperLipPoint.y),
                       accuracy: 1e-9, "three quarters of the opening is below the line")
        let closed = FaceSketch(face: makeFace(mouth: 0))
        XCTAssertEqual(closed.upperLipPoint.y, closed.lowerLipPoint.y, accuracy: 1e-9, "a closed mouth is one line")
    }

    func testRingsGrowWithTheirWeightAndKeepAMinimumHeight() {
        let sketch = FaceSketch(face: TestFaces.neutral)
        let low = sketch.ring(.mouth, weight: 1)
        let high = sketch.ring(.mouth, weight: 4)
        XCTAssertEqual(high.maxX - low.maxX, 3 * FaceSketch.ringStep, accuracy: 1e-9)
        XCTAssertEqual(low.minX - high.minX, 3 * FaceSketch.ringStep, accuracy: 1e-9)
        for region in FaceRegion.allCases {
            XCTAssertGreaterThanOrEqual(sketch.ring(region, weight: 0).height, FaceSketch.minimumRingHeight - 1e-9)
            XCTAssertTrue(sketch.ring(region, weight: 0).contains(sketch.bounds(of: region).center))
        }
        XCTAssertEqual(sketch.ring(.brows, weight: 9), sketch.ring(.brows, weight: 5), "weights stop at 5")
        XCTAssertEqual(sketch.ring(.brows, weight: -2), sketch.ring(.brows, weight: 0))
    }

    func testEveryHandleIsFoundWhereItSits() {
        let sketch = FaceSketch(face: TestFaces.surprise)
        let weights: [FaceRegion: Double] = [.brows: 2, .eyes: 2, .mouth: 3]
        for handle in FaceHandle.all {
            let point = sketch.position(of: handle, weights: weights)
            XCTAssertEqual(sketch.handle(at: point, weights: weights), handle, "\(handle)")
        }
        XCTAssertEqual(sketch.handle(at: sketch.leftBrow.point(at: 0.1), weights: weights), .brow(.left),
                       "a brow can be taken anywhere along it")
        XCTAssertNil(sketch.handle(at: SketchPoint(x: 100, y: 192), weights: weights), "nothing below the chin")
        XCTAssertNil(sketch.handle(at: SketchPoint(x: 100, y: 120), weights: weights), "nor between the eyes and mouth")
    }

    func testRegionsAreFoundByTheirRings() {
        let sketch = FaceSketch(face: TestFaces.neutral)
        let weights: [FaceRegion: Double] = [.brows: 1, .eyes: 1, .mouth: 1]
        for region in FaceRegion.allCases {
            XCTAssertEqual(sketch.region(at: sketch.bounds(of: region).center, weights: weights), region)
        }
        XCTAssertNil(sketch.region(at: SketchPoint(x: 10, y: 10), weights: weights))
    }

    func testTiltTurnsTheDrawingAndBack() {
        let sketch = FaceSketch(face: makeFace(tilt: 0.5), tiltDirection: -1)
        XCTAssertEqual(sketch.tiltDegrees, -22.5, accuracy: 1e-9)
        let point = SketchPoint(x: 140, y: 60)
        let back = sketch.toFace(sketch.fromFace(point))
        XCTAssertEqual(back.x, point.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, point.y, accuracy: 1e-9)
        XCTAssertEqual(sketch.toFace(FaceSketch.center), FaceSketch.center, "the head turns around its center")

        let up = FaceSketch.tilt(towards: FaceSketch.tiltHandlePoint)
        XCTAssertEqual(up.headTilt, 0, accuracy: 1e-9)

        let right = FaceSketch.tilt(towards: SketchPoint(x: 186, y: 106))   // a quarter turn: past the 45° limit
        XCTAssertEqual(right.headTilt, 1, accuracy: 1e-9)
        XCTAssertEqual(right.direction, 1)

        let left = FaceSketch.tilt(towards: FaceSketch.rotate(FaceSketch.tiltHandlePoint, by: -22.5))
        XCTAssertEqual(left.headTilt, 0.5, accuracy: 1e-9)
        XCTAssertEqual(left.direction, -1)
    }
}
