import Foundation

/// The pose behind the search: its word ("t-pose", "hands on hips"), or "your pose" for a clear gesture without one. It
/// picks where the readout's word comes from (the pose, or the face with a pose) and sets off the mirror's green flash
/// when a new one is caught.
public enum PoseBadge: Equatable, Sendable {
    case word(Mood)
    case pose

    /// The badge for a query: for a clear gesture (`Ranker.gestureWithoutFace`), the pose's word when it has one (the
    /// word the mood comes from, see `MoodClassifier.mood`), else "your pose"; nil otherwise (the face alone made the
    /// search, forearms on armrests included).
    public static func of(_ sample: ExpressionSample, baseline: RestingBaseline) -> PoseBadge? {
        guard let pose = sample.pose, pose.gestureStrength >= Ranker.gestureWithoutFace else { return nil }
        if let descriptor = pose.descriptor, let word = MoodClassifier.gestureMood(descriptor, face: sample.face, baseline: baseline) {
            return .word(word)
        }
        return .pose
    }

    public var label: String {
        switch self {
        case let .word(mood): return mood.label
        case .pose: return "your pose"
        }
    }
}

/// Tells when the person has stepped back to show their whole body, so the hint can talk about poses rather than a
/// face too small to read: on once the body has been narrower than `farWidth` of the frame for `onDelay`; off once it
/// has been at least `nearWidth` wide for `offDelay`, or gone for `goneDelay`. Widths in between change nothing, so the
/// hint never flickers at the edge.
public struct StandingBackDetector: Sendable {
    public static let farWidth = 0.2
    public static let nearWidth = 0.25
    public static let onDelay: TimeInterval = 1.5
    public static let offDelay: TimeInterval = 1.0
    public static let goneDelay: TimeInterval = 1.5

    public private(set) var isStandingBack = false

    private var farSince: TimeInterval?
    private var nearSince: TimeInterval?
    private var goneSince: TimeInterval?

    public init() {}

    /// Feed the body's width in the frame (0...1, `BodyJoints.widthInImage`) for every frame, nil without a body.
    /// Returns `isStandingBack`.
    @discardableResult
    public mutating func observe(bodyWidth: Double?, at timestamp: TimeInterval) -> Bool {
        let tolerance = 1e-9
        guard let bodyWidth else {
            farSince = nil
            nearSince = nil
            let since = goneSince ?? timestamp
            goneSince = since
            if isStandingBack && timestamp - since >= StandingBackDetector.goneDelay - tolerance {
                isStandingBack = false
            }
            return isStandingBack
        }
        goneSince = nil
        if bodyWidth < StandingBackDetector.farWidth {
            nearSince = nil
            let since = farSince ?? timestamp
            farSince = since
            if !isStandingBack && timestamp - since >= StandingBackDetector.onDelay - tolerance {
                isStandingBack = true
            }
        } else if bodyWidth >= StandingBackDetector.nearWidth {
            farSince = nil
            let since = nearSince ?? timestamp
            nearSince = since
            if isStandingBack && timestamp - since >= StandingBackDetector.offDelay - tolerance {
                isStandingBack = false
            }
        } else {
            farSince = nil
            nearSince = nil
        }
        return isStandingBack
    }

    public mutating func reset() {
        isStandingBack = false
        farSince = nil
        nearSince = nil
        goneSince = nil
    }
}
