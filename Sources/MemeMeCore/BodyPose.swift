import Foundation

/// A body joint MemeMe reads from Vision's body pose (hips and legs are ignored).
public enum BodyJoint: String, CaseIterable, Sendable {
    case nose, leftEye, rightEye, leftEar, rightEar, neck
    case leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
}

/// A hand joint from Vision's hand pose.
public enum HandJoint: String, CaseIterable, Sendable {
    case wrist
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip
}

/// A joint as Vision reports it: normalized image coordinates (0...1, origin bottom-left) and a confidence.
public struct JointReading: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var confidence: Double

    public init(x: Double, y: Double, confidence: Double) {
        self.x = x
        self.y = y
        self.confidence = confidence
    }
}

/// A point in aspect-corrected image units: y is Vision's normalized y (0 bottom … 1 top) and x is Vision's
/// normalized x times width / height, so a distance means the same along both axes.
public struct PosePoint: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    func distance(to other: PosePoint) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }

    static func mean(_ points: [PosePoint]) -> PosePoint? {
        guard !points.isEmpty else { return nil }
        let count = Double(points.count)
        return PosePoint(x: points.reduce(0) { $0 + $1.x } / count, y: points.reduce(0) { $0 + $1.y } / count)
    }
}

/// Joints below this confidence are treated as not seen.
private let minimumJointConfidence = 0.3

/// Converts Vision readings to aspect-corrected points, dropping joints seen with too little confidence.
private func correctedPoints<Joint: Hashable>(_ readings: [Joint: JointReading], imageWidth: Double, imageHeight: Double) -> [Joint: PosePoint] {
    let aspect = imageWidth > 0 && imageHeight > 0 ? imageWidth / imageHeight : 1
    var points: [Joint: PosePoint] = [:]
    for (joint, reading) in readings where reading.confidence >= minimumJointConfidence && reading.x.isFinite && reading.y.isFinite {
        points[joint] = PosePoint(x: reading.x * aspect, y: reading.y)
    }
    return points
}

/// The body joints seen in one image.
public struct BodyJoints: Hashable, Sendable {
    public private(set) var points: [BodyJoint: PosePoint]
    /// The image's shorter side in these units: min(width / height, 1).
    public let shortSide: Double
    /// Mean confidence of the two shoulders (a missing one counts 0).
    public let shoulderConfidence: Double

    public init(points: [BodyJoint: PosePoint], shortSide: Double = 1, shoulderConfidence: Double = 1) {
        self.points = points
        self.shortSide = shortSide
        self.shoulderConfidence = shoulderConfidence
    }

    /// Vision readings of one body; joints under 0.3 confidence count as not seen.
    public init(readings: [BodyJoint: JointReading], imageWidth: Double, imageHeight: Double) {
        let aspect = imageWidth > 0 && imageHeight > 0 ? imageWidth / imageHeight : 1
        let left = readings[.leftShoulder].map { $0.confidence >= minimumJointConfidence ? $0.confidence : 0 } ?? 0
        let right = readings[.rightShoulder].map { $0.confidence >= minimumJointConfidence ? $0.confidence : 0 } ?? 0
        self.init(points: correctedPoints(readings, imageWidth: imageWidth, imageHeight: imageHeight),
                  shortSide: min(aspect, 1),
                  shoulderConfidence: VectorMath.clampUnit((left + right) / 2))
    }

    public subscript(joint: BodyJoint) -> PosePoint? {
        points[joint]
    }

    /// The head joints that were seen (nose, eyes, ears).
    public var headPoints: [PosePoint] {
        [BodyJoint.nose, .leftEye, .rightEye, .leftEar, .rightEar].compactMap { points[$0] }
    }
}

/// A rectangle in aspect-corrected image units (see `PosePoint`), e.g. a face's bounding box.
public struct PoseBox: Hashable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    /// From a Vision-normalized rectangle (origin bottom-left) of an image that size.
    public init(normalizedX x: Double, y: Double, width: Double, height: Double, imageWidth: Double, imageHeight: Double) {
        let aspect = imageWidth > 0 && imageHeight > 0 ? imageWidth / imageHeight : 1
        self.init(minX: x * aspect, minY: y, maxX: (x + width) * aspect, maxY: y + height)
    }

    /// Grown by `fraction` of its size on every side.
    public func grown(by fraction: Double) -> PoseBox {
        let dx = (maxX - minX) * fraction
        let dy = (maxY - minY) * fraction
        return PoseBox(minX: minX - dx, minY: minY - dy, maxX: maxX + dx, maxY: maxY + dy)
    }

    public func contains(_ point: PosePoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
}

extension BodyJoints {
    /// The body whose head (nose, eyes or ears) lies in the face's box grown by 30 %, so the pose read is the face's
    /// own; else, or without a face, the one whose shoulders are surest.
    public static func primary(of bodies: [BodyJoints], faceBox: PoseBox?) -> BodyJoints? {
        if let box = faceBox?.grown(by: 0.3) {
            let owners = bodies.filter { body in body.headPoints.contains { box.contains($0) } }
            if let owner = owners.max(by: { $0.shoulderConfidence < $1.shoulderConfidence }) {
                return owner
            }
        }
        return bodies.max(by: { $0.shoulderConfidence < $1.shoulderConfidence })
    }

    /// The hands that are this body's: each hand's wrist within 0.6 shoulder widths of one of the body's wrists.
    /// Without a wrist seen to compare with, every hand.
    public func ownHands(_ hands: [HandJoints]) -> [HandJoints] {
        let wrists = [self[.leftWrist], self[.rightWrist]].compactMap { $0 }
        guard !wrists.isEmpty else { return hands }
        var reach = 0.15
        if let left = self[.leftShoulder], let right = self[.rightShoulder] {
            reach = max(0.6 * left.distance(to: right), 0.02)
        }
        return hands.filter { hand in
            guard let handWrist = hand[.wrist] else { return false }
            return wrists.contains { $0.distance(to: handWrist) <= reach }
        }
    }
}

/// The hand joints seen in one image.
public struct HandJoints: Hashable, Sendable {
    public private(set) var points: [HandJoint: PosePoint]

    public init(points: [HandJoint: PosePoint]) {
        self.points = points
    }

    /// Vision readings of one hand; joints under 0.3 confidence count as not seen.
    public init(readings: [HandJoint: JointReading], imageWidth: Double, imageHeight: Double) {
        self.init(points: correctedPoints(readings, imageWidth: imageWidth, imageHeight: imageHeight))
    }

    public subscript(joint: HandJoint) -> PosePoint? {
        points[joint]
    }
}

/// How much a hand looks like each sign, all 0...1.
public struct HandShape: Codable, Hashable, Sendable {
    public var thumbsUp: Double
    public var point: Double
    public var openPalm: Double
    public var fist: Double
    public var peace: Double

    public init(thumbsUp: Double = 0, point: Double = 0, openPalm: Double = 0, fist: Double = 0, peace: Double = 0) {
        self.thumbsUp = thumbsUp
        self.point = point
        self.openPalm = openPalm
        self.fist = fist
        self.peace = peace
    }

    /// nil when the wrist or too few fingers were seen. With `faceBox`, a finger or thumb lying on the face (a finger up
    /// the cheek while thinking, "shh", a thumb along the jaw) is no pointing or thumbs-up sign.
    public init?(_ hand: HandJoints, faceBox: PoseBox? = nil) {
        guard let wrist = hand[.wrist] else { return nil }
        // A finger is straight when its tip is clearly farther from the wrist than its middle joint, curled when closer.
        func ratio(_ pip: HandJoint, _ tip: HandJoint) -> Double? {
            guard let middle = hand[pip], let end = hand[tip] else { return nil }
            let toMiddle = wrist.distance(to: middle)
            guard toMiddle > 1e-6 else { return nil }
            return wrist.distance(to: end) / toMiddle
        }
        let index = ratio(.indexPIP, .indexTip)
        let middle = ratio(.middlePIP, .middleTip)
        let ring = ratio(.ringPIP, .ringTip)
        let little = ratio(.littlePIP, .littleTip)
        let fingers = [index, middle, ring, little]
        guard fingers.compactMap({ $0 }).count >= 2 else { return nil }

        func extended(_ value: Double?) -> Double? { value.map { VectorMath.clampUnit(($0 - 0.95) / 0.25) } }
        func curled(_ value: Double?) -> Double? { value.map { VectorMath.clampUnit((1.05 - $0) / 0.25) } }
        /// The weakest of the parts, 0 when fewer than `known` of them were seen.
        func all(_ parts: [Double?], known: Int) -> Double {
            let seen = parts.compactMap { $0 }
            guard seen.count >= known, let weakest = seen.min() else { return 0 }
            return weakest
        }

        let othersCurled = all([curled(index), curled(middle), curled(ring), curled(little)], known: 3)
        var thumbsUp = 0.0
        if let tip = hand[.thumbTip], let base = hand[.thumbIP] ?? hand[.thumbMP], othersCurled > 0 {
            // The thumb points up (within about 35°) and sticks out above the rest of the hand.
            let dx = tip.x - base.x
            let dy = tip.y - base.y
            let length = (dx * dx + dy * dy).squareRoot()
            let upright = length > 1e-6 ? VectorMath.clampUnit((dy / length - 0.57) / 0.25) : 0
            let palm = hand[.middleMCP].map { wrist.distance(to: $0) } ?? 0
            let others: [HandJoint] = [.indexTip, .indexPIP, .middleTip, .middlePIP, .ringTip, .ringPIP, .littleTip, .littlePIP]
            let highest = others.compactMap { hand[$0]?.y }.max()
            var above = 0.0
            if palm > 1e-6, let highest {
                above = VectorMath.clampUnit(((tip.y - highest) / palm - 0.1) / 0.25)
            }
            thumbsUp = min(othersCurled, upright, above)
        }
        var point = index == nil ? 0 : all([extended(index), curled(middle), curled(ring), curled(little)], known: 3)
        if let faceBox {
            if let tip = hand[.indexTip], faceBox.contains(tip) { point = 0 }
            if let tip = hand[.thumbTip], faceBox.contains(tip) { thumbsUp = 0 }
        }
        let peace = index == nil || middle == nil ? 0 : all([extended(index), extended(middle), curled(ring), curled(little)], known: 3)
        self.init(thumbsUp: thumbsUp,
                  point: point,
                  openPalm: all(fingers.map(extended), known: 3),
                  fist: all(fingers.map(curled), known: 3),
                  peace: peace)
    }

    var values: [Double] {
        [thumbsUp, point, openPalm, fist, peace]
    }

    /// The strongest sign that means something on its own (thumbs up, pointing, peace); a plain open hand or fist doesn't.
    public var signStrength: Double {
        max(thumbsUp, point, peace)
    }

    /// The most of each sign over several hands; nil for none.
    public static func strongest(_ shapes: [HandShape]) -> HandShape? {
        guard var result = shapes.first else { return nil }
        for shape in shapes.dropFirst() {
            result.thumbsUp = max(result.thumbsUp, shape.thumbsUp)
            result.point = max(result.point, shape.point)
            result.openPalm = max(result.openPalm, shape.openPalm)
            result.fist = max(result.fist, shape.fist)
            result.peace = max(result.peace, shape.peace)
        }
        return result
    }

    /// Rounded to 3 decimals, so stored JSON stays short.
    func rounded() -> HandShape {
        HandShape(thumbsUp: PoseDescriptor.round(thumbsUp), point: PoseDescriptor.round(point),
                  openPalm: PoseDescriptor.round(openPalm), fist: PoseDescriptor.round(fist), peace: PoseDescriptor.round(peace))
    }
}

/// A pose as 13 numbers (each 0...1, nil when a joint it needs wasn't seen) plus the hand's sign, measured in the
/// body's own frame: from the middle of the shoulders, along the shoulder line, in shoulder widths. So the same pose
/// gives the same numbers however large, tilted or framed the person is.
public struct PoseDescriptor: Codable, Hashable, Sendable {
    public enum Dimension: Int, CaseIterable, Sendable {
        /// Wrist height: 0 well below the shoulders, ≈ 0.43 at shoulder height, ≈ 0.63 at the head, 1 high above it.
        case leftLift, leftOut, leftHead, leftElbowLift, leftElbowBend
        case rightLift, rightOut, rightHead, rightElbowLift, rightElbowBend
        /// Distance between the wrists (0 together, 1 three shoulder widths apart).
        case wristGap
        /// Shoulder line tilt (1 at 30°).
        case shoulderTilt
        /// Head height above the shoulders (lower when shrugging).
        case headRise
    }

    public static let count = Dimension.allCases.count

    /// Indexed by `Dimension`.
    public private(set) var values: [Double?]
    public var hand: HandShape?

    public init(values: [Double?], hand: HandShape? = nil) {
        var normalized = Array(values.prefix(PoseDescriptor.count)).map { value in
            value.flatMap { $0.isFinite ? VectorMath.clampUnit($0) : nil }
        }
        while normalized.count < PoseDescriptor.count {
            normalized.append(nil)
        }
        self.values = normalized
        self.hand = hand
    }

    public subscript(dimension: Dimension) -> Double? {
        values[dimension.rawValue]
    }

    /// Measures the pose; nil without shoulders (or a neck) to measure from, or when the body is tiny in the image.
    public init?(_ joints: BodyJoints, hand: HandShape? = nil) {
        let leftShoulder = joints[.leftShoulder]
        let rightShoulder = joints[.rightShoulder]

        let origin: PosePoint
        if let left = leftShoulder, let right = rightShoulder {
            origin = PosePoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
        } else if let neck = joints[.neck] {
            origin = neck
        } else {
            return nil
        }

        // One shoulder width; a turned body narrows the shoulders, so the head's size keeps it from collapsing.
        var scale = 0.0
        if let left = leftShoulder, let right = rightShoulder {
            scale = left.distance(to: right)
        }
        let shoulderGap = scale
        var headScale: Double?
        if let left = joints[.leftEar], let right = joints[.rightEar] {
            headScale = 2.6 * left.distance(to: right)
        } else if let left = joints[.leftEye], let right = joints[.rightEye] {
            headScale = 6 * left.distance(to: right)
        } else if let nose = joints[.nose], let ear = joints[.leftEar] ?? joints[.rightEar] {
            // Seen from the side: nose to ear is about a third of a shoulder width.
            headScale = 3 * nose.distance(to: ear)
        }
        if let headScale {
            scale = max(scale, 0.8 * headScale)
        }
        // An upper arm is about 0.8–1 shoulder width, however the body is turned.
        let upperArms = [(leftShoulder, joints[.leftElbow]), (rightShoulder, joints[.rightElbow])].compactMap { pair -> Double? in
            guard let shoulder = pair.0, let elbow = pair.1 else { return nil }
            return shoulder.distance(to: elbow)
        }
        if let longest = upperArms.max() {
            scale = max(scale, 0.7 * longest)
        }
        guard scale.isFinite, scale > 0, scale >= 0.02 * joints.shortSide else { return nil }
        // A body turned to the side shows its shoulders almost on top of each other: their line says nothing about tilt.
        let shoulderLineIsReliable = leftShoulder != nil && rightShoulder != nil && shoulderGap >= 0.5 * scale

        // The shoulder line's tilt, taken left to right in the image whichever way the person faces.
        var roll = 0.0
        if shoulderLineIsReliable, let left = leftShoulder, let right = rightShoulder {
            var dx = left.x - right.x
            var dy = left.y - right.y
            if dx < 0 {
                dx = -dx
                dy = -dy
            }
            roll = atan2(dy, dx)
        }
        let cosine = cos(-roll)
        let sine = sin(-roll)
        func local(_ point: PosePoint) -> PosePoint {
            let dx = point.x - origin.x
            let dy = point.y - origin.y
            return PosePoint(x: (dx * cosine - dy * sine) / scale, y: (dx * sine + dy * cosine) / scale)
        }

        let head = PosePoint.mean(joints.headPoints).map(local)
        var values = [Double?](repeating: nil, count: PoseDescriptor.count)

        func measureArm(shoulder: BodyJoint, elbow: BodyJoint, wrist: BodyJoint, first: Dimension) {
            let base = first.rawValue
            let shoulderPoint = joints[shoulder].map(local)
            let elbowPoint = joints[elbow].map(local)
            let wristPoint = joints[wrist].map(local)
            if let wristPoint {
                values[base] = (wristPoint.y + 1.5) / 3.5
                values[base + 1] = abs(wristPoint.x) / 2.5
                if let head {
                    values[base + 2] = wristPoint.distance(to: head) / 2
                }
            }
            guard let shoulderPoint, let elbowPoint else { return }
            let upperX = elbowPoint.x - shoulderPoint.x
            let upperY = elbowPoint.y - shoulderPoint.y
            let upperLength = (upperX * upperX + upperY * upperY).squareRoot()
            guard upperLength > 1e-6 else { return }
            // Upper arm angle from hanging straight down: 0 down, 0.5 straight out, 1 straight up.
            values[base + 3] = acos(max(-1, min(1, -upperY / upperLength))) / Double.pi
            guard let wristPoint else { return }
            let foreX = wristPoint.x - elbowPoint.x
            let foreY = wristPoint.y - elbowPoint.y
            let foreLength = (foreX * foreX + foreY * foreY).squareRoot()
            guard foreLength > 1e-6 else { return }
            // 0 for a straight arm, rising as the elbow bends.
            let cosAngle = (-upperX * foreX - upperY * foreY) / (upperLength * foreLength)
            values[base + 4] = 1 - acos(max(-1, min(1, cosAngle))) / Double.pi
        }
        measureArm(shoulder: .leftShoulder, elbow: .leftElbow, wrist: .leftWrist, first: .leftLift)
        measureArm(shoulder: .rightShoulder, elbow: .rightElbow, wrist: .rightWrist, first: .rightLift)

        if let left = joints[.leftWrist], let right = joints[.rightWrist] {
            values[Dimension.wristGap.rawValue] = left.distance(to: right) / scale / 3
        }
        if shoulderLineIsReliable {
            values[Dimension.shoulderTilt.rawValue] = abs(roll) / (Double.pi / 6)
        }
        if let head {
            values[Dimension.headRise.rawValue] = head.y / 1.5
        }
        guard values.contains(where: { $0 != nil }) || hand != nil else { return nil }
        self.init(values: values.map { $0.map(PoseDescriptor.round) }, hand: hand?.rounded())
    }

    /// The same pose with the arms swapped (a mirrored image).
    public var mirrored: PoseDescriptor {
        var swapped = values
        let arm = Dimension.rightLift.rawValue - Dimension.leftLift.rawValue
        for offset in 0..<arm {
            swapped[offset] = values[offset + arm]
            swapped[offset + arm] = values[offset]
        }
        return PoseDescriptor(values: swapped, hand: hand)
    }

    /// Whether any arm number (or a hand sign) was measured.
    public var showsArms: Bool {
        if hand != nil { return true }
        let armDimensions: [Dimension] = [.leftLift, .leftElbowLift, .rightLift, .rightElbowLift, .wristGap]
        return armDimensions.contains { self[$0] != nil }
    }

    // MARK: Gesture strength

    /// Arms hanging at the sides; how far a pose is from this is how much of a gesture it is.
    private static let rest: [(dimension: Dimension, value: Double, weight: Double)] = [
        (.leftLift, 0.03, 1), (.leftOut, 0.2, 0.5), (.leftHead, 1, 1), (.leftElbowLift, 0.05, 0.5), (.leftElbowBend, 0.1, 0.25),
        (.rightLift, 0.03, 1), (.rightOut, 0.2, 0.5), (.rightHead, 1, 1), (.rightElbowLift, 0.05, 0.5), (.rightElbowBend, 0.1, 0.25),
        (.wristGap, 0.37, 0.5),
    ]

    /// An upper arm seen without its wrist counts as raised only this close to vertical (hands out of the top of the
    /// frame); elbows up and out with the wrists hidden are hands clasped behind the head, a resting pose.
    public static let elbowOnlyUp = 0.88

    /// How much the wrists seen rest low, in front and away from the head (forearms on a desk or in the lap, a mug or
    /// phone held at the chest): 1 inside that zone (lift ≤ 0.3, out ≤ 0.2, head ≥ 0.45), falling to 0 across a narrow
    /// band around it so the strength never jumps; 0 without a wrist.
    var forearmRest: Double {
        let factors = [
            self[.leftLift] == nil ? nil : armRest(lift: .leftLift, out: .leftOut, head: .leftHead),
            self[.rightLift] == nil ? nil : armRest(lift: .rightLift, out: .rightOut, head: .rightHead),
        ].compactMap { $0 }
        return factors.min() ?? 0
    }

    /// How much one wrist rests low, in front and away from the head (see `forearmRest`); 0 without that wrist.
    private func armRest(lift: Dimension, out: Dimension, head: Dimension) -> Double {
        guard let liftValue = self[lift] else { return 0 }
        return min(VectorMath.clampUnit((0.38 - liftValue) / 0.08),
                   VectorMath.clampUnit((0.26 - (self[out] ?? 1)) / 0.06),
                   VectorMath.clampUnit(((self[head] ?? 0) - 0.35) / 0.1))
    }

    /// 0 for arms at rest (hanging, on a desk, holding a mug at the chest, behind the head, or not seen) … 1 for a clear
    /// gesture: the weighted RMS distance from arms hanging at the sides over the arms seen, each arm's part scaled down
    /// by how much that arm rests (`armRest`), minus a small dead zone (fidgeting, typing); or a clear hand sign.
    public var gestureStrength: Double {
        var strength = 0.0
        // Each arm's distance is discounted by how much that arm rests (a phone in one hand and the other arm hanging
        // or on the mouse is still rest); the wrist gap by the more resting of the two.
        let leftRest = armRest(lift: .leftLift, out: .leftOut, head: .leftHead)
        let rightRest = armRest(lift: .rightLift, out: .rightOut, head: .rightHead)
        var sum = 0.0
        var weights = 0.0
        for entry in PoseDescriptor.rest {
            guard let value = self[entry.dimension] else { continue }
            if entry.dimension == .leftElbowLift && self[.leftLift] == nil && value < PoseDescriptor.elbowOnlyUp { continue }
            if entry.dimension == .rightElbowLift && self[.rightLift] == nil && value < PoseDescriptor.elbowOnlyUp { continue }
            let resting: Double
            if entry.dimension.rawValue < Dimension.rightLift.rawValue {
                resting = leftRest
            } else if entry.dimension.rawValue < Dimension.wristGap.rawValue {
                resting = rightRest
            } else {
                resting = max(leftRest, rightRest)
            }
            let difference = value - entry.value
            sum += entry.weight * (1 - resting) * difference * difference
            weights += entry.weight
        }
        if weights > 0 {
            let rms = (sum / weights).squareRoot()
            strength = VectorMath.clampUnit((rms - 0.1) / 0.3)
        }
        if let sign = hand?.signStrength, sign >= 0.7 {
            strength = max(strength, sign)
        }
        return strength
    }

    /// Mirror-invariant summary for telling one gesture from another (each 0 at rest):
    /// [higher wrist lift, lower wrist lift, nearer wrist to head, farther wrist to head, wrist gap, higher elbow,
    ///  thumbs up, pointing, peace] — a hand sign counts from 0.7, so relaxing the hand doesn't read as a new gesture.
    public var gestureDirection: [Double] {
        func pair(_ left: Dimension, _ right: Dimension) -> (high: Double?, low: Double?) {
            let seen = [self[left], self[right]].compactMap { $0 }
            return (seen.max(), seen.min())
        }
        let lift = pair(.leftLift, .rightLift)
        let head = pair(.leftHead, .rightHead)
        let elbow = pair(.leftElbowLift, .rightElbowLift)
        return [
            lift.high.map { $0 - 0.03 } ?? 0,
            lift.low.map { $0 - 0.03 } ?? 0,
            head.low.map { 1 - $0 } ?? 0,
            head.high.map { 1 - $0 } ?? 0,
            self[.wristGap].map { $0 - 0.37 } ?? 0,
            elbow.high.map { $0 - 0.05 } ?? 0,
            PoseDescriptor.sign(hand?.thumbsUp),
            PoseDescriptor.sign(hand?.point),
            PoseDescriptor.sign(hand?.peace),
        ]
    }

    /// A hand sign's strength when it is clear (≥ 0.7), else 0.
    private static func sign(_ value: Double?) -> Double {
        guard let value, value >= 0.7 else { return 0 }
        return value
    }

    // MARK: Similarity

    private static let weights: [Double] = [2, 1, 2, 1, 1, 2, 1, 2, 1, 1, 1.5, 0.5, 0.5]
    /// Per number: similarity falls to 0 at this difference.
    private static let tolerance = 0.25

    /// How alike two poses are on the numbers both have (0...1), and how much of what either shows that is (coverage, 0...1).
    /// Hand signs count only when both have a hand. Not mirrored: see `PoseFeatures.similarity(query:item:)`.
    public static func compare(_ a: PoseDescriptor, _ b: PoseDescriptor) -> (similarity: Double, coverage: Double) {
        var shared = 0.0
        var union = 0.0
        var total = 0.0
        for index in 0..<count {
            let weight = weights[index]
            switch (a.values[index], b.values[index]) {
            case let (x?, y?):
                shared += weight
                union += weight
                total += weight * max(0, 1 - abs(x - y) / tolerance)
            case (nil, nil):
                break
            default:
                union += weight
            }
        }
        if let first = a.hand, let second = b.hand {
            for (x, y) in zip(first.values, second.values) {
                shared += 1
                union += 1
                total += max(0, 1 - abs(x - y) / tolerance)
            }
        }
        guard shared > 0, union > 0 else { return (0, 0) }
        return (total / shared, shared / union)
    }

    static func round(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }

    // MARK: Codable (lenient: a damaged descriptor reads as "no numbers" rather than failing the item)

    private enum CodingKeys: String, CodingKey {
        case values, hand
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(values: container.decodeLenient([Double?].self, forKey: .values, default: []),
                  hand: container.decodeLenientIfPresent(HandShape.self, forKey: .hand))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(values, forKey: .values)
        try container.encodeIfPresent(hand, forKey: .hand)
    }
}
