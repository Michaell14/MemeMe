import Foundation

/// A point in the face editor's drawing space: 200 × 200, origin top-left, y down.
public struct SketchPoint: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = SketchPoint(x: 0, y: 0)

    public func distance(to other: SketchPoint) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// A rectangle in sketch space.
public struct SketchRect: Hashable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = min(minX, maxX)
        self.minY = min(minY, maxY)
        self.maxX = max(minX, maxX)
        self.maxY = max(minY, maxY)
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var midX: Double { (minX + maxX) / 2 }
    public var midY: Double { (minY + maxY) / 2 }
    public var center: SketchPoint { SketchPoint(x: midX, y: midY) }
    public var area: Double { width * height }

    /// Grown by `amount` on every side (shrunk when negative).
    public func outset(by amount: Double) -> SketchRect {
        SketchRect(minX: minX - amount, minY: minY - amount, maxX: maxX + amount, maxY: maxY + amount)
    }

    public func contains(_ point: SketchPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    /// The smallest rectangle holding all of `points` (nil for none).
    static func bounding(_ points: [SketchPoint]) -> SketchRect? {
        guard let first = points.first else { return nil }
        var rect = SketchRect(minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)
        for point in points.dropFirst() {
            rect.minX = min(rect.minX, point.x)
            rect.minY = min(rect.minY, point.y)
            rect.maxX = max(rect.maxX, point.x)
            rect.maxY = max(rect.maxY, point.y)
        }
        return rect
    }
}

public enum FaceSide: String, CaseIterable, Codable, Hashable, Sendable {
    case left, right
}

/// What a drag on the face editor takes hold of.
public enum FaceHandle: Hashable, Sendable {
    /// Up and down: browRaise (both brows move together).
    case brow(FaceSide)
    /// Up and down: eyeOpenness.
    case eyelid(FaceSide)
    /// Sideways: gazeSide.
    case pupil(FaceSide)
    /// Up and down: smile; out and in: mouthWidth.
    case mouthCorner(FaceSide)
    /// Up and down: mouthOpenness.
    case lowerLip
    /// Around the head: headTilt.
    case tilt
    /// Out and in: how much the region counts.
    case ring(FaceRegion)

    /// The region a handle belongs to (the tilt belongs to none).
    public var region: FaceRegion? {
        switch self {
        case .brow: return .brows
        case .eyelid, .pupil: return .eyes
        case .mouthCorner, .lowerLip: return .mouth
        case .tilt: return nil
        case let .ring(region): return region
        }
    }

    /// Every handle the editor shows.
    public static let all: [FaceHandle] = [
        .tilt,
        .brow(.left), .brow(.right),
        .eyelid(.left), .eyelid(.right),
        .pupil(.left), .pupil(.right),
        .mouthCorner(.left), .mouthCorner(.right), .lowerLip,
        .ring(.brows), .ring(.eyes), .ring(.mouth),
    ]
}

/// The face drawn from its seven numbers, the way the face editor shows it and the search reads it. All geometry is
/// in face space (200 × 200, before the head's tilt); `toFace` and `fromFace` convert to and from the tilted drawing.
/// Each number moves its feature by a fixed distance (the `…Travel` constants), and a drag moves the number back by
/// the same distance, so a dragged feature follows the pointer.
public struct FaceSketch: Equatable, Sendable {
    public static let size: Double = 200
    /// The head's center and radius.
    public static let center = SketchPoint(x: 100, y: 106)
    public static let headRadius: Double = 74
    public static let eyeY: Double = 98
    public static let eyeRadiusX: Double = 13
    public static let mouthY: Double = 142
    public static let tiltHandlePoint = SketchPoint(x: 100, y: 20)

    /// Points per unit of browRaise, eyeOpenness (half-height), gazeSide, smile (corner height), mouthWidth (half
    /// width) and mouthOpenness (the lower lip).
    public static let browTravel: Double = 28
    public static let lidTravel: Double = 14
    public static let gazeTravel: Double = 9
    public static let smileTravel: Double = 28
    public static let widthTravel: Double = 30
    public static let openTravel: Double = 27
    /// Degrees at headTilt 1.
    public static let maxTilt: Double = 45
    /// How far a ring grows for each step it counts more.
    public static let ringStep: Double = 2
    /// Rings are never thinner than this, so a closed eye or a flat brow keeps a ring you can see.
    public static let minimumRingHeight: Double = 20

    /// A quadratic curve (a brow).
    public struct Curve: Equatable, Sendable {
        public let start: SketchPoint
        public let control: SketchPoint
        public let end: SketchPoint

        public func point(at t: Double) -> SketchPoint {
            let u = 1 - t
            return SketchPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                               y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
        }

        func samples(_ count: Int = 9) -> [SketchPoint] {
            (0..<count).map { point(at: Double($0) / Double(count - 1)) }
        }
    }

    public let face: FaceFeatures
    /// +1 tilts clockwise, -1 counterclockwise: headTilt keeps no direction, the editor remembers the last one.
    public let tiltDirection: Double

    public let leftBrow: Curve
    public let rightBrow: Curve
    /// The eyes' half-height (both eyes).
    public let eyeRadiusY: Double
    public let pupilRadius: Double
    /// How far the pupils sit right of the eyes' centers.
    public let pupilOffset: Double
    /// The mouth: from the left corner over the upper lip to the right corner, back under the lower lip.
    public let mouthLeft: SketchPoint
    public let mouthRight: SketchPoint
    public let upperLipControl: SketchPoint
    public let lowerLipControl: SketchPoint

    public init(face: FaceFeatures, tiltDirection: Double = 1) {
        let face = face.clamped()
        self.face = face
        self.tiltDirection = tiltDirection < 0 ? -1 : 1

        let eyeRadiusY = 2 + FaceSketch.lidTravel * face.eyeOpenness
        self.eyeRadiusY = eyeRadiusY
        let lidTop = FaceSketch.eyeY - eyeRadiusY
        let browY = 78 - (face.browRaise - 0.45) * FaceSketch.browTravel
        let angry = FaceSketch.unit((0.45 - face.browRaise) / 0.45)
        let raised = FaceSketch.unit((face.browRaise - 0.45) / 0.55)
        // Lowered brows pull their inner ends down (angry); raised ones arch. Never into the eyes.
        let innerY = min(browY + angry * 10 - raised * 4, lidTop - 2)
        let outerY = min(browY - angry * 3 + raised, lidTop - 3)
        let controlY = (innerY + outerY) / 2 - 4 - raised * 5
        leftBrow = Curve(start: SketchPoint(x: 52, y: outerY), control: SketchPoint(x: 70, y: controlY),
                         end: SketchPoint(x: 88, y: innerY))
        rightBrow = Curve(start: SketchPoint(x: 148, y: outerY), control: SketchPoint(x: 130, y: controlY),
                          end: SketchPoint(x: 112, y: innerY))

        pupilRadius = max(0, min(4.5, eyeRadiusY - 1.5))
        pupilOffset = min(8, face.gazeSide * FaceSketch.gazeTravel)

        let halfWidth = 12 + FaceSketch.widthTravel * face.mouthWidth
        let cornerY = FaceSketch.mouthY - (face.smile - 0.5) * FaceSketch.smileTravel
        let opening = face.mouthOpenness * (FaceSketch.openTravel / 0.75)
        // The curves' middles sit a quarter of the opening above the mouth's line and three quarters below it.
        let upperY = 2 * (FaceSketch.mouthY - opening * 0.25) - cornerY
        let lowerY = 2 * (FaceSketch.mouthY + opening * 0.75) - cornerY
        mouthLeft = SketchPoint(x: 100 - halfWidth, y: cornerY)
        mouthRight = SketchPoint(x: 100 + halfWidth, y: cornerY)
        upperLipControl = SketchPoint(x: 100, y: upperY)
        lowerLipControl = SketchPoint(x: 100, y: lowerY)
    }

    /// The head's tilt in degrees, clockwise.
    public var tiltDegrees: Double { face.headTilt * FaceSketch.maxTilt * tiltDirection }

    public func brow(_ side: FaceSide) -> Curve { side == .left ? leftBrow : rightBrow }

    public func eyeCenter(_ side: FaceSide) -> SketchPoint {
        SketchPoint(x: side == .left ? 72 : 128, y: FaceSketch.eyeY)
    }

    public func pupilCenter(_ side: FaceSide) -> SketchPoint {
        let eye = eyeCenter(side)
        return SketchPoint(x: eye.x + pupilOffset, y: eye.y)
    }

    /// The middle of the lower lip.
    public var lowerLipPoint: SketchPoint {
        SketchPoint(x: 100, y: (mouthLeft.y + lowerLipControl.y) / 2)
    }

    /// The middle of the upper lip.
    public var upperLipPoint: SketchPoint {
        SketchPoint(x: 100, y: (mouthLeft.y + upperLipControl.y) / 2)
    }

    // MARK: Regions and rings

    /// A part's own bounds, without its ring's padding.
    public func bounds(of region: FaceRegion) -> SketchRect {
        switch region {
        case .brows:
            return SketchRect.bounding(leftBrow.samples() + rightBrow.samples())
                ?? SketchRect(minX: 52, minY: 70, maxX: 148, maxY: 80)
        case .eyes:
            return SketchRect(minX: 72 - FaceSketch.eyeRadiusX, minY: FaceSketch.eyeY - eyeRadiusY,
                              maxX: 128 + FaceSketch.eyeRadiusX, maxY: FaceSketch.eyeY + eyeRadiusY)
        case .mouth:
            let upper = Curve(start: mouthLeft, control: upperLipControl, end: mouthRight)
            let lower = Curve(start: mouthLeft, control: lowerLipControl, end: mouthRight)
            return SketchRect.bounding(upper.samples() + lower.samples())
                ?? SketchRect(minX: 80, minY: 138, maxX: 120, maxY: 146)
        }
    }

    /// A part's ring: its bounds grown by `ringStep` for each step it counts (0…5), never thinner than
    /// `minimumRingHeight`.
    public func ring(_ region: FaceRegion, weight: Double) -> SketchRect {
        let padding = 2 + FaceSketch.ringStep * min(5, max(0, weight))
        var rect = bounds(of: region).outset(by: padding)
        if rect.height < FaceSketch.minimumRingHeight {
            let grow = (FaceSketch.minimumRingHeight - rect.height) / 2
            rect = SketchRect(minX: rect.minX, minY: rect.minY - grow, maxX: rect.maxX, maxY: rect.maxY + grow)
        }
        return rect
    }

    /// The region whose ring holds `point` (face space); the smallest ring wins where they overlap.
    public func region(at point: SketchPoint, weights: [FaceRegion: Double]) -> FaceRegion? {
        var best: (region: FaceRegion, area: Double)?
        for region in FaceRegion.allCases {
            let ring = self.ring(region, weight: weights[region] ?? 1)
            guard ring.contains(point) else { continue }
            if let current = best, current.area <= ring.area { continue }
            best = (region: region, area: ring.area)
        }
        return best?.region
    }

    // MARK: Handles

    /// Where a handle sits (face space).
    public func position(of handle: FaceHandle, weights: [FaceRegion: Double]) -> SketchPoint {
        switch handle {
        case let .brow(side):
            return brow(side).point(at: 0.5)
        case let .eyelid(side):
            let eye = eyeCenter(side)
            return SketchPoint(x: eye.x, y: eye.y - eyeRadiusY)
        case let .pupil(side):
            return pupilCenter(side)
        case let .mouthCorner(side):
            return side == .left ? mouthLeft : mouthRight
        case .lowerLip:
            return lowerLipPoint
        case .tilt:
            return FaceSketch.tiltHandlePoint
        case let .ring(region):
            let ring = self.ring(region, weight: weights[region] ?? 1)
            return SketchPoint(x: ring.maxX, y: ring.midY)
        }
    }

    /// How close a pointer must come to take hold of a handle.
    static func reach(of handle: FaceHandle) -> Double {
        switch handle {
        case .ring, .tilt: return 10
        case .lowerLip, .mouthCorner: return 9
        case .eyelid, .brow: return 8
        case .pupil: return 6
        }
    }

    /// The handle under `point` (face space): the nearest one within its reach. A brow can be taken anywhere along it.
    public func handle(at point: SketchPoint, weights: [FaceRegion: Double]) -> FaceHandle? {
        var best: (handle: FaceHandle, distance: Double)?
        for handle in FaceHandle.all {
            let distance: Double
            if case let .brow(side) = handle {
                distance = brow(side).samples().map { $0.distance(to: point) }.min() ?? .infinity
            } else {
                distance = position(of: handle, weights: weights).distance(to: point)
            }
            guard distance <= FaceSketch.reach(of: handle) else { continue }
            if let current = best, current.distance <= distance { continue }
            best = (handle: handle, distance: distance)
        }
        return best?.handle
    }

    // MARK: Tilt

    /// A point of the tilted drawing in face space.
    public func toFace(_ point: SketchPoint) -> SketchPoint {
        FaceSketch.rotate(point, by: -tiltDegrees)
    }

    /// A point of face space in the tilted drawing.
    public func fromFace(_ point: SketchPoint) -> SketchPoint {
        FaceSketch.rotate(point, by: tiltDegrees)
    }

    /// A movement in the tilted drawing, in face space.
    public func toFace(movement: SketchPoint) -> SketchPoint {
        FaceSketch.turn(movement, by: -tiltDegrees)
    }

    static func rotate(_ point: SketchPoint, by degrees: Double) -> SketchPoint {
        let offset = turn(SketchPoint(x: point.x - center.x, y: point.y - center.y), by: degrees)
        return SketchPoint(x: center.x + offset.x, y: center.y + offset.y)
    }

    /// A vector turned clockwise on screen (y down) by `degrees`.
    static func turn(_ vector: SketchPoint, by degrees: Double) -> SketchPoint {
        let angle = degrees * Double.pi / 180
        let cosine = cos(angle)
        let sine = sin(angle)
        return SketchPoint(x: vector.x * cosine - vector.y * sine, y: vector.x * sine + vector.y * cosine)
    }

    /// The tilt the head takes when its top handle is dragged to `point` (drawing space): the angle around the
    /// head's center from straight up, as headTilt (0…1) and a direction.
    public static func tilt(towards point: SketchPoint) -> (headTilt: Double, direction: Double) {
        let degrees = atan2(point.x - center.x, center.y - point.y) * 180 / Double.pi
        return (headTilt: unit(abs(degrees) / maxTilt), direction: degrees < 0 ? -1 : 1)
    }

    static func unit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, min(1, value))
    }
}
