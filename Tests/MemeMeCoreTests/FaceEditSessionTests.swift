import Foundation
import XCTest
@testable import MemeMeCore

final class FaceEditSessionTests: XCTestCase {
    private let baseline = RestingBaseline()

    private func makeSession(_ face: FaceFeatures, shape: FaceShape? = nil) throws -> FaceEditSession {
        try XCTUnwrap(FaceEditSession(query: ExpressionSample(face: face, shape: shape, timestamp: 10), baseline: baseline))
    }

    /// Drags `handle` by `movement` (drawing space) and lets go.
    private func drag(_ session: inout FaceEditSession, _ handle: FaceHandle, by movement: SketchPoint,
                      pointer: SketchPoint = .zero) {
        session.beginDrag(handle)
        session.drag(by: movement, pointer: pointer)
        session.endDrag()
    }

    func testAPoseWithoutAFaceHasNothingToEdit() {
        XCTAssertNil(FaceEditSession(query: ExpressionSample(face: nil, timestamp: 1), baseline: baseline))
    }

    func testItStartsFromTheCaughtFaceAndItsAutomaticWeights() throws {
        let session = try makeSession(TestFaces.surprise)
        XCTAssertEqual(session.face, TestFaces.surprise)
        // Deviations 0.4 (brows), 0.2 (eyes), 0.4 (mouth): 3, 2, 3.
        XCTAssertEqual(session.weights, [.brows: 3, .eyes: 2, .mouth: 3])
        XCTAssertFalse(session.isEdited)
        XCTAssertFalse(session.canUndo)
        XCTAssertEqual(session.sample.face, TestFaces.surprise)
        XCTAssertEqual(session.sample.timestamp, 10)
    }

    func testDraggingTheLowerLipOpensTheMouthAndChangesTheWord() throws {
        var session = try makeSession(makeFace(brow: 0.8, eye: 0.8, mouth: 0.55, width: 0.38))
        XCTAssertEqual(session.mood(baseline: baseline), .shocked)

        session.beginDrag(.lowerLip)
        XCTAssertEqual(session.draggedHandle, .lowerLip)
        session.drag(by: SketchPoint(x: 0, y: 0.3 * FaceSketch.openTravel), pointer: .zero)
        XCTAssertEqual(session.face.mouthOpenness, 0.85, accuracy: 1e-9)
        XCTAssertEqual(session.mood(baseline: baseline), .screaming)
        session.endDrag()

        XCTAssertNil(session.draggedHandle)
        XCTAssertTrue(session.isEdited)
        XCTAssertTrue(session.canUndo)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.face.mouthOpenness, 0.55, accuracy: 1e-9)
        XCTAssertFalse(session.undo(), "nothing more to undo")
    }

    func testADragKeepsTheFaceItBeganWith() throws {
        var session = try makeSession(makeFace(brow: 0.8, eye: 0.8, mouth: 0.55, width: 0.38))
        XCTAssertNil(session.dragStartSketch)
        session.beginDrag(.lowerLip)
        session.drag(by: SketchPoint(x: 0, y: 8), pointer: .zero)
        XCTAssertEqual(session.dragStartSketch?.face.mouthOpenness ?? -1, 0.55, accuracy: 1e-9,
                       "the editor draws the mouth where it started, dashed")
        XCTAssertGreaterThan(session.face.mouthOpenness, 0.6)
        session.endDrag()
        XCTAssertNil(session.dragStartSketch)
    }

    func testEachFeatureFollowsTheDrag() throws {
        var session = try makeSession(TestFaces.neutral)

        drag(&session, .brow(.left), by: SketchPoint(x: 0, y: -7))
        XCTAssertEqual(session.face.browRaise, 0.7, accuracy: 1e-9)

        drag(&session, .eyelid(.right), by: SketchPoint(x: 3, y: -7))
        XCTAssertEqual(session.face.eyeOpenness, 0.95, accuracy: 1e-9)

        drag(&session, .pupil(.left), by: SketchPoint(x: 4.5, y: 2))
        XCTAssertEqual(session.face.gazeSide, 0.6, accuracy: 1e-9)

        drag(&session, .mouthCorner(.right), by: SketchPoint(x: 3, y: -7))
        XCTAssertEqual(session.face.mouthWidth, 0.55, accuracy: 1e-9)
        XCTAssertEqual(session.face.smile, 0.75, accuracy: 1e-9)

        drag(&session, .mouthCorner(.left), by: SketchPoint(x: -3, y: 0))
        XCTAssertEqual(session.face.mouthWidth, 0.65, accuracy: 1e-9, "the left corner widens the mouth outward too")

        drag(&session, .brow(.right), by: SketchPoint(x: 0, y: -100))
        XCTAssertEqual(session.face.browRaise, 1, "numbers stop at 1")

        XCTAssertEqual(session.face.headTilt, 0)
        XCTAssertEqual(session.face.mouthOpenness, TestFaces.neutral.mouthOpenness)
    }

    func testTheTopHandleTiltsTheHeadAndAFollowingDragGoesAlongTheTilt() throws {
        var session = try makeSession(TestFaces.neutral)
        let left = FaceSketch.rotate(FaceSketch.tiltHandlePoint, by: -22.5)
        drag(&session, .tilt, by: .zero, pointer: left)
        XCTAssertEqual(session.face.headTilt, 0.5, accuracy: 1e-9)
        XCTAssertEqual(session.tiltDirection, -1)
        XCTAssertEqual(session.sketch.tiltDegrees, -22.5, accuracy: 1e-9)

        // Straight down on screen is partly sideways in the tilted face: the lip still opens by what goes along it.
        let down = SketchPoint(x: 0, y: 10)
        drag(&session, .lowerLip, by: down)
        let along = FaceSketch.turn(down, by: 22.5).y
        XCTAssertEqual(session.face.mouthOpenness, TestFaces.neutral.mouthOpenness + along / FaceSketch.openTravel,
                       accuracy: 1e-9)
    }

    func testRingsStepWithTheDragAndThePinchWithoutTouchingTheFace() throws {
        var session = try makeSession(TestFaces.smile)
        XCTAssertEqual(session.weights, [.brows: 1, .eyes: 1, .mouth: 3])

        session.beginDrag(.ring(.brows))
        session.drag(by: SketchPoint(x: 25, y: 0), pointer: .zero)
        XCTAssertEqual(session.weight(.brows), 4, "a step every 10 points")
        session.drag(by: SketchPoint(x: 100, y: 0), pointer: .zero)
        XCTAssertEqual(session.weight(.brows), 5, "at most 5")
        session.drag(by: SketchPoint(x: -30, y: 0), pointer: .zero)
        XCTAssertEqual(session.weight(.brows), 0, "pulled all the way in, the brows are ignored")
        session.endDrag()
        XCTAssertFalse(session.featuresEdited)
        XCTAssertEqual(session.face, TestFaces.smile)
        XCTAssertTrue(session.canUndo)

        var pinched = try makeSession(TestFaces.smile)
        pinched.beginDrag(.ring(.mouth))
        pinched.pinch(by: 2)
        XCTAssertEqual(pinched.weight(.mouth), 5)
        pinched.pinch(by: 0.5)
        XCTAssertEqual(pinched.weight(.mouth), 0)
        pinched.pinch(by: 1)
        XCTAssertEqual(pinched.weight(.mouth), 3)
        pinched.endDrag()
        XCTAssertFalse(pinched.canUndo, "a pinch that ends where it began changes nothing")
    }

    func testStepsStopAtTheEnds() throws {
        var session = try makeSession(TestFaces.surprise)
        session.step(.mouth, by: 1)
        session.step(.mouth, by: 1)
        session.step(.mouth, by: 1)
        XCTAssertEqual(session.weight(.mouth), 5)
        session.step(.eyes, by: -5)
        XCTAssertEqual(session.weight(.eyes), 0)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.weight(.eyes), 2)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.weight(.mouth), 4)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.weight(.mouth), 3)
        XCTAssertFalse(session.undo(), "the step past 5 changed nothing, so there was nothing to undo")
    }

    func testStrokesSetWeightsAndTearsMakeItCrying() throws {
        var session = try makeSession(TestFaces.smile)
        XCTAssertNotEqual(session.mood(baseline: baseline), .crying)

        session.apply(.circle(.eyes), stroke: [])
        XCTAssertEqual(session.weight(.eyes), 5)
        session.apply(.scribble(.mouth), stroke: [])
        XCTAssertEqual(session.weight(.mouth), 0)

        let tear = [SketchPoint(x: 66, y: 108), SketchPoint(x: 64, y: 132)]
        session.apply(.tear, stroke: tear)
        XCTAssertEqual(session.tears, [tear])
        XCTAssertEqual(session.mood(baseline: baseline), .crying)

        XCTAssertTrue(session.undo())
        XCTAssertTrue(session.tears.isEmpty)
        XCTAssertNotEqual(session.mood(baseline: baseline), .crying)
    }

    func testDraggingAFeatureDropsTheFaceDetailButResizingDoesNot() throws {
        let shape = FaceShape(tongue: 0.45)
        var session = try makeSession(TestFaces.smile, shape: shape)
        XCTAssertEqual(session.sample.shape, shape)

        drag(&session, .ring(.mouth), by: SketchPoint(x: 10, y: 0))
        XCTAssertEqual(session.sample.shape, shape, "how much a part counts doesn't change the face")

        drag(&session, .mouthCorner(.left), by: SketchPoint(x: 0, y: -2))
        XCTAssertNil(session.sample.shape, "the drawing can't show a tongue: the word follows the seven numbers")
        XCTAssertTrue(session.featuresEdited)

        session.undo()
        XCTAssertEqual(session.sample.shape, shape)
    }

    func testTheRankersWeightsAreTheEditorsWithTheCaughtPoseShare() throws {
        var session = try makeSession(TestFaces.surprise)
        session.step(.brows, by: -3)
        let weights = session.featureWeights(baseline: baseline)
        XCTAssertEqual(weights.brows, 0)
        XCTAssertEqual(weights.eyes, 2)
        XCTAssertEqual(weights.mouth, 3)
        XCTAssertEqual(weights.pose, 0.05, accuracy: 1e-12, "no pose: the automatic small share")
    }

    func testResetGoesBackToTheCaughtFaceAndCanBeUndone() throws {
        var session = try makeSession(TestFaces.surprise)
        drag(&session, .lowerLip, by: SketchPoint(x: 0, y: 5))
        session.step(.eyes, by: 2)
        session.apply(.tear, stroke: [SketchPoint(x: 66, y: 108), SketchPoint(x: 64, y: 132)])
        XCTAssertTrue(session.isEdited)

        session.reset()
        XCTAssertFalse(session.isEdited)
        XCTAssertEqual(session.face, TestFaces.surprise)
        XCTAssertEqual(session.weights, [.brows: 3, .eyes: 2, .mouth: 3])
        XCTAssertTrue(session.tears.isEmpty)

        XCTAssertTrue(session.undo(), "Reset can be undone")
        XCTAssertTrue(session.isEdited)
        XCTAssertEqual(session.weight(.eyes), 4)
        XCTAssertEqual(session.tears.count, 1)
    }
}
