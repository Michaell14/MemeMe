import Foundation

/// The user's resting face, learned silently from calm frames (seven numbers, the resting `FaceShape`, a counter).
public struct RestingBaseline: Codable, Equatable, Sendable {
    public private(set) var neutral: FaceFeatures
    public private(set) var sampleCount: Int
    /// The resting shape the face's cues (`FaceCues`) are read against; nil until a calm frame brought one.
    public private(set) var restShape: FaceShape?

    /// Calm frames before the baseline switches from fast to slow learning.
    private static let warmUpSamples = 30

    /// A calm frame showing a cue at least this strong teaches only at `cueAlpha`, so a held tongue or pucker is barely
    /// learned as the rest, while a rest that no longer fits (the camera moved) still catches up.
    static let calmCueLimit = 0.2
    static let cueAlpha = 0.01

    public init(neutral: FaceFeatures = .populationNeutral, sampleCount: Int = 0, restShape: FaceShape? = nil) {
        self.neutral = neutral
        self.sampleCount = max(0, sampleCount)
        self.restShape = restShape
    }

    /// Updates an EMA from calm frames: a frame is calm when intensity(of:) < (sampleCount < 30 ? 0.25 : 0.08).
    /// alpha = sampleCount < 30 ? 0.2 : 0.05 for the seven numbers and each field of the resting shape, or `cueAlpha`
    /// when one of `shape`'s cues reaches `calmCueLimit`; the first shape is taken as it is. Increments sampleCount for
    /// calm frames only.
    public mutating func observe(_ face: FaceFeatures, shape: FaceShape? = nil) {
        let face = face.clamped()
        let warmingUp = sampleCount < RestingBaseline.warmUpSamples
        let calmLimit = warmingUp ? 0.25 : 0.08
        guard intensity(of: face) < calmLimit else { return }
        let showsCue = (cues(of: shape).strongest?.value ?? 0) >= RestingBaseline.calmCueLimit
        let alpha = showsCue ? RestingBaseline.cueAlpha : (warmingUp ? 0.2 : 0.05)
        if let shape {
            restShape = restShape?.blended(toward: shape, amount: alpha) ?? shape
        }
        let current = neutral.vector
        let target = face.vector
        var blended: [Double] = []
        blended.reserveCapacity(current.count)
        for index in 0..<current.count {
            blended.append(current[index] + alpha * (target[index] - current[index]))
        }
        neutral = FaceFeatures(vector: blended)
        sampleCount += 1
    }

    /// face.vector - neutral.vector
    public func signedDeviation(of face: FaceFeatures) -> [Double] {
        let values = face.vector
        let rest = neutral.vector
        var deviation: [Double] = []
        deviation.reserveCapacity(values.count)
        for index in 0..<values.count {
            deviation.append(values[index] - rest[index])
        }
        return deviation
    }

    /// Per region: min(1, 2 * mean |deviation| over the region's indices)
    public func deviation(of face: FaceFeatures) -> [FaceRegion: Double] {
        let signed = signedDeviation(of: face)
        var result: [FaceRegion: Double] = [:]
        for region in FaceRegion.allCases {
            let indices = FaceFeatures.indices(for: region)
            var total = 0.0
            for index in indices { total += abs(signed[index]) }
            result[region] = min(1, 2 * total / Double(indices.count))
        }
        return result
    }

    /// min(1, 2 * RMS(signedDeviation))
    public func intensity(of face: FaceFeatures) -> Double {
        let signed = signedDeviation(of: face)
        guard !signed.isEmpty else { return 0 }
        var sumOfSquares = 0.0
        for value in signed { sumOfSquares += value * value }
        let rms = (sumOfSquares / Double(signed.count)).squareRoot()
        return min(1, 2 * rms)
    }

    // MARK: Codable (lenient, so older or partial settings keep loading)

    private enum CodingKeys: String, CodingKey {
        case neutral, sampleCount, restShape
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        neutral = container.decodeLenient(FaceFeatures.self, forKey: .neutral, default: FaceFeatures.populationNeutral)
        sampleCount = max(0, container.decodeLenient(Int.self, forKey: .sampleCount, default: 0))
        restShape = container.decodeLenientIfPresent(FaceShape.self, forKey: .restShape)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(neutral, forKey: .neutral)
        try container.encode(sampleCount, forKey: .sampleCount)
        try container.encodeIfPresent(restShape, forKey: .restShape)
    }
}
