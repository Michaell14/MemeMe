import Foundation

/// The one word a face is mapped to on-device; only this word is ever sent to GIPHY.
public enum Mood: String, CaseIterable, Codable, Hashable, Sendable {
    case shocked, screaming, laughing, happy, smug, sideEye, crying, sad, angry, confused, unimpressed, nervous, excited, reaction

    /// GIPHY query, e.g. "shocked reaction", "side eye", "unimpressed", "reaction"
    public var searchQuery: String {
        switch self {
        case .sideEye: return "side eye"
        case .unimpressed: return "unimpressed"
        case .reaction: return "reaction"
        default: return label + " reaction"
        }
    }

    /// Human word, e.g. "shocked", "side eye"
    public var label: String {
        switch self {
        case .shocked: return "shocked"
        case .screaming: return "screaming"
        case .laughing: return "laughing"
        case .happy: return "happy"
        case .smug: return "smug"
        case .sideEye: return "side eye"
        case .crying: return "crying"
        case .sad: return "sad"
        case .angry: return "angry"
        case .confused: return "confused"
        case .unimpressed: return "unimpressed"
        case .nervous: return "nervous"
        case .excited: return "excited"
        case .reaction: return "reaction"
        }
    }

    /// Moods prefetched in the background, most common first.
    public static let prefetchOrder: [Mood] = [.shocked, .laughing, .sideEye, .unimpressed, .crying, .smug, .happy, .screaming, .confused, .angry]
}

public enum MoodClassifier {
    /// Rules in this order (d = signed deviation from baseline.neutral; o = face.mouthOpenness; s = face.smile - 0.5):
    /// 1. face nil → .reaction
    /// 2. pose.handsRaised ≥ 0.5 && o ≥ 0.35 → .screaming;  pose.activity ≥ 0.5 && s > 0.08 → .excited
    /// 3. o ≥ 0.45 && s ≤ 0.05 && (d.eye ≥ 0.1 || d.brow ≥ 0.1) → o ≥ 0.7 ? .screaming : .shocked
    /// 4. o ≥ 0.2 && s > 0.08 → .laughing
    /// 5. d.eye ≥ 0.15 && d.brow ≥ 0.12 → .shocked
    /// 6. face.gazeSide ≥ 0.45 → .sideEye
    /// 7. s > 0.12 → d.eye < -0.12 ? .smug : .happy
    /// 8. s < -0.1 → d.brow > 0.05 ? .crying : .sad
    /// 9. d.brow > 0.12 && s < 0 → .nervous
    /// 10. d.brow < -0.12 → .angry
    /// 11. face.headTilt ≥ 0.35 → .confused
    /// 12. else → .unimpressed
    public static func mood(for face: FaceFeatures?, pose: PoseFeatures?, baseline: RestingBaseline) -> Mood {
        guard let face = face else { return .reaction }
        let deviation = baseline.signedDeviation(of: face)
        let browDeviation = deviation[0]   // browRaise
        let eyeDeviation = deviation[1]    // eyeOpenness
        let open = face.mouthOpenness
        let smile = face.smile - 0.5

        if let pose = pose {
            if pose.handsRaised >= 0.5 && open >= 0.35 { return .screaming }
            if pose.activity >= 0.5 && smile > 0.08 { return .excited }
        }
        if open >= 0.45 && smile <= 0.05 && (eyeDeviation >= 0.1 || browDeviation >= 0.1) {
            return open >= 0.7 ? .screaming : .shocked
        }
        if open >= 0.2 && smile > 0.08 { return .laughing }
        if eyeDeviation >= 0.15 && browDeviation >= 0.12 { return .shocked }
        if face.gazeSide >= 0.45 { return .sideEye }
        if smile > 0.12 { return eyeDeviation < -0.12 ? .smug : .happy }
        if smile < -0.1 { return browDeviation > 0.05 ? .crying : .sad }
        if browDeviation > 0.12 && smile < 0 { return .nervous }
        if browDeviation < -0.12 { return .angry }
        if face.headTilt >= 0.35 { return .confused }
        return .unimpressed
    }
}
