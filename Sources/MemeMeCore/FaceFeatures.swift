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

/// Body language from the body and hand pose requests.
public struct PoseFeatures: Codable, Hashable, Sendable {
    public var handsRaised: Double   // 0...1 wrists at/above shoulders or near the face
    public var armsSpread: Double    // 0...1 wrist span relative to shoulder width
    public var bodyVisible: Double   // 0...1 confidence that shoulders are in frame
    /// The pose in detail (arms, elbows, hand sign); nil for items analyzed before it existed or when it couldn't be measured.
    public var descriptor: PoseDescriptor?

    public init(handsRaised: Double, armsSpread: Double, bodyVisible: Double, descriptor: PoseDescriptor? = nil) {
        self.handsRaised = handsRaised
        self.armsSpread = armsSpread
        self.bodyVisible = bodyVisible
        self.descriptor = descriptor
    }

    /// Measures a body (and the strongest sign of its hands).
    public init(joints: BodyJoints, hand: HandShape? = nil) {
        let leftShoulder = joints[.leftShoulder]
        let rightShoulder = joints[.rightShoulder]
        let shoulderLine = PosePoint.mean([leftShoulder, rightShoulder].compactMap { $0 })?.y
        var shoulderWidth: Double?
        if let left = leftShoulder, let right = rightShoulder, abs(left.x - right.x) > 0.01 {
            shoulderWidth = abs(left.x - right.x)
        }
        let nose = joints[.nose]
        func raised(_ wrist: PosePoint?) -> Double {
            guard let wrist else { return 0 }
            if let line = shoulderLine, wrist.y >= line { return 1 }
            if let nose, let width = shoulderWidth, wrist.distance(to: nose) <= 0.6 * width { return 0.8 }
            return 0
        }
        let leftWrist = joints[.leftWrist]
        let rightWrist = joints[.rightWrist]
        var spread = 0.0
        if let left = leftWrist, let right = rightWrist, let width = shoulderWidth {
            spread = VectorMath.clampUnit((abs(left.x - right.x) / width - 1) / 1.5)
        }
        self.init(handsRaised: max(raised(leftWrist), raised(rightWrist)),
                  armsSpread: spread,
                  bodyVisible: joints.shoulderConfidence,
                  descriptor: PoseDescriptor(joints, hand: hand))
    }

    /// No body language at all.
    public static let none = PoseFeatures(handsRaised: 0, armsSpread: 0, bodyVisible: 0)

    /// max(handsRaised, armsSpread) * bodyVisible, clamped 0...1 (the measure before `descriptor` existed).
    public var activity: Double {
        VectorMath.clampUnit(max(handsRaised, armsSpread) * bodyVisible)
    }

    /// 0 (arms at rest or not seen) … 1 (a clear gesture): from the descriptor, else `activity`.
    public var gestureStrength: Double {
        descriptor?.gestureStrength ?? activity
    }

    /// Whether the arms (or a hand) were seen, so the pose says something; a face with shoulders doesn't.
    /// Poses measured the old way: whether the shoulders were seen.
    public var showsArms: Bool {
        descriptor?.showsArms ?? (bodyVisible > 0)
    }

    /// How well an item's pose matches the query's (0...1), g = gesture strength:
    /// - the item's arms weren't seen: unknown, so 1 − 0.7 × the query's g (neutral without a gesture, below a
    ///   matching pose when the user makes one);
    /// - both at rest (g ≤ 0.1), or the query not described in detail: 1 − |g difference| ("level"); the comparisons
    ///   below fade in from level as the stronger of the two goes from 0.1 to 0.4;
    /// - the item measured the old way: unknown against a query described in detail;
    /// - both described: on the numbers both show, shape similarity × (0.5 + 0.5 × level), so a different gesture or
    ///   arms at rest don't pass for the user's gesture; what only one side shows counts as level (the query's arms
    ///   out of frame ≈ arms down). The better of the item as-is and mirrored.
    public static func similarity(query: PoseFeatures?, item: PoseFeatures?) -> Double {
        let queryStrength = query?.gestureStrength ?? 0
        let unknown = 1 - 0.7 * queryStrength
        guard let item, item.showsArms else { return unknown }
        let itemStrength = item.gestureStrength
        let level = 1 - abs(queryStrength - itemStrength)
        // Two poses at rest match whatever their shape (arms hanging, on a desk, in the lap): the shape comparison
        // fades in as either pose becomes a gesture (strength 0.1 → 0.4), so a little hand height never jumps the order.
        let shaped = VectorMath.clampUnit((max(queryStrength, itemStrength) - 0.1) / 0.3)
        guard shaped > 0 else { return level }
        // An item measured the old way can't be compared with a pose described in detail (its "activity" only knew
        // raised or spread wrists): unknown until the pose pass reads it again.
        guard let itemPose = item.descriptor else {
            return query?.descriptor == nil ? level : (1 - shaped) * level + shaped * unknown
        }
        guard let queryPose = query?.descriptor else { return level }
        func blended(_ match: (similarity: Double, coverage: Double)) -> Double {
            match.coverage * match.similarity * (0.5 + 0.5 * level) + (1 - match.coverage) * level
        }
        let direct = blended(PoseDescriptor.compare(queryPose, itemPose))
        let mirrored = blended(PoseDescriptor.compare(queryPose, itemPose.mirrored))
        return VectorMath.clampUnit((1 - shaped) * level + shaped * max(direct, mirrored))
    }

    // MARK: Codable (lenient, so poses stored by earlier versions keep loading)

    private enum CodingKeys: String, CodingKey {
        case handsRaised, armsSpread, bodyVisible, descriptor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        handsRaised = container.decodeLenient(Double.self, forKey: .handsRaised, default: 0)
        armsSpread = container.decodeLenient(Double.self, forKey: .armsSpread, default: 0)
        bodyVisible = container.decodeLenient(Double.self, forKey: .bodyVisible, default: 0)
        descriptor = container.decodeLenientIfPresent(PoseDescriptor.self, forKey: .descriptor)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(handsRaised, forKey: .handsRaised)
        try container.encode(armsSpread, forKey: .armsSpread)
        try container.encode(bodyVisible, forKey: .bodyVisible)
        try container.encodeIfPresent(descriptor, forKey: .descriptor)
    }
}

/// One analyzed camera frame (or image) used as a query.
public struct ExpressionSample: Codable, Hashable, Sendable {
    public var face: FaceFeatures?
    public var pose: PoseFeatures?
    /// The face's details beyond the seven features (`FaceShape`), read into `FaceCues` against the resting shape.
    public var shape: FaceShape?
    public var timestamp: TimeInterval   // seconds, monotonic (CACurrentMediaTime on the app side)
    public var sharpness: Double         // 0...1, 1 when unknown

    public init(face: FaceFeatures?, pose: PoseFeatures? = nil, shape: FaceShape? = nil, timestamp: TimeInterval,
                sharpness: Double = 1) {
        self.face = face
        self.pose = pose
        self.shape = shape
        self.timestamp = timestamp
        self.sharpness = sharpness
    }
}
