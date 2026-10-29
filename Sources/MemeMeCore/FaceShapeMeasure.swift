// CGPoint, as Vision gives landmarks: from CoreGraphics on the Mac, from Foundation elsewhere (the core builds on Linux).
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Measures a face's `FaceShape` from its landmark contours (and, for the tongue, the picture's colors). Pure geometry,
/// so it runs and is tested without Vision.
///
/// The face is first turned level and scaled: a point p becomes q = R(−θ)(p − m) / d, where m is the midpoint of the
/// eyes' centers (each the mean of its pupil's points, else of its contour's), d the distance between them and θ the
/// angle of the line through them. Face-box-normalized coordinates count as square units (Vision's face boxes are
/// about square in pixels). Leveled, the eyes' centers sit at (±0.5, 0), y points up and the line down the face is
/// x = 0, so a tilted or far face measures like an upright, near one.
public enum FaceShapeMeasure {
    /// One face's landmark contours, in its face box's normalized coordinates (0...1, origin bottom-left) as Vision's
    /// `normalizedPoints`; a contour Vision didn't find is empty. "Left" and "right" are Vision's (the person's own).
    public struct Landmarks: Equatable, Sendable {
        public var leftEye: [CGPoint]
        public var rightEye: [CGPoint]
        public var leftBrow: [CGPoint]
        public var rightBrow: [CGPoint]
        public var outerLips: [CGPoint]
        public var innerLips: [CGPoint]
        public var leftPupil: [CGPoint]
        public var rightPupil: [CGPoint]

        public init(leftEye: [CGPoint] = [], rightEye: [CGPoint] = [], leftBrow: [CGPoint] = [], rightBrow: [CGPoint] = [],
                    outerLips: [CGPoint] = [], innerLips: [CGPoint] = [], leftPupil: [CGPoint] = [],
                    rightPupil: [CGPoint] = []) {
            self.leftEye = leftEye
            self.rightEye = rightEye
            self.leftBrow = leftBrow
            self.rightBrow = rightBrow
            self.outerLips = outerLips
            self.innerLips = innerLips
            self.leftPupil = leftPupil
            self.rightPupil = rightPupil
        }

        /// Every contour with `transform` applied to each point.
        func map(_ transform: (CGPoint) -> CGPoint) -> Landmarks {
            Landmarks(leftEye: leftEye.map(transform), rightEye: rightEye.map(transform),
                      leftBrow: leftBrow.map(transform), rightBrow: rightBrow.map(transform),
                      outerLips: outerLips.map(transform), innerLips: innerLips.map(transform),
                      leftPupil: leftPupil.map(transform), rightPupil: rightPupil.map(transform))
        }
    }

    /// The color of the picture at one point.
    public struct Sample: Equatable, Sendable {
        /// Brightness: BT.601 luma, 0...255.
        public var luma: Double
        /// How red: BT.601 Cr, 0...255 (128 is gray).
        public var redness: Double

        public init(luma: Double, redness: Double) {
            self.luma = luma
            self.redness = redness
        }
    }

    // MARK: Measuring

    /// The face's shape; nil without both eyes (each needs its pupil or its contour). `color` gives the picture's color
    /// at a face-box-normalized point (nil outside the picture); without it there is no `tongue`. Fields (leveled,
    /// lengths in eye distances; a field is nil without the contours it needs):
    /// - each eye's opening: its contour's area (shoelace) / its width²
    /// - each brow's gap: the brow's mean height minus its eye contour's
    /// - lipWidth, lipHeight: the outer lips' extents; lipOpening: the inner lips' height
    /// - lowerLip: inner-lip bottom minus outer-lip bottom (the lower lip's thickness)
    /// - cornerTilt: the height of the outer lips' left-most point minus the right-most one's
    /// - mouthShift: the middle of the outer lips' width (the face's midline is x = 0)
    /// - gazeUp: over the eyes with a pupil, the mean of the pupil's height over the line through the eye's corners (its
    ///   contour's left-most and right-most points) / the eye's width; the lids don't move the corners, so half-shut or
    ///   frowning eyes don't read as looking up
    /// - tongue: see `tongueShare`
    public static func shape(of landmarks: Landmarks, color: ((CGPoint) -> FaceShapeMeasure.Sample?)?) -> FaceShape? {
        guard let frame = Frame(landmarks) else { return nil }
        let leftEye = landmarks.leftEye.map(frame.level)
        let rightEye = landmarks.rightEye.map(frame.level)
        let outer = landmarks.outerLips.map(frame.level)
        let inner = landmarks.innerLips.map(frame.level)

        var shape = FaceShape()
        shape.leftEyeOpen = openness(leftEye)
        shape.rightEyeOpen = openness(rightEye)
        shape.leftBrowGap = browGap(landmarks.leftBrow.map(frame.level), eye: leftEye)
        shape.rightBrowGap = browGap(landmarks.rightBrow.map(frame.level), eye: rightEye)

        let outerBox = Box(outer)
        let innerBox = Box(inner)
        if let outerBox {
            shape.lipWidth = outerBox.width
            shape.lipHeight = outerBox.height
            shape.mouthShift = outerBox.midX
            if let left = outer.min(by: { $0.x < $1.x }), let right = outer.max(by: { $0.x < $1.x }) {
                shape.cornerTilt = left.y - right.y
            }
        }
        if let innerBox {
            shape.lipOpening = innerBox.height
            if let outerBox {
                shape.lowerLip = innerBox.minY - outerBox.minY
            }
        }

        var gaze: [Double] = []
        for (pupil, eye) in [(landmarks.leftPupil, leftEye), (landmarks.rightPupil, rightEye)] {
            let leveledPupil = pupil.map(frame.level)
            guard let pupilX = mean(leveledPupil.map(\.x)), let pupilY = mean(leveledPupil.map(\.y)),
                  let inner = eye.min(by: { $0.x < $1.x }), let outer = eye.max(by: { $0.x < $1.x }),
                  outer.x - inner.x > 1e-9 else { continue }
            let width = outer.x - inner.x
            let cornerLineY = inner.y + (outer.y - inner.y) * (pupilX - inner.x) / width
            gaze.append((pupilY - cornerLineY) / width)
        }
        shape.gazeUp = mean(gaze)

        if let color {
            shape.tongue = tongueShare(outer: outer, inner: inner, frame: frame, color: color)
        }
        return shape
    }

    /// `landmarks` turned about the eyes' midpoint so the line through the eyes is level, in the same units (not
    /// scaled): what the seven `FaceFeatures` are measured on. An upright face, or one without both eyes, comes back
    /// as it is.
    public static func leveled(_ landmarks: Landmarks) -> Landmarks {
        guard let frame = Frame(landmarks), frame.sine != 0 else { return landmarks }
        let origin = frame.origin
        return landmarks.map { point in
            let x = Double(point.x) - origin.x
            let y = Double(point.y) - origin.y
            return CGPoint(x: origin.x + x * frame.cosine + y * frame.sine,
                           y: origin.y - x * frame.sine + y * frame.cosine)
        }
    }

    // MARK: Tongue

    /// Skin: two 0.2 × 0.2 patches on the cheeks, centered at (±0.55, −0.75).
    private static let cheekCenters: [Point] = [Point(x: -0.55, y: -0.75), Point(x: 0.55, y: -0.75)]
    private static let cheekSize = 0.2
    /// The band under the lower lip: this far below the outer lips' bottom, this deep, and ± this share of the lips'
    /// width around their middle.
    private static let bandGap = 0.02
    private static let bandDepth = 0.45
    private static let bandHalfWidth = 0.3
    /// A sample is tongue-colored when it is redder than the skin by at least this share of what the lips are, and at
    /// least this share of the skin's brightness (a dark open mouth isn't).
    private static let tongueRedness = 0.6
    private static let tongueBrightness = 0.45
    /// Lips at most this much redder than the skin (gray or odd light) can't tell a tongue apart.
    private static let minimumLipContrast = 5.0

    /// The share (0...1) of tongue-colored samples on a 12 × 8 grid over the band under the lower lip: skin is the
    /// median redness and brightness of 6 × 6 samples in each cheek patch, lips the median redness of the samples of
    /// a 16 × 8 grid over the outer lips that lie between the outer and inner contours, C = lips − skin; a sample is
    /// tongue-colored when its redness ≥ skin + 0.6 × C and its brightness ≥ 0.45 × the skin's. nil when C < 5, or
    /// without lips, skin or band samples.
    private static func tongueShare(outer: [Point], inner: [Point], frame: Frame,
                                    color: (CGPoint) -> FaceShapeMeasure.Sample?) -> Double? {
        guard outer.count >= 3, let lips = Box(outer), lips.width > 1e-9 else { return nil }

        var skinRedness: [Double] = []
        var skinLuma: [Double] = []
        let half = cheekSize / 2
        for center in cheekCenters {
            for point in grid(minX: center.x - half, maxX: center.x + half, minY: center.y - half, maxY: center.y + half,
                              columns: 6, rows: 6) {
                guard let sample = color(frame.boxPoint(point)) else { continue }
                skinRedness.append(sample.redness)
                skinLuma.append(sample.luma)
            }
        }
        guard let skin = median(skinRedness), let skinBrightness = median(skinLuma) else { return nil }

        var lipRedness: [Double] = []
        let lipGrid = grid(minX: lips.minX, maxX: lips.maxX, minY: lips.minY, maxY: lips.maxY, columns: 16, rows: 8)
        for point in lipGrid where contains(outer, point) && !contains(inner, point) {
            if let sample = color(frame.boxPoint(point)) {
                lipRedness.append(sample.redness)
            }
        }
        guard let lip = median(lipRedness) else { return nil }
        let contrast = lip - skin
        guard contrast >= minimumLipContrast else { return nil }

        let halfWidth = bandHalfWidth * lips.width
        let top = lips.minY - bandGap
        var tongueCount = 0
        var total = 0
        for point in grid(minX: lips.midX - halfWidth, maxX: lips.midX + halfWidth, minY: top - bandDepth, maxY: top,
                          columns: 12, rows: 8) {
            guard let sample = color(frame.boxPoint(point)) else { continue }
            total += 1
            if sample.redness >= skin + tongueRedness * contrast && sample.luma >= tongueBrightness * skinBrightness {
                tongueCount += 1
            }
        }
        guard total > 0 else { return nil }
        return Double(tongueCount) / Double(total)
    }

    // MARK: Helpers

    /// A point in the leveled frame.
    private struct Point {
        var x: Double
        var y: Double
    }

    /// The face's own frame: the eyes' midpoint, the distance between the eyes and the eye line's direction.
    private struct Frame {
        let origin: Point
        let scale: Double
        let cosine: Double
        let sine: Double

        /// nil without both eyes, or with both at one point.
        init?(_ landmarks: Landmarks) {
            guard let left = FaceShapeMeasure.center(pupil: landmarks.leftPupil, eye: landmarks.leftEye),
                  let right = FaceShapeMeasure.center(pupil: landmarks.rightPupil, eye: landmarks.rightEye) else {
                return nil
            }
            // Vision's left eye is on the picture's right: the line runs from the right eye to the left one, and
            // points right whichever way round the eyes were named.
            var dx = left.x - right.x
            var dy = left.y - right.y
            if dx < 0 {
                dx = -dx
                dy = -dy
            }
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance > 1e-9, distance.isFinite else { return nil }
            origin = Point(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
            scale = distance
            cosine = dx / distance
            sine = dy / distance
        }

        /// Face-box-normalized → leveled.
        func level(_ point: CGPoint) -> Point {
            let x = Double(point.x) - origin.x
            let y = Double(point.y) - origin.y
            return Point(x: (x * cosine + y * sine) / scale, y: (y * cosine - x * sine) / scale)
        }

        /// Leveled → face-box-normalized.
        func boxPoint(_ point: Point) -> CGPoint {
            CGPoint(x: origin.x + scale * (point.x * cosine - point.y * sine),
                    y: origin.y + scale * (point.x * sine + point.y * cosine))
        }
    }

    /// The extents of some points; nil for fewer than two.
    private struct Box {
        let minX: Double
        let maxX: Double
        let minY: Double
        let maxY: Double

        init?(_ points: [Point]) {
            guard points.count >= 2, let first = points.first else { return nil }
            var minX = first.x
            var maxX = first.x
            var minY = first.y
            var maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x)
                maxX = max(maxX, point.x)
                minY = min(minY, point.y)
                maxY = max(maxY, point.y)
            }
            self.minX = minX
            self.maxX = maxX
            self.minY = minY
            self.maxY = maxY
        }

        var width: Double { maxX - minX }
        var height: Double { maxY - minY }
        var midX: Double { (minX + maxX) / 2 }
    }

    /// An eye's center (face-box-normalized): its pupil's mean point, else its contour's; nil without either.
    private static func center(pupil: [CGPoint], eye: [CGPoint]) -> Point? {
        let points = pupil.isEmpty ? eye : pupil
        guard let x = mean(points.map { Double($0.x) }), let y = mean(points.map { Double($0.y) }),
              x.isFinite, y.isFinite else { return nil }
        return Point(x: x, y: y)
    }

    /// An eye contour's area (shoelace) / its width²; nil for fewer than three points or no width.
    private static func openness(_ contour: [Point]) -> Double? {
        guard contour.count >= 3, let box = Box(contour), box.width > 1e-9 else { return nil }
        var twiceArea = 0.0
        for index in contour.indices {
            let point = contour[index]
            let next = contour[(index + 1) % contour.count]
            twiceArea += point.x * next.y - next.x * point.y
        }
        return abs(twiceArea) / 2 / (box.width * box.width)
    }

    /// The brow's mean height over its eye contour's (over the eye's center, at 0, without a contour); nil without
    /// the brow.
    private static func browGap(_ brow: [Point], eye: [Point]) -> Double? {
        guard let browY = mean(brow.map(\.y)) else { return nil }
        return browY - (mean(eye.map(\.y)) ?? 0)
    }

    /// The centers of a `columns` × `rows` grid of cells over the rectangle, row by row from the bottom.
    private static func grid(minX: Double, maxX: Double, minY: Double, maxY: Double, columns: Int, rows: Int) -> [Point] {
        guard columns > 0, rows > 0 else { return [] }
        var points: [Point] = []
        points.reserveCapacity(columns * rows)
        for row in 0..<rows {
            let y = minY + (Double(row) + 0.5) / Double(rows) * (maxY - minY)
            for column in 0..<columns {
                points.append(Point(x: minX + (Double(column) + 0.5) / Double(columns) * (maxX - minX), y: y))
            }
        }
        return points
    }

    /// Even-odd test: whether `point` is inside the closed `polygon` (false for fewer than three points).
    private static func contains(_ polygon: [Point], _ point: Point) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            if (current.y > point.y) != (previous.y > point.y) {
                let crossing = current.x + (point.y - current.y) / (previous.y - current.y) * (previous.x - current.x)
                if point.x < crossing {
                    inside.toggle()
                }
            }
            previous = current
        }
        return inside
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// The middle value (the mean of the two middle ones for an even count); nil for none.
    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
