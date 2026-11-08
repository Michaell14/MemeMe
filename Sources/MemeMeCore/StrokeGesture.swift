import Foundation

/// What a pen stroke drawn on the face editor means.
public enum StrokeGesture: Equatable, Sendable {
    /// A loop around a part: it counts the most.
    case circle(FaceRegion)
    /// A scribble over a part, or a line through it: it's ignored.
    case scribble(FaceRegion)
    /// A line running down from under an eye: the face is crying.
    case tear

    /// Strokes shorter than this are taps, not drawings.
    static let minimumLength: Double = 14

    /// Reads a stroke drawn on `sketch` (face space, in the order drawn); nil when it is none of the three.
    ///
    /// - circle: the ends meet (gap < 0.4 × the stroke's diagonal), the stroke is long for its size (> 1.6 × the
    ///   diagonal) and it turns back fewer than 4 times (left and right, or up and down);
    /// - scribble: it turns back 3 times or more, or it is a flat line (2.5 × wider than tall) through a part;
    /// - tear: taller than wide, drawn downward, starting by an eye.
    ///
    /// The part is the one whose ring's center is nearest the stroke's center (vertical distance counting 1.6 ×).
    public static func read(_ points: [SketchPoint], on sketch: FaceSketch,
                            weights: [FaceRegion: Double]) -> StrokeGesture? {
        guard points.count >= 2 else { return nil }
        var length = 0.0
        for index in 1..<points.count {
            length += points[index].distance(to: points[index - 1])
        }
        guard length >= minimumLength, let box = SketchRect.bounding(points) else { return nil }
        let diagonal = max(1, (box.width * box.width + box.height * box.height).squareRoot())
        let first = points[0]
        let last = points[points.count - 1]
        let gap = first.distance(to: last)

        var nearest = FaceRegion.mouth
        var nearestDistance = Double.infinity
        for region in FaceRegion.allCases {
            let center = sketch.ring(region, weight: weights[region] ?? 1).center
            let dx = center.x - box.midX
            let dy = (center.y - box.midY) * 1.6
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance < nearestDistance {
                nearestDistance = distance
                nearest = region
            }
        }

        let turns = max(turnsBack(points, along: \.x), turnsBack(points, along: \.y))
        if gap < diagonal * 0.4 && length > diagonal * 1.6 && turns < 4 {
            return .circle(nearest)
        }
        if turns >= 3 {
            return .scribble(nearest)
        }
        if box.height > box.width * 1.3, last.y > first.y, isUnderAnEye(first, box: box, sketch: sketch) {
            return .tear
        }
        if box.width > box.height * 2.5, nearestDistance < 34 {
            return .scribble(nearest)
        }
        return nil
    }

    /// How many times the stroke turns back along one axis (left and right, or up and down), ignoring wobbles under 4
    /// points.
    static func turnsBack(_ points: [SketchPoint], along axis: KeyPath<SketchPoint, Double>) -> Int {
        guard points.count >= 2 else { return 0 }
        var turns = 0
        var lastDirection = 0.0
        var travelled = 0.0
        for index in 1..<points.count {
            travelled += points[index][keyPath: axis] - points[index - 1][keyPath: axis]
            guard abs(travelled) >= 4 else { continue }
            let direction: Double = travelled > 0 ? 1 : -1
            if lastDirection != 0 && direction != lastDirection {
                turns += 1
            }
            lastDirection = direction
            travelled = 0
        }
        return turns
    }

    /// A tear starts level with an eye or just under it, and runs near the eye's column.
    static func isUnderAnEye(_ start: SketchPoint, box: SketchRect, sketch: FaceSketch) -> Bool {
        let top = FaceSketch.eyeY - sketch.eyeRadiusY - 4
        let bottom = FaceSketch.eyeY + 36
        guard start.y >= top, start.y <= bottom else { return false }
        return FaceSide.allCases.contains { abs(box.midX - sketch.eyeCenter($0).x) < 28 }
    }
}
