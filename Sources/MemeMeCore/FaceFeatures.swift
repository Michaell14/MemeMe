import Foundation

/// Face regions the user can pin and the weights refer to.
public enum FaceRegion: String, CaseIterable, Codable, Hashable, Sendable {
    case brows, eyes, mouth
}

/// Seven normalized facial measurements (all 0...1).
public struct FaceFeatures: Codable, Hashable, Sendable {
    public var browRaise: Double      // 0...1
    public var eyeOpenness: Double    // 0...1
    public var mouthOpenness: Double  // 0...1
    public var mouthWidth: Double     // 0...1
    public var smile: Double          // 0...1; 0.5 = neutral corners, > 0.5 corners up
    public var headTilt: Double       // 0...1 (|roll| / 45°)
    public var gazeSide: Double       // 0...1 (pupils toward one side = side-eye)

    public init(browRaise: Double, eyeOpenness: Double, mouthOpenness: Double, mouthWidth: Double, smile: Double, headTilt: Double, gazeSide: Double) {
        self.browRaise = browRaise
        self.eyeOpenness = eyeOpenness
        self.mouthOpenness = mouthOpenness
        self.mouthWidth = mouthWidth
        self.smile = smile
        self.headTilt = headTilt
        self.gazeSide = gazeSide
    }

    /// Builds features from a `vector`-ordered array; missing entries fall back to `populationNeutral`.
    init(vector values: [Double]) {
        let neutral = FaceFeatures.populationNeutral.vector
        func value(_ index: Int) -> Double { index < values.count ? values[index] : neutral[index] }
        self.init(browRaise: value(0), eyeOpenness: value(1), mouthOpenness: value(2), mouthWidth: value(3),
                  smile: value(4), headTilt: value(5), gazeSide: value(6))
    }

    /// Typical resting face under the extractor's mapping (see FaceFeatureExtractor).
    public static let populationNeutral = FaceFeatures(browRaise: 0.45, eyeOpenness: 0.45, mouthOpenness: 0.05, mouthWidth: 0.45,
                                                       smile: 0.5, headTilt: 0.0, gazeSide: 0.1)

    /// [browRaise, eyeOpenness, mouthOpenness, mouthWidth, smile, headTilt, gazeSide]
    public var vector: [Double] {
        [browRaise, eyeOpenness, mouthOpenness, mouthWidth, smile, headTilt, gazeSide]
    }

    /// Indices into `vector` per region: brows [0], eyes [1, 6], mouth [2, 3, 4].
    public static func indices(for region: FaceRegion) -> [Int] {
        switch region {
        case .brows: return [0]
        case .eyes: return [1, 6]
        case .mouth: return [2, 3, 4]
        }
    }

    /// Every field clamped to 0...1.
    public func clamped() -> FaceFeatures {
        FaceFeatures(browRaise: VectorMath.clampUnit(browRaise),
                     eyeOpenness: VectorMath.clampUnit(eyeOpenness),
                     mouthOpenness: VectorMath.clampUnit(mouthOpenness),
                     mouthWidth: VectorMath.clampUnit(mouthWidth),
                     smile: VectorMath.clampUnit(smile),
                     headTilt: VectorMath.clampUnit(headTilt),
                     gazeSide: VectorMath.clampUnit(gazeSide))
    }
}

/// Coarse body language from the body-pose request.
public struct PoseFeatures: Codable, Hashable, Sendable {
    public var handsRaised: Double   // 0...1 wrists at/above shoulders or near the face
    public var armsSpread: Double    // 0...1 wrist span relative to shoulder width
    public var bodyVisible: Double   // 0...1 confidence that shoulders are in frame

    public init(handsRaised: Double, armsSpread: Double, bodyVisible: Double) {
        self.handsRaised = handsRaised
        self.armsSpread = armsSpread
        self.bodyVisible = bodyVisible
    }

    /// No body language at all.
    public static let none = PoseFeatures(handsRaised: 0, armsSpread: 0, bodyVisible: 0)

    /// max(handsRaised, armsSpread) * bodyVisible, clamped 0...1.
    public var activity: Double {
        VectorMath.clampUnit(max(handsRaised, armsSpread) * bodyVisible)
    }
}

/// One analyzed camera frame (or image) used as a query.
public struct ExpressionSample: Codable, Hashable, Sendable {
    public var face: FaceFeatures?
    public var pose: PoseFeatures?
    public var timestamp: TimeInterval   // seconds, monotonic (CACurrentMediaTime on the app side)
    public var sharpness: Double         // 0...1, 1 when unknown

    public init(face: FaceFeatures?, pose: PoseFeatures? = nil, timestamp: TimeInterval, sharpness: Double = 1) {
        self.face = face
        self.pose = pose
        self.timestamp = timestamp
        self.sharpness = sharpness
    }
}
