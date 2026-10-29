import Foundation

/// A body joint MemeMe reads from Vision's body pose: the head, arms and hips (the hips only tell how upright the body
/// stands; the legs are ignored).
public enum BodyJoint: String, CaseIterable, Sendable {
    case nose, leftEye, rightEye, leftEar, rightEar, neck
    case leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
    case root, leftHip, rightHip
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

    /// How wide the body is across the image (a fraction of its width): its shoulders, or 2.6 times the gap between the
    /// ears when that is wider (a body turned to the side); nil when neither was seen. `aspect` is the image's width /
    /// height. About 0.4 at a laptop, 0.12 standing back far enough to show the whole body.
    public func widthInImage(aspect: Double) -> Double? {
        var widths: [Double] = []
        if let left = points[.leftShoulder], let right = points[.rightShoulder] {
            widths.append(left.distance(to: right))
        }
        if let left = points[.leftEar], let right = points[.rightEar] {
            widths.append(2.6 * left.distance(to: right))
        }
        guard let widest = widths.max(), aspect > 0 else { return nil }
        return widest / aspect
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

/// How much a hand looks like each sign, all 0...1, and how straight each of its fingers is.
public struct HandShape: Codable, Hashable, Sendable {
    public var thumbsUp: Double
    public var point: Double
    public var openPalm: Double
    public var fist: Double
    public var peace: Double
    /// How straight each finger is, thumb first (indexed by `Finger`: thumb, index, middle, ring, little): 0 curled …
    /// 1 straight; nil for a finger not seen. nil for hands read before fingers were kept (stored library poses).
    public var fingers: [Double?]?
    /// True when a straightened finger's tip lay on the face as the hand was read (nil otherwise): its finger pattern
    /// is then no sign (`patternStrength`), though `fingers` keeps how straight each finger is.
    var fingertipsOnFace: Bool?

    public init(thumbsUp: Double = 0, point: Double = 0, openPalm: Double = 0, fist: Double = 0, peace: Double = 0,
                fingers: [Double?]? = nil) {
        self.thumbsUp = thumbsUp
        self.point = point
        self.openPalm = openPalm
        self.fist = fist
        self.peace = peace
        self.fingers = fingers
    }

    /// A hand's fingers, in the order `fingers` keeps them.
    public enum Finger: Int, CaseIterable, Sendable {
        case thumb, index, middle, ring, little
    }

    /// How straight `finger` is (0 curled … 1 straight); nil when it wasn't seen, or the fingers weren't kept.
    public subscript(finger: Finger) -> Double? {
        guard let fingers, finger.rawValue < fingers.count else { return nil }
        return fingers[finger.rawValue]
    }

    /// A finger's straightness (`fingers`) is 0 up to this tip-to-wrist / middle-joint-to-wrist ratio, and rises to 1
    /// over the next `straightRange` (≥ 1.25: clearly extended; a curled finger's tip is nearer the wrist than its middle
    /// joint, about 0.7).
    static let straightFromRatio = 0.9
    static let straightRange = 0.35
    /// The thumb's straightness is 0 up to this distance from its tip to the middle finger's knuckle, in palm lengths
    /// (wrist to that knuckle; a thumb tucked against the fingers is about 0.4 away), rising to 1 over `straightRange`.
    static let thumbStraightFrom = 0.55
    /// A finger at least this straight whose tip lies on the face makes the pattern no sign.
    static let fingertipOnFace = 0.5

    /// nil when the wrist or too few fingers were seen. With `faceBox`, a finger or thumb lying on the face (a finger up
    /// the cheek while thinking, "shh", a thumb along the jaw, two fingers propping the head) is no pointing,
    /// thumbs-up or peace sign, nor any other finger pattern (`fingertipsOnFace`).
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
        let ratios = [index, middle, ring, little]
        guard ratios.compactMap({ $0 }).count >= 2 else { return nil }

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
        var peace = index == nil || middle == nil ? 0 : all([extended(index), extended(middle), curled(ring), curled(little)], known: 3)
        if let faceBox {
            if let tip = hand[.indexTip], faceBox.contains(tip) { point = 0 }
            if let tip = hand[.thumbTip], faceBox.contains(tip) { thumbsUp = 0 }
            // Two fingers along the cheek or temple (a head propped while thinking) aren't a V.
            if [hand[.indexTip], hand[.middleTip]].contains(where: { $0.map(faceBox.contains) ?? false }) { peace = 0 }
        }

        // How straight each finger is, for telling (and describing) any finger pattern. The thumb has no middle joint
        // to compare with: it is straight when its tip stands clear of the palm.
        func straightness(_ value: Double?) -> Double? {
            value.map { VectorMath.clampUnit(($0 - HandShape.straightFromRatio) / HandShape.straightRange) }
        }
        var thumb: Double?
        if let tip = hand[.thumbTip], let knuckle = hand[.middleMCP] {
            let palm = wrist.distance(to: knuckle)
            if palm > 1e-6 {
                thumb = VectorMath.clampUnit((tip.distance(to: knuckle) / palm - HandShape.thumbStraightFrom) / HandShape.straightRange)
            }
        }
        let fingers = [thumb] + ratios.map(straightness)
        self.init(thumbsUp: thumbsUp,
                  point: point,
                  openPalm: all(ratios.map(extended), known: 3),
                  fist: all(ratios.map(curled), known: 3),
                  peace: peace,
                  fingers: fingers)
        if let faceBox {
            let tips: [HandJoint] = [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]
            let onFace = zip(tips, fingers).contains { tip, straight in
                (straight ?? 0) >= HandShape.fingertipOnFace && (hand[tip].map(faceBox.contains) ?? false)
            }
            if onFace {
                fingertipsOnFace = true
            }
        }
    }

    var values: [Double] {
        [thumbsUp, point, openPalm, fist, peace]
    }

    /// The strongest sign that means something on its own (thumbs up, pointing, peace, or any other deliberate finger
    /// pattern: horns, hang loose, finger guns…); a plain open hand or fist doesn't. As a gesture, a pattern counts only
    /// away from rest (`PoseDescriptor.handSignStrength`).
    public var signStrength: Double {
        max(thumbsUp, point, peace, patternStrength)
    }

    /// A deliberate finger pattern, whatever it means: with at least 3 fingers seen, the weaker of the straightest of
    /// the four fingers' straightness and the most curled one's curl (1 − straightness). So 1 when some of them are
    /// clearly straight and others clearly curled (pointing, horns, hang loose, three fingers up); 0 for a fist, a thumb
    /// alone out of one (a thumb opposed round a mug or a phone stands clear of the palm too; a thumbs up is
    /// `thumbsUp`), an open palm (the thumb tucked against it too), a loose hand, fingers not kept, or a straightened
    /// fingertip on the face (a finger up the cheek while thinking). The thumb still tells patterns apart (`fingers`).
    public var patternStrength: Double {
        guard fingertipsOnFace != true, let fingers else { return 0 }
        let seen = fingers.compactMap { $0 }
        let fourFingers = fingers.dropFirst().compactMap { $0 }
        guard seen.count >= 3, let straightest = fourFingers.max(), let mostCurled = fourFingers.min() else { return 0 }
        return min(straightest, 1 - mostCurled)
    }

    /// Whether this hand and `other` hold their fingers differently: some finger seen on both is clearly straight
    /// (≥ 0.7) on one and clearly curled (≤ 0.3) on the other (horns and hang loose, horns and love you); false when
    /// either hand's fingers weren't kept.
    func holdsFingersOtherwise(than other: HandShape) -> Bool {
        Finger.allCases.contains { finger in
            guard let mine = self[finger], let theirs = other[finger] else { return false }
            return (mine >= 0.7 && theirs <= 0.3) || (mine <= 0.3 && theirs >= 0.7)
        }
    }

    /// The most of each sign over several hands, with the fingers of the hand that shows the most (the strongest sign,
    /// then the clearest fist or open palm; the first on a tie; nil when no hand kept its fingers), so horns made with
    /// one hand stay a sign beside an open other hand; nil for no hands.
    public static func strongest(_ shapes: [HandShape]) -> HandShape? {
        guard var result = shapes.first else { return nil }
        for shape in shapes.dropFirst() {
            result.thumbsUp = max(result.thumbsUp, shape.thumbsUp)
            result.point = max(result.point, shape.point)
            result.openPalm = max(result.openPalm, shape.openPalm)
            result.fist = max(result.fist, shape.fist)
            result.peace = max(result.peace, shape.peace)
        }
        var shown: HandShape?
        for shape in shapes where shape.fingers != nil {
            if let current = shown, !shape.showsMore(than: current) { continue }
            shown = shape
        }
        result.fingers = shown?.fingers
        result.fingertipsOnFace = shown?.fingertipsOnFace
        return result
    }

    /// One body's hands as one shape, as `strongest(_:)` but with the open palm and the fist of the highest hand: the
    /// raised hand says what the gesture is (a wave's open palm, a flexed arm's fist), not a relaxed hand hanging at the
    /// side, which reads as an open palm and would make a one-arm flex "hello". nil when no hand could be read.
    public static func strongest(of hands: [HandJoints], faceBox: PoseBox? = nil) -> HandShape? {
        let highestFirst = hands.sorted { ($0[.wrist]?.y ?? -.infinity) > ($1[.wrist]?.y ?? -.infinity) }
        let shapes = highestFirst.compactMap { HandShape($0, faceBox: faceBox) }
        guard var result = strongest(shapes), let raised = shapes.first else { return nil }
        result.openPalm = raised.openPalm
        result.fist = raised.fist
        return result
    }

    /// Whether this hand shows more than `other`: a stronger sign, or as strong a one and a clearer fist or open palm.
    private func showsMore(than other: HandShape) -> Bool {
        if signStrength != other.signStrength {
            return signStrength > other.signStrength
        }
        return max(fist, openPalm) > max(other.fist, other.openPalm)
    }

    /// Rounded to 3 decimals, so stored JSON stays short.
    func rounded() -> HandShape {
        var shape = HandShape(thumbsUp: PoseDescriptor.round(thumbsUp), point: PoseDescriptor.round(point),
                              openPalm: PoseDescriptor.round(openPalm), fist: PoseDescriptor.round(fist),
                              peace: PoseDescriptor.round(peace),
                              fingers: fingers?.map { $0.map(PoseDescriptor.round) })
        shape.fingertipsOnFace = fingertipsOnFace
        return shape
    }
}

/// A body pose with a word of its own, told from the body alone (`PoseDescriptor.bodyShape`).
public enum BodyShape: String, CaseIterable, Sendable {
    case dab, bolt, flex, ohNo, armsCrossed, tPose, handsOnHips, pickMe, hello, bow
}

/// A pose as 20 numbers (each 0...1, nil when a joint it needs wasn't seen) plus the hand's sign, measured in the
/// body's own frame: from the middle of the shoulders, along the shoulder line, in shoulder widths. So the same pose
/// gives the same numbers however large, tilted or framed the person is. Numbers are only ever appended: a descriptor
/// stored with fewer reads the missing ones as not seen.
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
        /// How far the wrist reaches across the body: 0 at (or outside) its own shoulder, 0.25 at the middle, 0.5 at the
        /// other shoulder. Only while the shoulder line is seen square on.
        case leftCross, rightCross
        /// How far out to the side the elbow is (as `leftOut` is for the wrist).
        case leftElbowOut, rightElbowOut
        /// Shoulders to hips (0.5 per shoulder width): about 0.675 standing upright, short when bowing to the camera.
        case torsoLength
        /// How much the forearm rises from the elbow to the wrist: 0.5 level, more with the wrist above the elbow
        /// (arms crossed over the chest), less below it (forearms folded on a desk).
        case leftForearmRise, rightForearmRise
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

        func measureArm(shoulder: BodyJoint, elbow: BodyJoint, wrist: BodyJoint, first: Dimension, cross: Dimension,
                        elbowOut: Dimension, forearmRise: Dimension) {
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
                // Toward the other side is away from this arm's own shoulder, whichever way the image is flipped.
                if shoulderLineIsReliable, let shoulderPoint {
                    let side: Double = shoulderPoint.x >= 0 ? 1 : -1
                    values[cross.rawValue] = (0.5 - side * wristPoint.x) / 2
                }
            }
            if let elbowPoint {
                values[elbowOut.rawValue] = abs(elbowPoint.x) / 2.5
                if let wristPoint {
                    values[forearmRise.rawValue] = 0.5 + (wristPoint.y - elbowPoint.y) / 2
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
        measureArm(shoulder: .leftShoulder, elbow: .leftElbow, wrist: .leftWrist, first: .leftLift,
                   cross: .leftCross, elbowOut: .leftElbowOut, forearmRise: .leftForearmRise)
        measureArm(shoulder: .rightShoulder, elbow: .rightElbow, wrist: .rightWrist, first: .rightLift,
                   cross: .rightCross, elbowOut: .rightElbowOut, forearmRise: .rightForearmRise)

        if let left = joints[.leftWrist], let right = joints[.rightWrist] {
            values[Dimension.wristGap.rawValue] = left.distance(to: right) / scale / 3
        }
        if shoulderLineIsReliable {
            values[Dimension.shoulderTilt.rawValue] = abs(roll) / (Double.pi / 6)
        }
        if let head {
            values[Dimension.headRise.rawValue] = head.y / 1.5
        }
        let hips = [joints[.leftHip], joints[.rightHip]].compactMap { $0 }
        if let hipMiddle = hips.count == 2 ? PosePoint.mean(hips) : joints[.root] {
            let torso = local(hipMiddle)
            values[Dimension.torsoLength.rawValue] = (torso.x * torso.x + torso.y * torso.y).squareRoot() / 2
        }
        guard values.contains(where: { $0 != nil }) || hand != nil else { return nil }
        self.init(values: values.map { $0.map(PoseDescriptor.round) }, hand: hand?.rounded())
    }

    /// Each left number with its right one.
    private static let mirrorPairs: [(Dimension, Dimension)] = [
        (.leftLift, .rightLift), (.leftOut, .rightOut), (.leftHead, .rightHead), (.leftElbowLift, .rightElbowLift),
        (.leftElbowBend, .rightElbowBend), (.leftCross, .rightCross), (.leftElbowOut, .rightElbowOut),
        (.leftForearmRise, .rightForearmRise),
    ]

    /// The same pose with the arms swapped (a mirrored image).
    public var mirrored: PoseDescriptor {
        var swapped = values
        for (left, right) in PoseDescriptor.mirrorPairs {
            swapped[left.rawValue] = values[right.rawValue]
            swapped[right.rawValue] = values[left.rawValue]
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

    /// How much one wrist may be holding something (a phone or a mug at the chest, a hand on a desk or a mouse): its
    /// rest (`armRest`), but only for an arm bent (elbow bend from 0.2, fully at 0.3) or with its wrist above the waist
    /// (lift from 0.1, fully at 0.15). An arm hanging straight with its wrist under the shoulder rests as much as one
    /// holding a phone, but holds nothing. Without the elbow seen, its rest.
    private func holdingRest(lift: Dimension, out: Dimension, head: Dimension, bend: Dimension) -> Double {
        let rest = armRest(lift: lift, out: out, head: head)
        guard rest > 0, let bendValue = self[bend] else { return rest }
        let raised = VectorMath.clampUnit(((self[lift] ?? 0) - 0.1) / 0.05)
        let bent = VectorMath.clampUnit((bendValue - 0.2) / 0.1)
        return rest * max(raised, bent)
    }

    /// From this `holdingRest` a wrist may be holding something: a hand's finger pattern is then no sign.
    static let patternAtRest = 0.5

    /// The hand's finger pattern (`HandShape.patternStrength`) as a sign: 0 while a wrist seen rests low in front on a
    /// bent arm or above the waist (`holdingRest` ≥ `patternAtRest`), where fingers along the back of a phone held at
    /// the chest, round a mug or on a mouse read as a pattern too (which hand made the pattern isn't kept, so either
    /// wrist counts); an arm hanging straight holds nothing. 0 without a hand.
    var patternSign: Double {
        guard let hand else { return 0 }
        let holding = max(holdingRest(lift: .leftLift, out: .leftOut, head: .leftHead, bend: .leftElbowBend),
                          holdingRest(lift: .rightLift, out: .rightOut, head: .rightHead, bend: .rightElbowBend))
        return holding < PoseDescriptor.patternAtRest ? hand.patternStrength : 0
    }

    /// The hand's strongest sign as a gesture: thumbs up, pointing or peace, or another finger pattern away from rest
    /// (`patternSign`); 0 without a hand.
    var handSignStrength: Double {
        guard let hand else { return 0 }
        return max(hand.thumbsUp, hand.point, hand.peace, patternSign)
    }

    /// Whether this pose's hand makes a clear finger pattern away from rest (`patternSign` ≥ 0.7), as `other`'s does,
    /// with its fingers held otherwise (`HandShape.holdsFingersOtherwise`): horns, then hang loose. The arms, the five
    /// sign scores (`compare`) and `gestureDirection` can read the same for both.
    func makesAnotherFingerPattern(than other: PoseDescriptor) -> Bool {
        guard let hand, let otherHand = other.hand, patternSign >= 0.7, other.patternSign >= 0.7 else { return false }
        return hand.holdsFingersOtherwise(than: otherHand)
    }

    /// 0 for arms at rest (hanging, on a desk, holding a mug at the chest, behind the head, or not seen) … 1 for a clear
    /// gesture: the arms' distance from rest (`armStrength`); at least 0.6 for a body shape with its own word (hands on
    /// hips and arms crossed sit close to rest); or a clear hand sign (`handSignStrength` ≥ 0.7: a named sign, or any
    /// other deliberate finger pattern while no wrist may be holding something, so horns start a search with the arms
    /// hanging, and a phone held at the chest doesn't).
    public var gestureStrength: Double {
        var strength = armStrength
        if bodyShape != nil {
            strength = max(strength, PoseDescriptor.shapeStrength)
        }
        let sign = handSignStrength
        if sign >= 0.7 {
            strength = max(strength, sign)
        }
        return strength
    }

    /// The gesture strength of a pose that is one of the `BodyShape`s.
    public static let shapeStrength = 0.6

    /// The weighted RMS distance from arms hanging at the sides over the arms seen, each arm's part scaled down by how
    /// much that arm rests (`armRest`), minus a small dead zone (fidgeting, typing): 0 at rest … 1.
    var armStrength: Double {
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
        return strength
    }

    /// Mirror-invariant summary for telling one gesture from another (each 0 at rest), 10 numbers:
    /// [higher wrist lift, lower wrist lift, nearer wrist to head, farther wrist to head, wrist gap, higher elbow,
    ///  thumbs up, pointing, peace, another finger pattern] — a hand sign counts from 0.7, so relaxing the hand doesn't
    /// read as a new gesture; the last is the hand's pattern strength as a sign (`patternSign`) beyond what the three
    /// named signs already tell (horns, hang loose, finger guns…; 0 for pointing, which `point` tells). All finger
    /// patterns share it: the tracker tells one from another by the fingers (`makesAnotherFingerPattern`).
    public var gestureDirection: [Double] {
        // An arm whose wrist wasn't seen, next to one that was, reads as resting (out of frame ≈ arms down, as in
        // `gestureStrength`) — not as a copy of the other — unless its upper arm is near vertical (hands out of the top
        // of the frame). So one arm up and both arms up are different gestures.
        let hiddenArmUp = (self[.leftLift] == nil && (self[.leftElbowLift] ?? 0) >= PoseDescriptor.elbowOnlyUp)
            || (self[.rightLift] == nil && (self[.rightElbowLift] ?? 0) >= PoseDescriptor.elbowOnlyUp)
        func pair(_ left: Dimension, _ right: Dimension, resting: Double? = nil) -> (high: Double?, low: Double?) {
            var seen = [self[left], self[right]].compactMap { $0 }
            if seen.count == 1, let resting, !hiddenArmUp {
                seen.append(resting)
            }
            return (seen.max(), seen.min())
        }
        let lift = pair(.leftLift, .rightLift, resting: 0.03)
        let head = pair(.leftHead, .rightHead, resting: 1)
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
            PoseDescriptor.sign(hand.map { max(0, patternSign - max($0.thumbsUp, $0.point, $0.peace)) }),
        ]
    }

    /// A hand sign's strength when it is clear (≥ 0.7), else 0.
    private static func sign(_ value: Double?) -> Double {
        guard let value, value >= 0.7 else { return 0 }
        return value
    }

    // MARK: Body shapes

    /// One arm's numbers.
    private struct Arm {
        let lift: Double?
        let out: Double?
        let head: Double?
        let elbowLift: Double?
        let bend: Double?
        let cross: Double?
        let elbowOut: Double?
        let forearmRise: Double?

        /// Hanging or low (lift ≤ 0.4); with the wrist unseen, an elbow that isn't raised (or isn't seen either).
        var isLow: Bool {
            if let lift { return lift <= 0.4 }
            return (elbowLift ?? 0) < 0.4
        }
    }

    private var leftArm: Arm {
        Arm(lift: self[.leftLift], out: self[.leftOut], head: self[.leftHead], elbowLift: self[.leftElbowLift],
            bend: self[.leftElbowBend], cross: self[.leftCross], elbowOut: self[.leftElbowOut],
            forearmRise: self[.leftForearmRise])
    }

    private var rightArm: Arm {
        Arm(lift: self[.rightLift], out: self[.rightOut], head: self[.rightHead], elbowLift: self[.rightElbowLift],
            bend: self[.rightElbowBend], cross: self[.rightCross], elbowOut: self[.rightElbowOut],
            forearmRise: self[.rightForearmRise])
    }

    /// The pose's shape when it is one with a word of its own, read from the body alone (no face), whichever arm does
    /// what; nil otherwise. Each test needs the numbers it reads (a missing one never matches), first match wins:
    /// - dab: one arm straight up and out (lift ≥ 0.6, out ≥ 0.4, bend ≤ 0.25, not across) and the other across the face
    ///   (cross ≥ 0.35, lift ≥ 0.5, head ≤ 0.5)
    /// - bolt: one arm straight up and out and the other drawn back (bend ≥ 0.3, lift 0.3...0.6, cross ≤ 0.3)
    /// - flex: both upper arms out near level (elbowLift 0.36...0.66), elbows bent ≥ 0.38, fists up (lift ≥ 0.5) beside
    ///   the head (head ≥ 0.36)
    /// - ohNo: both hands on top of the head (head ≤ 0.35, lift ≥ 0.5 and clearly above the head's centre, by 0.07; hands
    ///   clasped behind the head sit lower), not both out at the temples (mind blown)
    /// - armsCrossed: both wrists across the body (cross ≥ 0.27), elbows bent ≥ 0.3, wrists between the waist and the
    ///   chest (lift ≤ 0.45; ≥ 0.12 with hips in view; with none, ≥ 0.21 and each wrist above its elbow, forearmRise
    ///   ≥ 0.52, so forearms folded on a desk, or leaned on, stay rest)
    /// - tPose: both arms straight (bend ≤ 0.2) out to the side (out ≥ 0.55) at shoulder height (lift 0.3...0.6,
    ///   elbowLift 0.38...0.65 when seen)
    /// - handsOnHips: upright with the hips in view (torso ≥ 0.5) and an elbow out past its wrist (elbowOut − out ≥ 0.1), raised
    ///   (elbowLift ≥ 0.15) and the wrist at the waist (lift ≤ 0.32): both arms, or one (elbowLift ≥ 0.17) with the other
    ///   low
    /// - pickMe: one arm straight up (lift ≥ 0.75, bend ≤ 0.35, clear of the head) and the other low
    /// - hello: one hand raised beside the head (lift 0.5...0.8, head 0.3...0.75, out ≥ 0.2, elbowLift ≤ 0.6, bend ≥ 0.25),
    ///   the other low, the hand read as an open palm (openPalm ≥ 0.5: an open palm facing the camera is what Vision
    ///   reads best; the same arm with a fist, or a hand not read, is a one-arm flex, told by `PoseDescription`)
    /// - bow: the torso short (≤ 0.45) and the head down (headRise ≤ 0.25)
    public var bodyShape: BodyShape? {
        let left = leftArm
        let right = rightArm
        func both(_ test: (Arm) -> Bool) -> Bool { test(left) && test(right) }
        func oneAndOther(_ first: (Arm) -> Bool, _ second: (Arm) -> Bool) -> Bool {
            (first(left) && second(right)) || (first(right) && second(left))
        }
        let torso = self[.torsoLength]

        let upAndOut: (Arm) -> Bool = { arm in
            guard let lift = arm.lift, let out = arm.out, let bend = arm.bend else { return false }
            return lift >= 0.6 && out >= 0.4 && bend <= 0.25 && (arm.cross ?? 0) <= 0.05
        }
        let acrossFace: (Arm) -> Bool = { arm in
            guard let cross = arm.cross, let lift = arm.lift else { return false }
            return cross >= 0.35 && lift >= 0.5 && (arm.head ?? 1) <= 0.5
        }
        if oneAndOther(upAndOut, acrossFace) {
            return .dab
        }
        let drawnBack: (Arm) -> Bool = { arm in
            guard let bend = arm.bend, let lift = arm.lift else { return false }
            return bend >= 0.3 && lift >= 0.3 && lift <= 0.6 && (arm.cross ?? 0) <= 0.3
        }
        if oneAndOther(upAndOut, drawnBack) {
            return .bolt
        }
        let flexing: (Arm) -> Bool = { arm in
            guard let elbowLift = arm.elbowLift, let bend = arm.bend, let lift = arm.lift, let head = arm.head else { return false }
            return elbowLift >= 0.36 && elbowLift <= 0.66 && bend >= 0.38 && lift >= 0.5 && head >= 0.36
        }
        if both(flexing) {
            return .flex
        }
        // The head's centre in wrist-lift units.
        let headLift = self[.headRise].map { (1.5 * $0 + 1.5) / 3.5 }
        let onTopOfHead: (Arm) -> Bool = { arm in
            guard let head = arm.head, let lift = arm.lift, let headLift else { return false }
            return head <= 0.35 && lift >= 0.5 && lift >= headLift + 0.07
        }
        let atTemples: (Arm) -> Bool = { arm in
            guard let head = arm.head, let lift = arm.lift, let out = arm.out else { return false }
            return head <= 0.35 && lift >= 0.5 && out >= 0.09
        }
        if both(onTopOfHead) && !both(atTemples) {
            return .ohNo
        }
        let lowestCrossed = torso == nil ? 0.21 : 0.12
        let crossed: (Arm) -> Bool = { arm in
            guard let cross = arm.cross, let lift = arm.lift, let bend = arm.bend else { return false }
            guard cross >= 0.27 && lift >= lowestCrossed && lift <= 0.45 && bend >= 0.3 else { return false }
            // Without hips in view the body may be at a desk: crossed forearms rise to the wrists, folded ones don't.
            return torso != nil || (arm.forearmRise ?? 0) >= 0.52
        }
        if both(crossed) {
            return .armsCrossed
        }
        let tPosed: (Arm) -> Bool = { arm in
            guard let lift = arm.lift, let out = arm.out, let bend = arm.bend else { return false }
            let elbowLift = arm.elbowLift ?? 0.5
            return lift >= 0.3 && lift <= 0.6 && out >= 0.55 && bend <= 0.2 && elbowLift >= 0.38 && elbowLift <= 0.65
        }
        if both(tPosed) {
            return .tPose
        }
        if let torso, torso >= 0.5 {
            func akimbo(_ arm: Arm, elbowAtLeast minimum: Double) -> Bool {
                guard let elbowOut = arm.elbowOut, let out = arm.out, let lift = arm.lift, let elbowLift = arm.elbowLift else { return false }
                return elbowOut - out >= 0.1 && elbowLift >= minimum && lift <= 0.32
            }
            if both({ akimbo($0, elbowAtLeast: 0.15) }) || oneAndOther({ akimbo($0, elbowAtLeast: 0.17) }, { $0.isLow }) {
                return .handsOnHips
            }
        }
        let straightUp: (Arm) -> Bool = { arm in
            guard let lift = arm.lift, let bend = arm.bend else { return false }
            return lift >= 0.75 && bend <= 0.35 && (arm.head ?? 1) >= 0.35
        }
        if oneAndOther(straightUp, { $0.isLow }) {
            return .pickMe
        }
        let raisedHand: (Arm) -> Bool = { arm in
            guard let lift = arm.lift, let head = arm.head, let out = arm.out, let elbowLift = arm.elbowLift,
                  let bend = arm.bend else { return false }
            return lift >= 0.5 && lift < 0.8 && head >= 0.3 && head <= 0.75 && out >= 0.2 && elbowLift <= 0.6 && bend >= 0.25
        }
        if oneAndOther(raisedHand, { $0.isLow }) && (hand?.openPalm ?? 0) >= 0.5 {
            return .hello
        }
        if let torso, let headRise = self[.headRise], torso <= 0.45 && headRise <= 0.25 {
            return .bow
        }
        return nil
    }

    // MARK: Similarity

    /// Indexed by `Dimension`.
    static let weights: [Double] = [2, 1, 2, 1, 1, 2, 1, 2, 1, 1, 1.5, 0.5, 0.5, 1, 1, 0.5, 0.5, 0.5, 0.5, 0.5]
    /// Per number: similarity falls to 0 at this difference.
    private static let tolerance = 0.25

    /// How alike two poses are on the numbers both have (0...1), and how much of what either shows that is (coverage, 0...1).
    /// Hand signs, and the torso, count only when both have them (a meme cropped at the chest is no other pose). Not
    /// mirrored: see `PoseFeatures.similarity(query:item:)`.
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
                if index != Dimension.torsoLength.rawValue {
                    union += weight
                }
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
