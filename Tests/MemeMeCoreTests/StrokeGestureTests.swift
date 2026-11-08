import Foundation
import XCTest
@testable import MemeMeCore

final class StrokeGestureTests: XCTestCase {
    private let sketch = FaceSketch(face: TestFaces.neutral)
    private let weights: [FaceRegion: Double] = [.brows: 1, .eyes: 1, .mouth: 1]

    /// A hand-drawn loop: a little more than once around, ends overlapping.
    private func loop(around center: SketchPoint, width: Double, height: Double, turns: Double = 1.1) -> [SketchPoint] {
        stride(from: 0.0, through: turns * 2 * Double.pi, by: 0.15).map { angle in
            SketchPoint(x: center.x + width / 2 * cos(angle), y: center.y + height / 2 * sin(angle))
        }
    }

    private func read(_ points: [SketchPoint]) -> StrokeGesture? {
        StrokeGesture.read(points, on: sketch, weights: weights)
    }

    func testACircleMakesItsPartCountMost() {
        let mouth = sketch.ring(.mouth, weight: 1).center
        XCTAssertEqual(read(loop(around: mouth, width: 80, height: 36)), .circle(.mouth))
        let brows = sketch.ring(.brows, weight: 1).center
        XCTAssertEqual(read(loop(around: brows, width: 112, height: 28)), .circle(.brows))
        let eyes = sketch.ring(.eyes, weight: 1).center
        XCTAssertEqual(read(loop(around: eyes, width: 104, height: 30)), .circle(.eyes))
    }

    func testAScribbleOrALineThroughAPartIgnoresIt() {
        let brows = sketch.ring(.brows, weight: 1).center
        let zigzag = (0...12).map { SketchPoint(x: 50 + Double($0) * 8, y: brows.y + ($0 % 2 == 0 ? -6 : 6)) }
        XCTAssertEqual(read(zigzag), .scribble(.brows), "up and down along the brows")

        let mouthY = sketch.ring(.mouth, weight: 1).midY
        let backAndForth = [80.0, 120, 80, 120, 80].enumerated().flatMap { index, x -> [SketchPoint] in
            let next = index % 2 == 0 ? x + 40 : x - 40
            return stride(from: 0.0, through: 1, by: 0.25).map { t in
                SketchPoint(x: x + (next - x) * t, y: mouthY + Double(index))
            }
        }
        XCTAssertEqual(read(backAndForth), .scribble(.mouth), "back and forth over the mouth")

        let line = stride(from: 60.0, through: 140, by: 5).map { SketchPoint(x: $0, y: mouthY) }
        XCTAssertEqual(read(line), .scribble(.mouth), "a line through the mouth")
    }

    func testALineDownFromAnEyeIsATear() {
        let tear = [SketchPoint(x: 66, y: 108), SketchPoint(x: 64, y: 114), SketchPoint(x: 67, y: 120),
                    SketchPoint(x: 65, y: 126), SketchPoint(x: 63, y: 132)]
        XCTAssertEqual(read(tear), .tear)
        let right = tear.map { SketchPoint(x: 200 - $0.x, y: $0.y) }
        XCTAssertEqual(read(right), .tear, "under either eye")
        XCTAssertNil(read(Array(tear.reversed())), "drawn upward it isn't a tear")
    }

    func testOtherStrokesMeanNothing() {
        XCTAssertNil(read([SketchPoint(x: 100, y: 100), SketchPoint(x: 102, y: 101)]), "a tap")
        XCTAssertNil(read([SketchPoint(x: 100, y: 100)]))
        XCTAssertNil(read([]))
        let diagonal = stride(from: 0.0, through: 1, by: 0.1).map { t in
            SketchPoint(x: 60 + 80 * t, y: 40 + 130 * t)
        }
        XCTAssertNil(read(diagonal), "a slash across the face")
    }
}
