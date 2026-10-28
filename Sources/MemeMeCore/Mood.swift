import Foundation

/// The one word a face is mapped to on-device; of the face, only this word is sent to GIPHY (typed words go as typed).
public enum Mood: String, CaseIterable, Codable, Hashable, Sendable {
    case shocked, screaming, laughing, happy, smug, sideEye, crying, sad, angry, confused, unimpressed, nervous, excited, reaction
    // Body language
    case celebrate, facepalm, mindBlown, shrug, thumbsUp, pointing, clapping
    case tPose, flex, dab, handsOnHips, armsCrossed, pickMe, hello, ohNo, peace, bow

    /// GIPHY query, e.g. "shocked reaction", "side eye", "unimpressed", "reaction", "mind blown", "t pose"
    public var searchQuery: String {
        switch self {
        case .sideEye: return "side eye"
        case .unimpressed: return "unimpressed"
        case .reaction: return "reaction"
        case .tPose: return "t pose"
        case .peace: return "peace sign"
        // "bow" alone finds ribbons.
        case .bow: return "bowing"
        case .celebrate, .facepalm, .mindBlown, .shrug, .thumbsUp, .pointing, .clapping,
             .flex, .dab, .handsOnHips, .armsCrossed, .pickMe, .hello, .ohNo: return label
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
        case .tPose: return "t-pose"
        case .flex: return "flex"
        case .dab: return "dab"
        case .handsOnHips: return "hands on hips"
        case .armsCrossed: return "arms crossed"
        case .pickMe: return "pick me"
        case .hello: return "hello"
        case .ohNo: return "oh no"
        case .peace: return "peace"
        case .bow: return "bow"
        }
    }
}

public enum MoodClassifier {
    /// Rules in this order (d = signed deviation from baseline.neutral; o = face.mouthOpenness; s = face.smile - 0.5):
    /// 1. a pose described in detail (`PoseDescriptor`), a clear gesture (strength ≥ `Ranker.gestureWithoutFace`), with
    ///    body language that has its own word → that word (`gestureMood`; forearms on armrests have a shrug's shape)
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
        if let descriptor = pose?.descriptor, descriptor.gestureStrength >= Ranker.gestureWithoutFace,
           let gesture = gestureMood(descriptor, face: face, baseline: baseline) {
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
    /// in this order (shapes: `PoseDescriptor.bodyShape`):
    /// 1. hand sign: thumbs up ≥ 0.7 → .thumbsUp; peace ≥ 0.7 → .peace; pointing ≥ 0.7 → .pointing
    /// 2. shape dab → .dab; flex → .flex; bolt (one arm up and out, the other drawn back) → .celebrate
    /// 3. both arms up (wrist lift ≥ 0.7, or ≥ 0.65 spread out ≥ 0.45, and not at the head; or with the hands out of
    ///    frame an upper arm near vertical, elbowLift ≥ `PoseDescriptor.elbowOnlyUp`) → mouth open ≥ 0.35 without a
    ///    smile ? .screaming : .celebrate
    /// 4. both hands beside the head (head ≤ 0.35, lift ≥ 0.5, out ≥ 0.09: not under the chin or over the face)
    ///    → mouth open ≥ 0.45 ? .screaming : .mindBlown
    /// 5. shape ohNo (hands on top of the head) → mouth open ≥ 0.45 ? .screaming : .ohNo
    /// 6. a hand on the face (head ≤ 0.22, lift ≥ 0.5; ≤ 0.3 when the face is hidden; not raised and reaching across
    ///    from the other side, elbowLift ≥ 0.42 with cross ≥ 0.35, as a dab's bent arm does) with the eyes shut (≥ 0.25 below rest; heavy lids on a
    ///    propped head aren't enough) or the face hidden, mouth open < 0.35, no smile (≤ 0.05: a smile narrows the eyes
    ///    too) → .facepalm
    /// 7. wrists together (gap ≤ 0.12) in front, both lifts 0.3...0.75, clear of the chin (head > 0.3), not resting low
    ///    (`forearmRest` < 0.5), open hands when the hands were read (a mug or clasped fingers isn't a clap) → .clapping
    /// 8. shape armsCrossed, tPose, handsOnHips, pickMe, hello or bow → that word
    /// 9. both elbows bent ≥ 0.3, wrists out ≥ 0.3 and low (lift 0.1...0.5) → .shrug
    /// 10. both arms spread (out ≥ 0.45, lift ≥ 0.35) with a smile > 0.08 → .excited
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
            let cross: Double?
        }
        let left = Arm(lift: pose[.leftLift], out: pose[.leftOut], head: pose[.leftHead],
                       elbowLift: pose[.leftElbowLift], elbowBend: pose[.leftElbowBend], cross: pose[.leftCross])
        let right = Arm(lift: pose[.rightLift], out: pose[.rightOut], head: pose[.rightHead],
                        elbowLift: pose[.rightElbowLift], elbowBend: pose[.rightElbowBend], cross: pose[.rightCross])
        func both(_ test: (Arm) -> Bool) -> Bool { test(left) && test(right) }
        func either(_ test: (Arm) -> Bool) -> Bool { test(left) || test(right) }

        if let hand = pose.hand {
            if hand.thumbsUp >= 0.7 { return .thumbsUp }
            if hand.peace >= 0.7 { return .peace }
            if hand.point >= 0.7 { return .pointing }
        }
        let shape = pose.bodyShape
        if let shape {
            switch shape {
            case .dab: return .dab
            case .flex: return .flex
            case .bolt: return .celebrate
            case .ohNo, .armsCrossed, .tPose, .handsOnHips, .pickMe, .hello, .bow: break
            }
        }
        let armUp: (Arm) -> Bool = { arm in
            if let lift = arm.lift {
                let high = lift >= 0.7 || (lift >= 0.65 && (arm.out ?? 0) >= 0.45)
                return high && (arm.head ?? 1) >= 0.35
            }
            return (arm.elbowLift ?? 0) >= PoseDescriptor.elbowOnlyUp
        }
        if both(armUp) {
            return open >= 0.35 && smile <= 0.05 ? .screaming : .celebrate
        }
        let handAtHead: (Arm) -> Bool = { arm in
            guard let head = arm.head, let lift = arm.lift, let out = arm.out else { return false }
            return head <= 0.35 && lift >= 0.5 && out >= 0.09
        }
        if both(handAtHead) {
            return open >= 0.45 ? .screaming : .mindBlown
        }
        if shape == .ohNo {
            return open >= 0.45 ? .screaming : .ohNo
        }
        let reach = face == nil ? 0.3 : 0.22
        let handOnFace: (Arm) -> Bool = { arm in
            guard let head = arm.head, let lift = arm.lift else { return false }
            // Not a dab's bent arm: raised and reaching across the face from the other side.
            let acrossFromTheOtherSide = (arm.elbowLift ?? 0) >= 0.42 && (arm.cross ?? 0) >= 0.35
            return head <= reach && lift >= 0.5 && !acrossFromTheOtherSide
        }
        if either(handOnFace) && (face == nil || eyeDeviation <= -0.25) && open < 0.35 && smile <= 0.05 {
            return .facepalm
        }
        let openHands = pose.hand.map { $0.openPalm >= 0.5 } ?? true
        let inFront: (Arm) -> Bool = { arm in
            guard let lift = arm.lift, lift >= 0.3, lift <= 0.75 else { return false }
            return (arm.head ?? 1) > 0.3
        }
        if let gap = pose[.wristGap], gap <= 0.12, openHands, pose.forearmRest < 0.5, both(inFront) {
            return .clapping
        }
        if let shape {
            switch shape {
            case .armsCrossed: return .armsCrossed
            case .tPose: return .tPose
            case .handsOnHips: return .handsOnHips
            case .pickMe: return .pickMe
            case .hello: return .hello
            case .bow: return .bow
            case .dab, .bolt, .flex, .ohNo: break
            }
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
