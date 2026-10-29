import Foundation

/// What the seven `FaceFeatures` don't keep about a face: each eye and each brow on its own, the lips' shape, where the
/// mouth and the pupils sit, and how much tongue shows. Measured in the face's own frame (turned level by the line
/// through the eyes), lengths in eye distances (the distance between the eyes' centers), so a tilted or far face reads
/// like an upright, near one. A field is nil when it couldn't be measured.
public struct FaceShape: Codable, Hashable, Sendable {
    /// Each eye's opening: its contour's area / its width² (about 0.25 open, under 0.1 shut). "Left" and "right" are
    /// Vision's (the person's own); only the difference between them matters.
    public var leftEyeOpen: Double?
    public var rightEyeOpen: Double?
    /// Each brow's height over its eye: the brow's mean height minus the eye's (about 0.3).
    public var leftBrowGap: Double?
    public var rightBrowGap: Double?
    /// The outer lips' width and height (about 0.8 and 0.3 at rest).
    public var lipWidth: Double?
    public var lipHeight: Double?
    /// The inner lips' height: how far the mouth is open (about 0 closed).
    public var lipOpening: Double?
    /// The lower lip's thickness, outer-lip bottom to inner-lip bottom (a tongue over the lip thickens it).
    public var lowerLip: Double?
    /// One mouth corner higher than the other: the left corner's height minus the right one's.
    public var cornerTilt: Double?
    /// The middle of the mouth to one side of the line down the face through the eyes' midpoint. Not read as a cue: a
    /// head turned with the camera above or below the eyes moves it as much as a mouth pulled aside.
    public var mouthShift: Double?
    /// The pupils' mean height in their eyes, in eye heights from the eye's middle (+ up, about 0 looking ahead).
    public var gazeUp: Double?
    /// The share of tongue-colored samples in a band under the lower lip (0...1): redder than the cheeks by more than
    /// half of what the lips are, and not dark. nil when skin and lips can't be told apart (gray, odd light).
    public var tongue: Double?

    public init(leftEyeOpen: Double? = nil, rightEyeOpen: Double? = nil, leftBrowGap: Double? = nil,
                rightBrowGap: Double? = nil, lipWidth: Double? = nil, lipHeight: Double? = nil, lipOpening: Double? = nil,
                lowerLip: Double? = nil, cornerTilt: Double? = nil, mouthShift: Double? = nil, gazeUp: Double? = nil,
                tongue: Double? = nil) {
        self.leftEyeOpen = leftEyeOpen
        self.rightEyeOpen = rightEyeOpen
        self.leftBrowGap = leftBrowGap
        self.rightBrowGap = rightBrowGap
        self.lipWidth = lipWidth
        self.lipHeight = lipHeight
        self.lipOpening = lipOpening
        self.lowerLip = lowerLip
        self.cornerTilt = cornerTilt
        self.mouthShift = mouthShift
        self.gazeUp = gazeUp
        self.tongue = tongue
    }

    /// Every field, in a fixed order, for blending.
    static let fields: [WritableKeyPath<FaceShape, Double?>] = [
        \.leftEyeOpen, \.rightEyeOpen, \.leftBrowGap, \.rightBrowGap, \.lipWidth, \.lipHeight, \.lipOpening,
        \.lowerLip, \.cornerTilt, \.mouthShift, \.gazeUp, \.tongue,
    ]

    /// Moves each field `amount` of the way toward `target`'s (a field this one lacks takes the target's; one the target
    /// lacks stays).
    func blended(toward target: FaceShape, amount: Double) -> FaceShape {
        var result = self
        for field in FaceShape.fields {
            guard let new = target[keyPath: field] else { continue }
            if let old = self[keyPath: field] {
                result[keyPath: field] = old + amount * (new - old)
            } else {
                result[keyPath: field] = new
            }
        }
        return result
    }

    // MARK: Codable (lenient: a field that doesn't decode is nil)

    private enum CodingKeys: String, CodingKey {
        case leftEyeOpen, rightEyeOpen, leftBrowGap, rightBrowGap, lipWidth, lipHeight, lipOpening, lowerLip,
             cornerTilt, mouthShift, gazeUp, tongue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        leftEyeOpen = container.decodeLenientIfPresent(Double.self, forKey: .leftEyeOpen)
        rightEyeOpen = container.decodeLenientIfPresent(Double.self, forKey: .rightEyeOpen)
        leftBrowGap = container.decodeLenientIfPresent(Double.self, forKey: .leftBrowGap)
        rightBrowGap = container.decodeLenientIfPresent(Double.self, forKey: .rightBrowGap)
        lipWidth = container.decodeLenientIfPresent(Double.self, forKey: .lipWidth)
        lipHeight = container.decodeLenientIfPresent(Double.self, forKey: .lipHeight)
        lipOpening = container.decodeLenientIfPresent(Double.self, forKey: .lipOpening)
        lowerLip = container.decodeLenientIfPresent(Double.self, forKey: .lowerLip)
        cornerTilt = container.decodeLenientIfPresent(Double.self, forKey: .cornerTilt)
        mouthShift = container.decodeLenientIfPresent(Double.self, forKey: .mouthShift)
        gazeUp = container.decodeLenientIfPresent(Double.self, forKey: .gazeUp)
        tongue = container.decodeLenientIfPresent(Double.self, forKey: .tongue)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(leftEyeOpen, forKey: .leftEyeOpen)
        try container.encodeIfPresent(rightEyeOpen, forKey: .rightEyeOpen)
        try container.encodeIfPresent(leftBrowGap, forKey: .leftBrowGap)
        try container.encodeIfPresent(rightBrowGap, forKey: .rightBrowGap)
        try container.encodeIfPresent(lipWidth, forKey: .lipWidth)
        try container.encodeIfPresent(lipHeight, forKey: .lipHeight)
        try container.encodeIfPresent(lipOpening, forKey: .lipOpening)
        try container.encodeIfPresent(lowerLip, forKey: .lowerLip)
        try container.encodeIfPresent(cornerTilt, forKey: .cornerTilt)
        try container.encodeIfPresent(mouthShift, forKey: .mouthShift)
        try container.encodeIfPresent(gazeUp, forKey: .gazeUp)
        try container.encodeIfPresent(tongue, forKey: .tongue)
    }
}

/// Deliberate faces the seven features can't tell apart from the plain ones they resemble, each 0 (not there) ... 1
/// (clearly there): read from a `FaceShape` against the person's own resting shape when there is one (the camera),
/// else against fixed values (an image in the library).
public struct FaceCues: Hashable, Sendable {
    public enum Cue: String, CaseIterable, Codable, Hashable, Sendable {
        case tongueOut, wink, raisedBrow, pucker, smirk, eyeRoll

        /// The word the cue gives the search.
        public var mood: Mood {
            switch self {
            case .tongueOut: return .tongueOut
            case .wink: return .wink
            case .raisedBrow: return .raisedEyebrow
            case .pucker: return .duckFace
            case .smirk: return .smirk
            case .eyeRoll: return .eyeRoll
            }
        }
    }

    /// A cue at least this strong names the mood and is an expression of its own.
    public static let clear = 0.5

    /// One value per `Cue.allCases`, in that order.
    public private(set) var values: [Double]

    public static let none = FaceCues(values: Array(repeating: 0, count: Cue.allCases.count))

    private init(values: [Double]) {
        self.values = values
    }

    /// Each cue from `shape`, against `rest` (the person's resting shape) where it has the fields a cue needs, else
    /// against fixed values. Formulas (clamp to 0...1; lengths in eye distances; r = rest):
    /// - tongueOut: (tongue − r.tongue − 0.12) / 0.25, + 0.3 when the lower lip is ≥ 1.6 × r.lowerLip and the tongue
    ///   share grew ≥ 0.06; without a rest (tongue − 0.2) / 0.25
    /// - wink: with each eye's opening over its rest, when the lower is ≤ 0.55 and the higher ≥ 0.5 (a smile narrows the
    ///   open eye too): (higher − lower − 0.3) / 0.4; without a rest (ln(higher eye / lower eye) − 0.7) / 0.7
    /// - raisedBrow: (|(leftBrowGap − rightBrowGap) − rest's| − 0.05) / 0.1; without a rest (|difference| − 0.07) / 0.1
    /// - pucker (duck face, kissy lips; mouth closed, lipOpening ≤ 0.12): (1 − lipWidth / r.lipWidth − 0.1) / 0.15;
    ///   without a rest (0.7 − lipWidth) / 0.15 when lipHeight / lipWidth ≥ 0.4
    /// - smirk (one corner up): (|cornerTilt − r| − 0.05) / 0.1; without a rest (|cornerTilt| − 0.07) / 0.1
    /// - eyeRoll: (gazeUp − r.gazeUp − 0.12) / 0.15; without a rest (gazeUp − 0.18) / 0.15
    public init(shape: FaceShape, rest: FaceShape?) {
        func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
        var values: [Double] = []
        for cue in Cue.allCases {
            switch cue {
            case .tongueOut:
                guard let tongue = shape.tongue else {
                    values.append(0)
                    continue
                }
                if let restTongue = rest?.tongue {
                    var value = clamp((tongue - restTongue - 0.12) / 0.25)
                    if let lip = shape.lowerLip, let restLip = rest?.lowerLip, restLip > 0,
                       lip >= 1.6 * restLip, tongue - restTongue >= 0.06 {
                        value = clamp(value + 0.3)
                    }
                    values.append(value)
                } else {
                    values.append(clamp((tongue - 0.2) / 0.25))
                }
            case .wink:
                guard let left = shape.leftEyeOpen, let right = shape.rightEyeOpen, left > 0 || right > 0 else {
                    values.append(0)
                    continue
                }
                if let restLeft = rest?.leftEyeOpen, let restRight = rest?.rightEyeOpen, restLeft > 0, restRight > 0 {
                    let leftShare = left / restLeft
                    let rightShare = right / restRight
                    let lower = min(leftShare, rightShare)
                    let higher = max(leftShare, rightShare)
                    values.append(lower <= 0.55 && higher >= 0.5 ? clamp((higher - lower - 0.3) / 0.4) : 0)
                } else {
                    let lower = max(min(left, right), 0.005)
                    let higher = max(left, right)
                    values.append(clamp((log(higher / lower) - 0.7) / 0.7))
                }
            case .raisedBrow:
                guard let left = shape.leftBrowGap, let right = shape.rightBrowGap else {
                    values.append(0)
                    continue
                }
                if let restLeft = rest?.leftBrowGap, let restRight = rest?.rightBrowGap {
                    values.append(clamp((abs((left - right) - (restLeft - restRight)) - 0.05) / 0.1))
                } else {
                    values.append(clamp((abs(left - right) - 0.07) / 0.1))
                }
            case .pucker:
                guard let width = shape.lipWidth, width > 0, (shape.lipOpening ?? 0) <= 0.12 else {
                    values.append(0)
                    continue
                }
                if let restWidth = rest?.lipWidth, restWidth > 0 {
                    values.append(clamp((1 - width / restWidth - 0.1) / 0.15))
                } else if let height = shape.lipHeight, height / width >= 0.4 {
                    values.append(clamp((0.7 - width) / 0.15))
                } else {
                    values.append(0)
                }
            case .smirk:
                guard let tilt = shape.cornerTilt else {
                    values.append(0)
                    continue
                }
                values.append(rest?.cornerTilt.map { clamp((abs(tilt - $0) - 0.05) / 0.1) } ?? clamp((abs(tilt) - 0.07) / 0.1))
            case .eyeRoll:
                guard let up = shape.gazeUp else {
                    values.append(0)
                    continue
                }
                values.append(rest?.gazeUp.map { clamp((up - $0 - 0.12) / 0.15) } ?? clamp((up - 0.18) / 0.15))
            }
        }
        self.init(values: values)
    }

    public subscript(_ cue: Cue) -> Double {
        guard let index = Cue.allCases.firstIndex(of: cue), index < values.count else { return 0 }
        return values[index]
    }

    /// The strongest cue above 0 (the first in `Cue.allCases` on a tie); nil when none shows.
    public var strongest: (cue: Cue, value: Double)? {
        var best: (cue: Cue, value: Double)?
        for (index, cue) in Cue.allCases.enumerated() where index < values.count && values[index] > 0 {
            if let current = best, values[index] <= current.value { continue }
            best = (cue, values[index])
        }
        return best
    }

    /// The cue clear enough (≥ `clear`) to name the mood; nil when none is.
    public var clearCue: Cue? {
        guard let strongest, strongest.value >= FaceCues.clear else { return nil }
        return strongest.cue
    }
}

extension RestingBaseline {
    /// `shape`'s cues against the resting shape (fixed values for the fields it hasn't learned yet); none without a
    /// shape.
    public func cues(of shape: FaceShape?) -> FaceCues {
        guard let shape else { return .none }
        return FaceCues(shape: shape, rest: restShape)
    }
}
