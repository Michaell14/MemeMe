import Foundation

/// The user's resting face, learned silently from calm frames (seven numbers plus a counter).
public struct RestingBaseline: Codable, Equatable, Sendable {
    public private(set) var neutral: FaceFeatures
    public private(set) var sampleCount: Int

    /// Calm frames before the baseline switches from fast to slow learning.
    private static let warmUpSamples = 30

    public init(neutral: FaceFeatures = .populationNeutral, sampleCount: Int = 0) {
        self.neutral = neutral
        self.sampleCount = max(0, sampleCount)
    }

    /// Updates an EMA from calm frames: a frame is calm when intensity(of:) < (sampleCount < 30 ? 0.25 : 0.08).
    /// alpha = sampleCount < 30 ? 0.2 : 0.05. Increments sampleCount for calm frames only.
    public mutating func observe(_ face: FaceFeatures) {
        let face = face.clamped()
        let warmingUp = sampleCount < RestingBaseline.warmUpSamples
        let calmLimit = warmingUp ? 0.25 : 0.08
        guard intensity(of: face) < calmLimit else { return }
        let alpha = warmingUp ? 0.2 : 0.05
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
        case neutral, sampleCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        neutral = container.decodeLenient(FaceFeatures.self, forKey: .neutral, default: FaceFeatures.populationNeutral)
        sampleCount = max(0, container.decodeLenient(Int.self, forKey: .sampleCount, default: 0))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(neutral, forKey: .neutral)
        try container.encode(sampleCount, forKey: .sampleCount)
    }
}
