import Foundation

/// The one word a face is mapped to on-device; only this word is ever sent to GIPHY.
public enum Mood: String, CaseIterable, Codable, Hashable, Sendable {
    case shocked, screaming, laughing, happy, smug, sideEye, crying, sad, angry, confused, unimpressed, nervous, excited, reaction
    // Body language
    case celebrate, facepalm, mindBlown, shrug, thumbsUp, pointing, clapping

    /// GIPHY query, e.g. "shocked reaction", "side eye", "unimpressed", "reaction", "mind blown"
    public var searchQuery: String {
        switch self {
        case .sideEye: return "side eye"
        case .unimpressed: return "unimpressed"
        case .reaction: return "reaction"
        case .celebrate, .facepalm, .mindBlown, .shrug, .thumbsUp, .pointing, .clapping: return label
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
        case .celebrate: return "celebrate"
        case .facepalm: return "facepalm"
        case .mindBlown: return "mind blown"
        case .shrug: return "shrug"
        case .thumbsUp: return "thumbs up"
        case .pointing: return "pointing"
        case .clapping: return "clapping"
        }
    }
}

public enum MoodClassifier {
    /// Rules in this order (d = signed deviation from baseline.neutral; o = face.mouthOpenness; s = face.smile - 0.5):
    /// 1. a pose described in detail (`PoseDescriptor`) with body language that has its own word → that word (`gestureMood`)
    /// 2. face nil → .reaction
    /// 3. only for poses measured the old way (no descriptor):
    ///    pose.handsRaised ≥ 0.5 && o ≥ 0.35 → .screaming;  pose.activity ≥ 0.5 && s > 0.08 → .excited
    /// 4. o ≥ 0.45 && s ≤ 0.05 && (d.eye ≥ 0.1 || d.brow ≥ 0.1) → o ≥ 0.7 ? .screaming : .shocked
    /// 5. o ≥ 0.2 && s > 0.08 → .laughing
    /// 6. d.eye ≥ 0.15 && d.brow ≥ 0.12 → .shocked
    /// 7. face.gazeSide ≥ 0.45 → .sideEye
    /// 8. s > 0.12 → d.eye < -0.12 ? .smug : .happy
    /// 9. s < -0.1 → d.brow > 0.05 ? .crying : .sad
    /// 10. d.brow > 0.12 && s < 0 → .nervous
    /// 11. d.brow < -0.12 → .angry
    /// 12. face.headTilt ≥ 0.35 → .confused
    /// 13. else → .unimpressed
    public static func mood(for face: FaceFeatures?, pose: PoseFeatures?, baseline: RestingBaseline) -> Mood {
        if let descriptor = pose?.descriptor, let gesture = gestureMood(descriptor, face: face, baseline: baseline) {
            return gesture
        }
        guard let face = face else { return .reaction }
        let deviation = baseline.signedDeviation(of: face)
        let browDeviation = deviation[0]   // browRaise
        let eyeDeviation = deviation[1]    // eyeOpenness
        let open = face.mouthOpenness
        let smile = face.smile - 0.5

        if let pose = pose, pose.descriptor == nil {
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

    /// Body language that has its own word, or nil. Each rule needs the joints it reads (a missing one never matches);
    /// in this order:
    /// 1. hand sign: thumbs up ≥ 0.7 → .thumbsUp; pointing ≥ 0.7 → .pointing
    /// 2. both arms up (wrist lift ≥ 0.7 and not at the head, or with the hands out of frame an upper arm above
    ///    shoulder height) → mouth open ≥ 0.35 without a smile ? .screaming : .celebrate
    /// 3. both hands at the head (head ≤ 0.35, lift ≥ 0.5) → mouth open ≥ 0.45 ? .screaming : .mindBlown
    /// 4. a hand on the face (head ≤ 0.22, lift ≥ 0.5; ≤ 0.3 when the face is hidden) with the eyes shut or the face
    ///    hidden, mouth open < 0.35 → .facepalm
    /// 5. wrists together (gap ≤ 0.12) in front, both lifts 0.3...0.75 → .clapping
    /// 6. both elbows bent ≥ 0.3, wrists out ≥ 0.3 and low (lift 0.1...0.5) → .shrug
    /// 7. both arms spread (out ≥ 0.45, lift ≥ 0.35) with a smile > 0.08 → .excited
    public static func gestureMood(_ pose: PoseDescriptor, face: FaceFeatures?, baseline: RestingBaseline) -> Mood? {
        let open = face?.mouthOpenness ?? 0
        let smile = (face?.smile ?? 0.5) - 0.5
        let eyeDeviation = face.map { baseline.signedDeviation(of: $0)[1] } ?? 0

        struct Arm {
            let lift: Double?
            let out: Double?
            let head: Double?
            let elbowLift: Double?
            let elbowBend: Double?
        }
        let left = Arm(lift: pose[.leftLift], out: pose[.leftOut], head: pose[.leftHead],
                       elbowLift: pose[.leftElbowLift], elbowBend: pose[.leftElbowBend])
        let right = Arm(lift: pose[.rightLift], out: pose[.rightOut], head: pose[.rightHead],
                        elbowLift: pose[.rightElbowLift], elbowBend: pose[.rightElbowBend])
        func both(_ test: (Arm) -> Bool) -> Bool { test(left) && test(right) }
        func either(_ test: (Arm) -> Bool) -> Bool { test(left) || test(right) }

        if let hand = pose.hand {
            if hand.thumbsUp >= 0.7 { return .thumbsUp }
            if hand.point >= 0.7 { return .pointing }
        }
        let armUp: (Arm) -> Bool = { arm in
            if let lift = arm.lift {
                return lift >= 0.7 && (arm.head ?? 1) >= 0.35
            }
            return (arm.elbowLift ?? 0) >= 0.5
        }
        if both(armUp) {
            return open >= 0.35 && smile <= 0.05 ? .screaming : .celebrate
        }
        let handAtHead: (Arm) -> Bool = { arm in
            guard let head = arm.head, let lift = arm.lift else { return false }
            return head <= 0.35 && lift >= 0.5
        }
        if both(handAtHead) {
            return open >= 0.45 ? .screaming : .mindBlown
        }
        let reach = face == nil ? 0.3 : 0.22
        let handOnFace: (Arm) -> Bool = { arm in
            guard let head = arm.head, let lift = arm.lift else { return false }
            return head <= reach && lift >= 0.5
        }
        if either(handOnFace) && (face == nil || eyeDeviation <= -0.1) && open < 0.35 {
            return .facepalm
        }
        if let gap = pose[.wristGap], gap <= 0.12,
           both({ arm in arm.lift.map { $0 >= 0.3 && $0 <= 0.75 } ?? false }) {
            return .clapping
        }
        let shrugging: (Arm) -> Bool = { arm in
            guard let bend = arm.elbowBend, let out = arm.out, let lift = arm.lift else { return false }
            return bend >= 0.3 && out >= 0.3 && lift >= 0.1 && lift <= 0.5
        }
        if both(shrugging) {
            return .shrug
        }
        let spread: (Arm) -> Bool = { arm in
            guard let out = arm.out, let lift = arm.lift else { return false }
            return out >= 0.45 && lift >= 0.35
        }
        if both(spread) && smile > 0.08 {
            return .excited
        }
        return nil
    }
}
