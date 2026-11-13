import Foundation

/// The benchmarked "Hybrid: CLIP B/32 + emotion" matcher (the midterm report; `scripts/hybrid/bench_reference.py`).
///
///     visual     = (q_full · m.clip_full + 1) / 2
///     expression = prob_sim(q_emo, m.emo) if m.has_face else prob_sim(q_zs, m.zs)
///     score      = (1 − w) · visual + w · expression,   w = `expressionWeight`
///
/// `q_full` is CLIP of the held frame, `q_emo` HSEmotion of its face crop, `q_zs` CLIP zero-shot of the crop.
public enum HybridMatcher {
    /// w: the expression's share of the score, tuned on the benchmark's dev set.
    public static let expressionWeight = 0.2
    /// Zero-shot logits are `zeroShotScale · e · Tᵀ` (CLIP's logit scale).
    public static let zeroShotScale = 100.0
    public static let embeddingSize = 512

    /// 1 − total variation distance between two probability vectors (0...1); 0 when the sizes differ.
    public static func probSim(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var total = 0.0
        for i in 0..<a.count { total += abs(a[i] - b[i]) }
        return 1 - 0.5 * total
    }

    /// Cosine of two L2-normalized embeddings mapped to 0...1; 0.5 when the sizes differ.
    public static func visual(_ query: [Float], _ item: [Float]) -> Double {
        guard query.count == item.count, !query.isEmpty else { return 0.5 }
        return (dot(query, item) + 1) / 2
    }

    public static func expression(query: HybridQuery, entry: HybridIndexEntry) -> Double {
        if entry.hasFace, let emo = entry.emo {
            return probSim(query.emotion, emo)
        }
        return probSim(query.zeroShot, entry.zs)
    }

    public static func score(query: HybridQuery, entry: HybridIndexEntry, weight: Double = expressionWeight) -> Double {
        (1 - weight) * visual(query.full, entry.clipFull) + weight * expression(query: query, entry: entry)
    }

    /// Every entry scored, best first (ties keep the order given).
    public static func rank(_ entries: [HybridIndexEntry], query: HybridQuery) -> [(entry: HybridIndexEntry, score: Double)] {
        entries.enumerated()
            .map { (offset: $0.offset, entry: $0.element, score: score(query: query, entry: $0.element)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            .map { (entry: $0.entry, score: $0.score) }
    }

    public static func softmax(_ logits: [Double]) -> [Double] {
        guard let top = logits.max(), top.isFinite else { return logits.map { _ in 1 / Double(max(logits.count, 1)) } }
        let e = logits.map { Foundation.exp($0 - top) }
        let sum = e.reduce(0, +)
        return e.map { $0 / sum }
    }

    public static func l2Normalized(_ v: [Float]) -> [Float] {
        var sum = 0.0
        for x in v { sum += Double(x) * Double(x) }
        let norm = sum.squareRoot()
        guard norm > 1e-12 else { return v }
        return v.map { Float(Double($0) / norm) }
    }

    /// softmax(scale · e · Tᵀ) over the prompts' classes.
    public static func zeroShot(embedding: [Float], prompts: EmotionPrompts) -> [Double] {
        softmax(prompts.embeddings.map { prompts.scale * dot(embedding, $0) })
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Double {
        var sum: Float = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for i in 0..<min(pa.count, pb.count) { sum += pa[i] * pb[i] }
            }
        }
        return Double(sum)
    }
}

/// What a held face is searched with.
public struct HybridQuery: Equatable, Sendable {
    public var full: [Float]        // CLIP of the whole frame, L2-normalized
    public var emotion: [Double]    // HSEmotion probabilities of the face crop (`HSEmotionClass` order)
    public var zeroShot: [Double]   // CLIP zero-shot probabilities of the crop (`EmotionPrompts.classes` order)
    public init(full: [Float], emotion: [Double], zeroShot: [Double]) {
        self.full = full
        self.emotion = emotion
        self.zeroShot = zeroShot
    }
}

/// HSEmotion's 8 classes, in the model's output order.
public enum HSEmotionClass: Int, CaseIterable, Codable, Sendable {
    case anger, contempt, disgust, fear, happiness, neutral, sadness, surprise

    /// The word shown for the class (the app's own words where it had them).
    public var mood: Mood {
        switch self {
        case .surprise: return .shocked
        case .happiness: return .happy
        case .anger: return .angry
        case .sadness: return .sad
        case .disgust: return .disgusted
        case .fear: return .scared
        case .neutral, .contempt: return .unimpressed
        }
    }

    public var name: String {
        switch self {
        case .anger: return "anger"
        case .contempt: return "contempt"
        case .disgust: return "disgust"
        case .fear: return "fear"
        case .happiness: return "happiness"
        case .neutral: return "neutral"
        case .sadness: return "sadness"
        case .surprise: return "surprise"
        }
    }

    /// The most probable class; nil unless there are 8 probabilities.
    public static func top(of probabilities: [Double]) -> HSEmotionClass? {
        guard probabilities.count == allCases.count,
              let best = probabilities.indices.max(by: { probabilities[$0] < probabilities[$1] }) else { return nil }
        return HSEmotionClass(rawValue: best)
    }
}

/// The 7 zero-shot prompts' text embeddings (`Resources/Hybrid/emotion_prompts.json`, made by
/// `scripts/hybrid/convert_models.py` with the same CLIP's text tower).
public struct EmotionPrompts: Codable, Equatable, Sendable {
    public var classes: [String]
    public var prompts: [String]
    public var scale: Double
    public var embeddings: [[Float]]
    public init(classes: [String], prompts: [String], scale: Double = HybridMatcher.zeroShotScale, embeddings: [[Float]]) {
        self.classes = classes
        self.prompts = prompts
        self.scale = scale
        self.embeddings = embeddings
    }

    public static let expectedClasses = ["anger", "disgust", "fear", "happiness", "neutral", "sadness", "surprise"]

    /// nil unless the file has the 7 classes in order, each with a 512-number embedding.
    public static func load(from url: URL) -> EmotionPrompts? {
        guard let data = try? Data(contentsOf: url),
              let prompts = try? JSONDecoder().decode(EmotionPrompts.self, from: data),
              prompts.classes == expectedClasses,
              prompts.embeddings.count == expectedClasses.count,
              prompts.embeddings.allSatisfy({ $0.count == HybridMatcher.embeddingSize }) else { return nil }
        return prompts
    }
}

/// When the hybrid matcher decides a held face's search, and which word it shows.
public enum HybridRouting {
    /// Face details the hybrid can't represent (CLIP and the emotion model don't see them): held for
    /// `cueHoldDuration`, they keep the rule-based ranker. A smirk and one raised brow always go to the hybrid.
    public static let routedCues: Set<FaceCues.Cue> = [.tongueOut, .wink, .pucker, .eyeRoll]
    /// The normal hold (`PeakHoldConfig.holdDuration`).
    public static let cueHoldDuration: TimeInterval = PeakHoldConfig().holdDuration

    /// The hybrid ranks the search unless a pose is clear (with a word of its own or described), or one of
    /// `routedCues` is clear and was held (`cueHeld`), or the frame has no face or no emotion reading.
    public static func usesHybrid(_ sample: ExpressionSample, baseline: RestingBaseline, cueHeld: Bool = true) -> Bool {
        guard sample.face != nil, let emotion = sample.emotion, emotion.count == HSEmotionClass.allCases.count else {
            return false
        }
        if PoseBadge.of(sample, baseline: baseline) != nil { return false }
        if let cue = baseline.cues(of: sample.shape).clearCue, routedCues.contains(cue), cueHeld { return false }
        return true
    }

    /// The word for a sample: a clear pose's or face detail's word (`MoodClassifier`) whatever ranks it, else
    /// HSEmotion's top class when the hybrid handles it, else `MoodClassifier`'s.
    public static func mood(for sample: ExpressionSample, baseline: RestingBaseline, hybrid: Bool,
                            cueHeld: Bool = true) -> Mood {
        let rules = MoodClassifier.mood(for: sample.face, pose: sample.pose, shape: sample.shape, baseline: baseline)
        guard hybrid, usesHybrid(sample, baseline: baseline, cueHeld: cueHeld),
              PoseBadge.of(sample, baseline: baseline) == nil, baseline.cues(of: sample.shape).clearCue == nil,
              let emotion = sample.emotion, let top = HSEmotionClass.top(of: emotion) else { return rules }
        return top.mood
    }
}

/// The clear face detail of each recent camera frame, to tell a held one from a single frame's.
public struct CueHistory: Sendable {
    public static let window: TimeInterval = 3
    /// A frame's worth of slack: a hold of `duration` spans about `duration` − one frame between its first and last.
    public static let frameSlack: TimeInterval = 0.11
    private var frames: [(timestamp: TimeInterval, cue: FaceCues.Cue?)] = []

    public init() {}

    public mutating func observe(_ cue: FaceCues.Cue?, at timestamp: TimeInterval) {
        frames.append((timestamp, cue))
        frames.removeAll { timestamp - $0.timestamp > CueHistory.window }
    }

    public mutating func reset() { frames.removeAll() }

    /// Whether `cue` showed in an unbroken run of frames around `timestamp` lasting at least `duration`.
    public func isHeld(_ cue: FaceCues.Cue, at timestamp: TimeInterval,
                       for duration: TimeInterval = HybridRouting.cueHoldDuration) -> Bool {
        guard let i = frames.firstIndex(where: { abs($0.timestamp - timestamp) < 0.001 }), frames[i].cue == cue else {
            return false
        }
        var first = i, last = i
        while first > 0, frames[first - 1].cue == cue { first -= 1 }
        while last + 1 < frames.count, frames[last + 1].cue == cue { last += 1 }
        return frames[last].timestamp - frames[first].timestamp >= duration - CueHistory.frameSlack
    }
}

/// Which ranker a held face uses (settings.json `matchingModel`).
public enum MatchingModel: String, Codable, CaseIterable, Sendable {
    case hybrid    // the benchmarked CLIP B/32 + emotion model (default)
    case classic   // the face-geometry ranker from before (`Ranker.expressionScore`)
}
