import Foundation

/// A clear gesture with no word of its own, in words: plain facts for the on-device model to name, and a phrase made
/// from them by rule for when it can't. It describes what `PoseBadge.of` calls "your pose": one arm flexed beside the
/// head, horns with the fingers, a hand on the chin, arms out in front.
///
/// The facts are quantized words, never numbers, so the same pose always gives the same facts (and `key`). They never
/// say left or right: Vision's sides aren't checked against the mirror, the descriptor is side-agnostic and memes may be
/// flipped, so it is "one arm" and "the other arm", "both arms", "one hand". The arms' numbers are `PoseDescriptor`'s
/// (lift, out, head, elbow lift, bend, cross, forearm rise, in its units), the hand's `HandShape`'s, the face's
/// `MoodClassifier`'s (deviations from the resting face, and its cues).
public struct PoseDescription: Hashable, Sendable {
    /// Short sentences, most telling first, e.g. "One arm: …", "The other arm …", "One hand: …", "Body: …", "Face: …".
    public let facts: [String]
    /// 1–3 lowercase GIF-tag words made by rule ("flexing", "rock on", "thinking", "hand on head", … "strike a pose");
    /// never empty.
    public let phrase: String

    /// The same for the same pose (the facts are quantized words): `facts.joined(separator: "\n")`.
    public var key: String {
        facts.joined(separator: "\n")
    }

    /// An empty phrase becomes `fallbackPhrase`.
    public init(facts: [String], phrase: String) {
        self.facts = facts
        self.phrase = phrase.isEmpty ? PoseDescription.fallbackPhrase : phrase
    }

    /// The phrase when no rule names the pose.
    static let fallbackPhrase = "strike a pose"

    // MARK: Thresholds (arm numbers in `PoseDescriptor`'s units)

    /// Wrist heights (lift) from which a hand is high above the head, at head height, at shoulder height, at chest
    /// height; lower is low.
    static let highAboveTheHead = 0.75
    static let headHeight = 0.55
    static let shoulderHeight = 0.4
    static let chestHeight = 0.25
    /// An elbow bent at most this much is a straight arm; from `sharplyBent` it is bent sharply.
    static let straightArm = 0.2
    static let sharplyBent = 0.45
    /// Upper-arm angles (elbow lift: 0 hanging, 0.5 level, 1 straight up): hanging below `upperArmHanging`, raised a
    /// little up to `upperArmOut`, out to the side at shoulder height within it, raised high above it, raised over the
    /// head from `upperArmOverTheHead`.
    static let upperArmHanging = 0.25
    static let upperArmOut: ClosedRange<Double> = 0.36...0.7
    static let upperArmOverTheHead = 0.8
    /// A bent arm's forearm is up from this rise (the wrist well above the elbow), down at `forearmDown` or less.
    static let forearmUp = 0.6
    static let forearmDown = 0.4
    /// A wrist this far out is stretched out to the side; one this far across reaches across the body.
    static let stretchedOut = 0.55
    static let acrossTheBody = 0.3
    /// A straight arm at least at chest height whose wrist is nearer its shoulder than this (in shoulder widths) points
    /// toward the camera: foreshortened, as arms held out in front are.
    static let forwardReach = 0.8
    /// Wrist to head: on the face within `onTheFace`, beside the head within `besideTheHead`; on top of it when also
    /// `aboveTheHeadsCentre` over the head's centre (as `BodyShape.ohNo` tells it).
    static let onTheFace = 0.22
    static let besideTheHead = 0.35
    static let aboveTheHeadsCentre = 0.07
    /// A hand on the chest: reaching in (cross ≥ 0.15) at chest height (lift 0.3...0.45), off the face (head 0.35...0.7).
    static let chestCross = 0.15
    static let chestLift: ClosedRange<Double> = 0.3...0.45
    static let chestHead: ClosedRange<Double> = 0.35...0.7
    /// The head's centre in lift units when it isn't measured: upright (headRise ≈ 0.507).
    static let uprightHeadLift = (1.5 * 0.507 + 1.5) / 3.5
    /// A low arm (lift under `chestHeight`) out less than this, and not across the body, rests; bent more than
    /// `restingBend` it rests low (on a desk, in the lap), else it hangs at the side.
    static let restingOut = 0.4
    static let restingBend = 0.3
    /// Wrists this close (wrist gap) are together.
    static let handsTogether = 0.12
    /// A finger at least this straight is straight; at most `curledFinger`, curled.
    static let straightFinger = 0.7
    static let curledFinger = 0.3
    /// A hand sign (or finger pattern) is clear from this; a fist or an open palm is read from `handRead`.
    static let clearSign = 0.7
    static let handRead = 0.5
    /// A flexed arm: upper arm out near level (`upperArmOut`), the elbow bent at least this much, the hand up (lift ≥
    /// `flexedLift`, or the forearm rising ≥ `flexedForearm`) — `BodyShape.flex` with one arm.
    static let flexedBend = 0.38
    static let flexedLift = 0.5
    static let flexedForearm = 0.55
    /// A raised hand: lift at least this, the elbow bent at most `raisedBend`.
    static let raisedLift = 0.75
    static let raisedBend = 0.35
    /// The torso this short (shoulders to hips) is bending forward.
    static let bendingForward = 0.45
    /// The head this low over the shoulders is ducked between them.
    static let headDucked = 0.3
    /// The shoulder line tilted this much (1 at 30°) is tilted.
    static let shouldersTilted = 0.5

    // MARK: Describing

    /// nil unless the sample is a clear gesture with no word (`PoseBadge.of(sample, baseline:) == .pose`) measured in
    /// detail (a `PoseDescriptor`). Facts, in this order:
    /// - the hand first when it makes a clear sign (`HandShape.signStrength` ≥ 0.7): which fingers are straight (≥ 0.7)
    ///   and which curled (≤ 0.3) when the fingers were kept, else its clearest sign; "Hands: not seen" without one;
    /// - each arm, the more raised or active first ("One arm", "The other arm", or "Both arms" when they read the same):
    ///   the upper arm, the elbow, the forearm, out to the side or across the body or toward the camera, and where the
    ///   hand is (on the face at the chin or the forehead, on top of or beside the head, on the chest) or how high;
    ///   "hangs at the side" / "rests low" at rest, "is out of view" with neither the elbow nor the wrist seen;
    /// - "Hands: together" (wrist gap ≤ 0.12); then the hand when it makes no clear sign;
    /// - the body: bending forward, the head ducked, the shoulders tilted;
    /// - the face when something about it stands out (an open mouth, a big smile or a frown, raised or lowered brows,
    ///   shut or wide eyes, a tilted head, a look to the side, a clear cue), "Face: not seen" without one.
    /// The phrase is the first that fits:
    /// 1. a clear finger pattern (`HandShape.patternStrength` ≥ 0.7, never on the face): thumb, index and little straight,
    ///    middle and ring curled → "love you"; index and little straight, middle and ring curled → "rock on"; thumb and
    ///    little straight, the other three curled → "hang loose"; thumb and index straight, the other three curled →
    ///    "finger guns" (any other pattern goes on to the arms);
    /// 2. one arm flexed (upper arm 0.36...0.7, bend ≥ 0.38, lift ≥ 0.5 or forearm rise ≥ 0.55, the hand not on the face
    ///    or on top of the head) and the hand not read as an open palm (that is `BodyShape.hello`) → "flexing";
    /// 3. a hand on the face below the head's centre → "thinking"; at the forehead → "salute"; on top of the head →
    ///    "hand on head"; on the chest → "hand on heart"; the hands together → "hands together";
    /// 4. both hands high (lift ≥ 0.75) → "hands up"; one arm up and fairly straight (bend ≤ 0.35) with the other low →
    ///    "raise hand"; both arms stretched out straight (out ≥ 0.55, bend ≤ 0.2) → "arms out"; one of them, the other
    ///    low → "arm out"; bending forward → "bowing";
    /// 5. else "strike a pose".
    public static func of(_ sample: ExpressionSample, baseline: RestingBaseline) -> PoseDescription? {
        guard case .pose? = PoseBadge.of(sample, baseline: baseline), let pose = sample.pose?.descriptor else { return nil }
        let headLift = pose[.headRise].map { (1.5 * $0 + 1.5) / 3.5 } ?? PoseDescription.uprightHeadLift
        let arms = [Arm(pose, left: true, headLift: headLift), Arm(pose, left: false, headLift: headLift)]

        // Which arm is "one arm" never depends on the side: the higher (or more active) first, then by its words.
        let ordered = arms.sorted { first, second in
            first.rank != second.rank ? first.rank > second.rank : first.summary < second.summary
        }
        var armFacts: [String] = []
        if ordered[0].summary == ordered[1].summary {
            if let resting = ordered[0].resting {
                armFacts.append("Both arms \(resting.both).")
            } else {
                armFacts.append("Both arms: \(ordered[0].clauses.joined(separator: ", ")).")
            }
        } else {
            armFacts.append(ordered[0].sentence("One arm"))
            armFacts.append(ordered[1].sentence("The other arm"))
        }
        if let gap = pose[.wristGap], gap <= PoseDescription.handsTogether {
            armFacts.append("Hands: together.")
        }

        var facts: [String]
        if let hand = pose.hand {
            let handFact = "One hand: \(handWords(hand))."
            facts = hand.signStrength >= PoseDescription.clearSign ? [handFact] + armFacts : armFacts + [handFact]
        } else {
            facts = armFacts + ["Hands: not seen."]
        }

        var body: [String] = []
        if let torso = pose[.torsoLength], torso <= PoseDescription.bendingForward {
            body.append("bending forward")
        }
        if let headRise = pose[.headRise], headRise <= PoseDescription.headDucked {
            body.append("head low between the shoulders")
        }
        if let tilt = pose[.shoulderTilt], tilt >= PoseDescription.shouldersTilted {
            body.append("shoulders tilted")
        }
        if !body.isEmpty {
            facts.append("Body: \(body.joined(separator: ", ")).")
        }
        if let face = faceFact(sample, baseline: baseline) {
            facts.append(face)
        }
        return PoseDescription(facts: facts, phrase: rulePhrase(for: pose, arms: arms))
    }

    /// Where a hand is, when that says something.
    private enum Place {
        case chin, forehead, topOfTheHead, besideTheHead, chest
    }

    /// One arm's numbers, and how they read.
    private struct Arm {
        let lift: Double?
        let out: Double?
        let head: Double?
        let elbowLift: Double?
        let bend: Double?
        let cross: Double?
        let forearmRise: Double?
        /// The head's centre in lift units.
        let headLift: Double

        init(_ pose: PoseDescriptor, left: Bool, headLift: Double) {
            lift = pose[left ? .leftLift : .rightLift]
            out = pose[left ? .leftOut : .rightOut]
            head = pose[left ? .leftHead : .rightHead]
            elbowLift = pose[left ? .leftElbowLift : .rightElbowLift]
            bend = pose[left ? .leftElbowBend : .rightElbowBend]
            cross = pose[left ? .leftCross : .rightCross]
            forearmRise = pose[left ? .leftForearmRise : .rightForearmRise]
            self.headLift = headLift
        }

        /// Hanging or low (lift ≤ 0.4); with the wrist unseen, an elbow that isn't raised (or isn't seen either), as
        /// `PoseDescriptor`'s body shapes tell it.
        var isLow: Bool {
            if let lift { return lift <= 0.4 }
            return (elbowLift ?? 0) < 0.4
        }

        var isStraight: Bool {
            bend.map { $0 <= PoseDescription.straightArm } ?? false
        }

        /// Where the hand is: on top of the head (at the head and clearly above its centre), on the face (below the
        /// head's centre: the chin or mouth; above it: the forehead), beside the head, on the chest; nil elsewhere, or
        /// without the wrist or the head seen.
        var place: Place? {
            guard let lift, let head else { return nil }
            if head <= PoseDescription.besideTheHead && lift >= headLift + PoseDescription.aboveTheHeadsCentre {
                return .topOfTheHead
            }
            if head <= PoseDescription.onTheFace {
                return lift < headLift ? .chin : .forehead
            }
            if head <= PoseDescription.besideTheHead {
                return .besideTheHead
            }
            if let cross, cross >= PoseDescription.chestCross, PoseDescription.chestLift.contains(lift),
               PoseDescription.chestHead.contains(head) {
                return .chest
            }
            return nil
        }

        /// Whether the wrist is near its own shoulder for an arm that isn't hanging: held out toward the camera. The
        /// wrist's offset from its shoulder comes from how far it is across the body (or out past the shoulder) and
        /// its height; only with the shoulders square on (cross measured).
        var reachesForward: Bool {
            guard let lift, let out, let cross, lift >= PoseDescription.chestHeight else { return false }
            let across = cross > 0 ? 2 * cross : max(0, 2.5 * out - 0.5)
            let up = 3.5 * lift - 1.5
            return (across * across + up * up).squareRoot() < PoseDescription.forwardReach
        }

        /// How a resting arm reads, for one arm and for both ("hangs at the side" / "hang at the side"); also an arm
        /// out of view. nil for an arm doing something.
        var resting: (one: String, both: String)? {
            guard let lift else {
                guard let elbowLift else { return (one: "is out of view", both: "are out of view") }
                if elbowLift < PoseDescription.upperArmOut.lowerBound {
                    return (one: "hangs low out of view", both: "hang low out of view")
                }
                return nil
            }
            guard lift < PoseDescription.chestHeight, (out ?? 0) < PoseDescription.restingOut,
                  (cross ?? 0) < PoseDescription.acrossTheBody else { return nil }
            if (bend ?? 0) <= PoseDescription.restingBend {
                return (one: "hangs at the side", both: "hang at the side")
            }
            return (one: "rests low", both: "rest low")
        }

        /// What the arm does, e.g. ["upper arm out to the side at shoulder height", "elbow bent sharply", "forearm up",
        /// "hand at head height"].
        var clauses: [String] {
            var words: [String] = []
            if !isStraight, let elbowLift {
                if elbowLift < PoseDescription.upperArmHanging {
                    words.append("upper arm hanging")
                } else if elbowLift < PoseDescription.upperArmOut.lowerBound {
                    words.append("upper arm raised a little")
                } else if elbowLift <= PoseDescription.upperArmOut.upperBound {
                    words.append("upper arm out to the side at shoulder height")
                } else if elbowLift < PoseDescription.upperArmOverTheHead {
                    words.append("upper arm raised high")
                } else {
                    words.append("upper arm raised over the head")
                }
            }
            if let bend {
                if isStraight {
                    words.append("arm straight")
                } else {
                    words.append(bend < PoseDescription.sharplyBent ? "elbow bent" : "elbow bent sharply")
                    if let forearmRise {
                        if forearmRise >= PoseDescription.forearmUp {
                            words.append("forearm up")
                        } else if forearmRise <= PoseDescription.forearmDown {
                            words.append("forearm down")
                        } else {
                            words.append("forearm level")
                        }
                    }
                }
            }
            if let out, out >= PoseDescription.stretchedOut {
                words.append("stretched out to the side")
            }
            if let cross, cross >= PoseDescription.acrossTheBody {
                words.append("reaching across the body")
            }
            if isStraight && reachesForward {
                words.append("reaching toward the camera")
            }
            guard let lift else {
                words.append("hand out of view")
                return words
            }
            switch place {
            case .chin?: words.append("hand on the face at the chin")
            case .forehead?: words.append("hand on the face at the forehead")
            case .topOfTheHead?: words.append("hand on top of the head")
            case .besideTheHead?: words.append("hand beside the head")
            case .chest?: words.append("hand on the chest")
            case nil:
                if lift >= PoseDescription.highAboveTheHead {
                    words.append("hand high above the head")
                } else if lift >= PoseDescription.headHeight {
                    words.append("hand at head height")
                } else if lift >= PoseDescription.shoulderHeight {
                    words.append("hand at shoulder height")
                } else if lift >= PoseDescription.chestHeight {
                    words.append("hand at chest height")
                } else {
                    words.append("hand low")
                }
            }
            return words
        }

        /// How much the arm does, for putting the more raised or active arm first: −1 out of view, 0 at rest, else 1
        /// (low) … 5 (high above the head) by the wrist's height (the upper arm's without the wrist).
        var rank: Int {
            if lift == nil && elbowLift == nil { return -1 }
            if resting != nil { return 0 }
            guard let lift else {
                let elbow = elbowLift ?? 0
                return elbow >= PoseDescription.upperArmOverTheHead ? 4 : elbow >= PoseDescription.upperArmOut.lowerBound ? 2 : 1
            }
            if lift >= PoseDescription.highAboveTheHead { return 5 }
            if lift >= PoseDescription.headHeight { return 4 }
            if lift >= PoseDescription.shoulderHeight { return 3 }
            if lift >= PoseDescription.chestHeight { return 2 }
            return 1
        }

        /// The arm's words on their own, for ordering and for telling whether both arms read the same.
        var summary: String {
            resting?.one ?? clauses.joined(separator: ", ")
        }

        /// "One arm hangs at the side." or "One arm: upper arm …, elbow bent, …."
        func sentence(_ subject: String) -> String {
            if let resting {
                return "\(subject) \(resting.one)."
            }
            return "\(subject): \(clauses.joined(separator: ", "))."
        }

        /// One arm of `BodyShape.flex`: the upper arm out near level, the elbow bent, the hand up, and not on the face or
        /// on top of the head (a salute, a hand on the head).
        var isFlexed: Bool {
            guard let elbowLift, let bend, PoseDescription.upperArmOut.contains(elbowLift),
                  bend >= PoseDescription.flexedBend else { return false }
            if let place, place == .chin || place == .forehead || place == .topOfTheHead {
                return false
            }
            return (lift ?? 0) >= PoseDescription.flexedLift || (forearmRise ?? 0) >= PoseDescription.flexedForearm
        }
    }

    // MARK: The hand

    /// Which fingers are straight and which curled when they were kept ("index and little fingers straight, the others
    /// curled", "a fist", "an open palm"), else the clearest of its five signs; "relaxed" when none is clear.
    private static func handWords(_ hand: HandShape) -> String {
        let seen = HandShape.Finger.allCases.filter { hand[$0] != nil }
        if seen.count >= 3 {
            let straight = seen.filter { (hand[$0] ?? 0) >= PoseDescription.straightFinger }
            let curled = seen.filter { (hand[$0] ?? 1) <= PoseDescription.curledFinger }
            let halfBent = seen.filter { !straight.contains($0) && !curled.contains($0) }
            if straight.isEmpty && halfBent.isEmpty {
                return "a fist"
            }
            if curled.isEmpty && halfBent.isEmpty {
                return "an open palm"
            }
            var parts: [String] = []
            if !straight.isEmpty {
                parts.append(names(of: straight) + " straight")
            }
            if !halfBent.isEmpty {
                parts.append(names(of: halfBent) + " half bent")
            }
            if !curled.isEmpty {
                let theOthers = halfBent.isEmpty && seen.count == HandShape.Finger.allCases.count && curled.count >= 2
                parts.append(theOthers ? "the others curled" : names(of: curled) + " curled")
            }
            return parts.joined(separator: ", ")
        }
        if hand.thumbsUp >= clearSign { return "thumb up" }
        if hand.point >= clearSign { return "pointing" }
        if hand.peace >= clearSign { return "peace sign" }
        if hand.fist >= handRead { return "a fist" }
        if hand.openPalm >= handRead { return "an open palm" }
        return "relaxed"
    }

    /// "thumb", "index finger", "thumb and index finger", "index and little fingers", "thumb, index and little fingers".
    private static func names(of fingers: [HandShape.Finger]) -> String {
        let others = fingers.filter { $0 != .thumb }
        var words: [String] = fingers.contains(.thumb) ? ["thumb"] : []
        words += others.map { word(for: $0) }
        var list = words.last ?? ""
        if words.count > 1 {
            list = words.dropLast().joined(separator: ", ") + " and " + list
        }
        if others.isEmpty {
            return list
        }
        return list + (others.count == 1 ? " finger" : " fingers")
    }

    private static func word(for finger: HandShape.Finger) -> String {
        switch finger {
        case .thumb: return "thumb"
        case .index: return "index"
        case .middle: return "middle"
        case .ring: return "ring"
        case .little: return "little"
        }
    }

    /// The words of a finger pattern known by name; nil for none (or no clear pattern, or the fingers not kept).
    private static func handPhrase(_ hand: HandShape) -> String? {
        guard hand.fingers != nil, hand.patternStrength >= clearSign else { return nil }
        func straight(_ fingers: HandShape.Finger...) -> Bool {
            fingers.allSatisfy { (hand[$0] ?? 0) >= PoseDescription.straightFinger }
        }
        func curled(_ fingers: HandShape.Finger...) -> Bool {
            fingers.allSatisfy { (hand[$0] ?? 1) <= PoseDescription.curledFinger }
        }
        if straight(.thumb, .index, .little) && curled(.middle, .ring) { return "love you" }
        if straight(.index, .little) && curled(.middle, .ring) { return "rock on" }
        if straight(.thumb, .little) && curled(.index, .middle, .ring) { return "hang loose" }
        if straight(.thumb, .index) && curled(.middle, .ring, .little) { return "finger guns" }
        return nil
    }

    // MARK: The face

    /// What stands out about the face (the thresholds `MoodClassifier.mood` reads it with), "Face: not seen." without
    /// one; nil when nothing does.
    private static func faceFact(_ sample: ExpressionSample, baseline: RestingBaseline) -> String? {
        guard let face = sample.face else { return "Face: not seen." }
        let deviation = baseline.signedDeviation(of: face)
        let browDeviation = deviation[0]
        let eyeDeviation = deviation[1]
        let smile = face.smile - 0.5
        var words: [String] = []
        if face.mouthOpenness >= 0.45 {
            words.append("mouth wide open")
        } else if face.mouthOpenness >= 0.2 {
            words.append("mouth open")
        }
        if smile > 0.12 {
            words.append("big smile")
        } else if smile < -0.1 {
            words.append("frowning")
        }
        if browDeviation >= 0.12 {
            words.append("eyebrows raised")
        } else if browDeviation <= -0.12 {
            words.append("eyebrows lowered")
        }
        if eyeDeviation <= -0.25 {
            words.append("eyes shut")
        } else if eyeDeviation >= 0.15 {
            words.append("eyes wide")
        }
        if face.headTilt >= 0.35 {
            words.append("head tilted")
        }
        if face.gazeSide >= 0.45 {
            words.append("looking to the side")
        }
        if let cue = baseline.cues(of: sample.shape).clearCue {
            words.append(cueWords(cue))
        }
        return words.isEmpty ? nil : "Face: \(words.joined(separator: ", "))."
    }

    private static func cueWords(_ cue: FaceCues.Cue) -> String {
        switch cue {
        case .tongueOut: return "tongue out"
        case .wink: return "winking"
        case .raisedBrow: return "one eyebrow raised"
        case .pucker: return "lips puckered"
        case .smirk: return "smirking"
        case .eyeRoll: return "eyes rolled up"
        }
    }

    // MARK: The phrase

    /// The rule-made phrase (see `of(_:baseline:)`).
    private static func rulePhrase(for pose: PoseDescriptor, arms: [Arm]) -> String {
        if let hand = pose.hand, let sign = handPhrase(hand) {
            return sign
        }
        let openPalm = (pose.hand?.openPalm ?? 0) >= handRead
        if !openPalm && arms.contains(where: { $0.isFlexed }) {
            return "flexing"
        }
        let places = arms.compactMap { $0.place }
        if places.contains(.chin) { return "thinking" }
        if places.contains(.forehead) { return "salute" }
        if places.contains(.topOfTheHead) { return "hand on head" }
        if places.contains(.chest) { return "hand on heart" }
        if let gap = pose[.wristGap], gap <= handsTogether {
            return "hands together"
        }
        func oneAndOther(_ test: (Arm) -> Bool) -> Bool {
            (test(arms[0]) && arms[1].isLow) || (test(arms[1]) && arms[0].isLow)
        }
        func high(_ arm: Arm) -> Bool {
            (arm.lift ?? 0) >= PoseDescription.raisedLift
        }
        func raised(_ arm: Arm) -> Bool {
            high(arm) && (arm.bend ?? 1) <= PoseDescription.raisedBend
        }
        func stretched(_ arm: Arm) -> Bool {
            (arm.out ?? 0) >= PoseDescription.stretchedOut && (arm.bend ?? 1) <= PoseDescription.straightArm
        }
        if arms.allSatisfy(high) { return "hands up" }
        if oneAndOther(raised) { return "raise hand" }
        if arms.allSatisfy(stretched) { return "arms out" }
        if oneAndOther(stretched) { return "arm out" }
        if let torso = pose[.torsoLength], torso <= bendingForward {
            return "bowing"
        }
        return fallbackPhrase
    }

    // MARK: Cleaning a model's name

    /// Most words a name keeps, and most characters.
    static let maximumNameWords = 3
    static let maximumNameLength = 30
    /// Answers that are no name at all.
    private static let refusals = ["sorry", "i can't", "i cannot", "cannot", "unable", "as an ai"]
    /// Leading words that say nothing about the pose ("the person is flexing").
    private static let fillers: Set<String> = [
        "a", "an", "the", "someone", "somebody", "person", "user", "they", "they're", "are", "is", "he", "she", "he's",
        "she's", "it", "it's", "this",
    ]

    /// Cleans a model's answer into at most 3 lowercase words: its first line with any letters, letters, digits, ' and -
    /// kept (quotes, other punctuation and a trailing period dropped), leading filler ("the person is", "a", "an",
    /// "the", "someone", "they are" …) dropped. nil when fewer than 3 letters remain, when it is longer than 30
    /// characters, or when the answer is a refusal or an apology ("sorry", "i can't", "cannot", "unable", "as an ai").
    public static func cleanName(_ raw: String) -> String? {
        let text = raw.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        guard !refusals.contains(where: { text.contains($0) }) else { return nil }
        let lines = text.split(whereSeparator: { $0.isNewline })
        guard let line = lines.first(where: { candidate in candidate.contains { $0.isLetter || $0.isNumber } }) else {
            return nil
        }
        let kept = String(line.map { character -> Character in
            character.isLetter || character.isNumber || character == "'" || character == "-" ? character : " "
        })
        var words = kept.split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'-")) }
            .filter { !$0.isEmpty }
        while let first = words.first, fillers.contains(first) {
            words.removeFirst()
        }
        let name = words.prefix(maximumNameWords).joined(separator: " ")
        guard name.filter({ $0.isLetter }).count >= 3, name.count <= maximumNameLength else { return nil }
        return name
    }
}
