import Foundation

/// Per-region importance used by the expression scorer. Never shown to the user.
public struct FeatureWeights: Codable, Hashable, Sendable {
    public var brows: Double
    public var eyes: Double
    public var mouth: Double
    public var pose: Double     // 0...1 share of the face score taken by pose similarity

    /// Weight given to a region the user pinned on the mirror.
    private static let pinnedWeight = 6.0

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

    /// Pinned regions get weight 6.
    public func pinning(_ pins: Set<FaceRegion>) -> FeatureWeights {
        var weights = self
        for region in pins {
            weights[region] = FeatureWeights.pinnedWeight
        }
        return weights
    }
}
