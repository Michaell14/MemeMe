import Foundation

/// Tuning for `PeakHoldTracker`.
public struct PeakHoldConfig: Sendable {
    public var holdDuration: TimeInterval = 0.3
    public var newExpressionHold: TimeInterval = 1.0
    public var strongerRatio: Double = 1.15
    public var sameDirectionCosine: Double = 0.85
    public var minimumIntensity: Double = 0.12
    public var bufferWindow: TimeInterval = 0.5
    /// A frame without a face (a hand over it, say) still counts when its gesture is at least this strong.
    public var minimumGestureWithoutFace: Double = 0.5

    public init() {}
}

/// Turns a stream of analyzed frames into a stable query: a held expression becomes the query,
/// relaxing or talking does nothing, a stronger version of the same expression or a different
/// expression held long enough replaces it.
public final class PeakHoldTracker {
    public var baseline: RestingBaseline
    public let config: PeakHoldConfig
    public private(set) var query: ExpressionSample?
    public private(set) var queryIntensity: Double = 0          // 0 when no query
    public private(set) var holdProgress: Double = 0            // 0...1 toward replacing the query
    public private(set) var candidateIsNewExpression: Bool = false
    /// The strongest frame of the expression being held toward the query; nil when nothing is being held.
    public private(set) var candidate: ExpressionSample?
    public private(set) var lastSample: ExpressionSample?
    public private(set) var lastFaceTimestamp: TimeInterval?    // timestamp of the last sample that had a face
    /// Timestamp of the last sample that had a face or a gesture strong enough to stand in for one.
    public private(set) var lastSeenTimestamp: TimeInterval?

    /// A frame with its effective intensity and unit direction (7 signed face deviations + 9 gesture numbers).
    private struct Entry {
        let sample: ExpressionSample
        let intensity: Double
        let direction: [Double]

        var score: Double { intensity * sample.sharpness }
    }

    /// Consecutive candidate frames inside the cone of the run's first frame.
    private struct Run {
        let start: TimeInterval
        let direction: [Double]
        var entries: [Entry]
    }

    private var run: Run?
    private var queryDirection: [Double]?
    /// The last sample with a face, or with a gesture strong enough to stand in for one: what `snap` takes.
    private var lastSeenSample: ExpressionSample?

    /// A gesture weaker than this adds nothing to a frame's intensity (`Ranker.gestureWithoutFace`).
    private static let minimumGesture = Ranker.gestureWithoutFace

    /// Frame clocks are never exact: a hold that is short of its target by less than this
    /// fraction counts as complete, so a nominal 0.3 s hold does not cost an extra frame.
    private static let progressTolerance = 1e-9

    public init(baseline: RestingBaseline = RestingBaseline(), config: PeakHoldConfig = PeakHoldConfig()) {
        self.baseline = baseline
        self.config = config
    }

    /// Feed every analyzed frame. Returns true when `query` changed.
    @discardableResult
    public func ingest(_ sample: ExpressionSample) -> Bool {
        lastSample = sample
        if let face = sample.face {
            lastFaceTimestamp = sample.timestamp
            lastSeenTimestamp = sample.timestamp
            lastSeenSample = sample
            // Judge the frame against the baseline as it was when the frame arrived, then let calm frames refine it.
            let entry = makeEntry(for: sample)
            baseline.observe(face)
            return hold(entry)
        }
        // No face: only a clear gesture (a facepalm hides the face) keeps the hold going.
        guard (sample.pose?.gestureStrength ?? 0) >= config.minimumGestureWithoutFace else {
            clearCandidate()
            return false
        }
        lastSeenTimestamp = sample.timestamp
        lastSeenSample = sample
        return hold(makeEntry(for: sample))
    }

    /// Adds a frame to the run being held; true when it completes the hold and becomes the query.
    private func hold(_ entry: Entry) -> Bool {
        let sample = entry.sample

        guard entry.intensity >= config.minimumIntensity else {
            clearCandidate()
            return false
        }

        var current: Run
        if let existing = run, VectorMath.cosine(entry.direction, existing.direction) >= config.sameDirectionCosine {
            current = existing
            current.entries.append(entry)
            let oldest = sample.timestamp - config.bufferWindow
            current.entries.removeAll { $0.sample.timestamp < oldest }
        } else {
            current = Run(start: sample.timestamp, direction: entry.direction, entries: [entry])
        }

        guard let best = PeakHoldTracker.bestEntry(in: current.entries) else {
            run = current
            return false
        }

        let required: TimeInterval
        if let reference = queryDirection {
            if VectorMath.cosine(current.direction, reference) >= config.sameDirectionCosine {
                guard best.intensity >= queryIntensity * config.strongerRatio || completesGesture(best) else {
                    // Same expression, not clearly stronger: nothing to hold toward. Dropping the run means a
                    // later, stronger version is held for the full `holdDuration` from its first frame.
                    clearCandidate()
                    return false
                }
                required = config.holdDuration
                candidateIsNewExpression = false
            } else {
                required = config.newExpressionHold
                candidateIsNewExpression = true
            }
        } else {
            required = config.holdDuration
            candidateIsNewExpression = false
        }

        let elapsed = sample.timestamp - current.start
        let progress = required > 0 ? elapsed / required : 1
        if progress >= 1 - PeakHoldTracker.progressTolerance {
            query = best.sample
            queryIntensity = best.intensity
            queryDirection = best.direction
            clearCandidate()
            return true
        }
        run = current
        candidate = best.sample
        holdProgress = min(1, max(0, progress))
        return false
    }

    /// Space: makes the last sample with a face (or a gesture hiding it) the query, even if neutral. Returns true if it
    /// changed the query.
    @discardableResult
    public func snap() -> Bool {
        guard let sample = lastSeenSample else { return false }
        if query == sample { return false }
        let entry = makeEntry(for: sample)
        query = sample
        queryIntensity = entry.intensity
        queryDirection = entry.direction
        clearCandidate()
        return true
    }

    /// Drops the expression being held toward the query (keeps the query and the baseline): frames stopped coming in
    /// for a while (the capture view was open), so the next one starts a new hold.
    public func clearHold() {
        clearCandidate()
    }

    /// Clears query and candidate (keeps the baseline).
    public func reset() {
        query = nil
        queryIntensity = 0
        queryDirection = nil
        clearCandidate()
    }

    // MARK: Private

    private func clearCandidate() {
        run = nil
        candidate = nil
        holdProgress = 0
        candidateIsNewExpression = false
    }

    /// intensity = max(face intensity, 0.8 × gesture strength when ≥ 0.4); direction = the face's signed deviations (zeros without
    /// a face) + the pose's gesture numbers × 0.5 × its gesture strength, so arms at rest or on a desk coming into view
    /// don't turn the same face into a new expression (a pose measured the old way: [activity, 0, 0, 0, 0, 0, 0, 0, 0]).
    private func makeEntry(for sample: ExpressionSample) -> Entry {
        let faceIntensity = sample.face.map { baseline.intensity(of: $0) } ?? 0
        // Only a clear gesture stands in for a face: a neutral face with half-raised arms isn't an expression.
        let strength = sample.pose?.gestureStrength ?? 0
        let gesture = strength >= PeakHoldTracker.minimumGesture ? strength : 0
        let intensity = max(faceIntensity, 0.8 * gesture)
        var direction = sample.face.map { baseline.signedDeviation(of: $0) } ?? [Double](repeating: 0, count: 7)
        if let descriptor = sample.pose?.descriptor {
            let strength = descriptor.gestureStrength
            direction += descriptor.gestureDirection.map { 0.5 * strength * $0 }
        } else {
            direction += [sample.pose?.activity ?? 0, 0, 0, 0, 0, 0, 0, 0, 0]
        }
        return Entry(sample: sample, intensity: intensity, direction: VectorMath.normalized(direction))
    }

    /// The gesture alone is as strong as the query, and the arms or hand have reached a pose with a word of its own (a
    /// facepalm, say) where the query, caught on the way there, had none. Gesture strength saturates before the hand
    /// gets to the face, so the finished gesture is rarely stronger than the frame the hold caught mid-motion; it still
    /// replaces it. A weak gesture (forearms on armrests reading as a shrug) never takes over a held face.
    private func completesGesture(_ entry: Entry) -> Bool {
        let strength = entry.sample.pose?.gestureStrength ?? 0
        guard let query, strength >= PeakHoldTracker.minimumGesture, 0.8 * strength >= queryIntensity - 1e-9,
              let descriptor = entry.sample.pose?.descriptor,
              MoodClassifier.gestureMood(descriptor, face: entry.sample.face, baseline: baseline) != nil else { return false }
        guard let held = query.pose?.descriptor else { return true }
        return MoodClassifier.gestureMood(held, face: query.face, baseline: baseline) == nil
    }

    /// Highest `intensity * sharpness`; the newest wins ties.
    private static func bestEntry(in entries: [Entry]) -> Entry? {
        var best: Entry?
        for entry in entries {
            if let current = best, entry.score < current.score { continue }
            best = entry
        }
        return best
    }
}
