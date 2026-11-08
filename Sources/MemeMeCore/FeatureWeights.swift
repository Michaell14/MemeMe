import Foundation

/// Per-region importance used by the expression scorer. The mirror shows it as a glow on each part, and the face
/// editor lets you set it (`FaceEditSession`).
public struct FeatureWeights: Codable, Hashable, Sendable {
    public var brows: Double
    public var eyes: Double
    public var mouth: Double
    public var pose: Double     // 0...1 share of the face score taken by pose similarity

    public init(brows: Double = 1, eyes: Double = 1, mouth: Double = 1, pose: Double = 0.15) {
        self.brows = brows
        self.eyes = eyes
        self.mouth = mouth
        self.pose = pose
    }

    public static let uniform = FeatureWeights()

    public subscript(region: FaceRegion) -> Double {
        get {
            switch region {
            case .brows: return brows
            case .eyes: return eyes
            case .mouth: return mouth
            }
        }
        set {
            switch region {
            case .brows: brows = newValue
            case .eyes: eyes = newValue
            case .mouth: mouth = newValue
            }
        }
    }

    /// m = max deviation; if m < 0.05 → all 1, else 1 + 2 * d / m per region. pose = min(0.6, 0.05 + 0.55 * poseStrength)
    /// (`PoseFeatures.gestureStrength`): a plain face leaves the pose a small say, a clear gesture most of it.
    public static func automatic(deviation: [FaceRegion: Double], poseStrength: Double) -> FeatureWeights {
        var weights = FeatureWeights()
        var largest = 0.0
        for region in FaceRegion.allCases {
            largest = max(largest, deviation[region] ?? 0)
        }
        if largest >= 0.05 {
            for region in FaceRegion.allCases {
                let regionDeviation = max(0, deviation[region] ?? 0)
                weights[region] = 1 + 2 * regionDeviation / largest
            }
        }
        let strength = VectorMath.clampUnit(poseStrength)
        weights.pose = min(0.6, 0.05 + 0.55 * strength)
        return weights
    }

    /// The face editor's weights in place of these for the regions given (0 ignores a region; the ranker then leaves
    /// it out). The pose's share stays.
    public func overriding(_ regions: [FaceRegion: Double]) -> FeatureWeights {
        var weights = self
        for (region, value) in regions {
            weights[region] = value.isFinite ? max(0, value) : 0
        }
        return weights
    }

    /// What the weights say in words, under the mirror: "mostly your brows", "your whole face", "your eyes and mouth"
    /// (some ignored, the rest alike), "only your mouth", "mostly your mouth · ignoring your brows", or "every part
    /// ignored". Parts within 0.5 of each other count alike; 0.05 or less is ignored.
    public static func summary(of weights: [FaceRegion: Double]) -> String {
        let active = FaceRegion.allCases.filter { (weights[$0] ?? 0) > 0.05 }
        let ignored = FaceRegion.allCases.filter { (weights[$0] ?? 0) <= 0.05 }
        guard let strongest = active.max(by: { (weights[$0] ?? 0) < (weights[$1] ?? 0) }) else {
            return "every part ignored"
        }
        if active.count == 1 {
            return ignored.isEmpty ? "your " + strongest.rawValue : "only your " + strongest.rawValue
        }
        let values = active.map { weights[$0] ?? 0 }
        let spread = (values.max() ?? 0) - (values.min() ?? 0)
        if spread < 0.5 {
            return ignored.isEmpty ? "your whole face" : "your " + list(active)
        }
        let main = "mostly your " + strongest.rawValue
        return ignored.isEmpty ? main : main + " · ignoring your " + list(ignored)
    }

    /// "brows", "brows and mouth", "brows, eyes and mouth"
    private static func list(_ regions: [FaceRegion]) -> String {
        let names = regions.map { $0.rawValue }
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}
