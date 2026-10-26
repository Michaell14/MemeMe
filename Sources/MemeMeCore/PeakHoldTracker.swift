import Foundation

/// Tuning for `PeakHoldTracker`.
public struct PeakHoldConfig: Sendable {
    public var holdDuration: TimeInterval = 0.3
    public var newExpressionHold: TimeInterval = 1.0
    public var strongerRatio: Double = 1.15
    public var sameDirectionCosine: Double = 0.85
    public var minimumIntensity: Double = 0.12
    public var bufferWindow: TimeInterval = 0.5

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
    public private(set) var lastSample: ExpressionSample?
    public private(set) var lastFaceTimestamp: TimeInterval?    // timestamp of the last sample that had a face

    /// A frame with its effective intensity and unit direction (7 signed deviations + pose activity).
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
    private var lastFaceSample: ExpressionSample?

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
        guard let face = sample.face else {
            clearCandidate()
            return false
        }
        lastFaceTimestamp = sample.timestamp
        lastFaceSample = sample

        // Judge the frame against the baseline as it was when the frame arrived, then let calm frames refine it.
        let entry = makeEntry(for: sample, face: face)
        baseline.observe(face)

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
                guard best.intensity >= queryIntensity * config.strongerRatio else {
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
        holdProgress = min(1, max(0, progress))
        return false
    }

    /// Space: makes the last sample with a face the query, even if neutral. Returns true if it changed the query.
    @discardableResult
    public func snap() -> Bool {
        guard let sample = lastFaceSample, let face = sample.face else { return false }
        if query == sample { return false }
        let entry = makeEntry(for: sample, face: face)
        query = sample
        queryIntensity = entry.intensity
        queryDirection = entry.direction
        clearCandidate()
        return true
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
        holdProgress = 0
        candidateIsNewExpression = false
    }

    private func makeEntry(for sample: ExpressionSample, face: FaceFeatures) -> Entry {
        let activity = sample.pose?.activity ?? 0
        let intensity = max(baseline.intensity(of: face), 0.8 * activity)
        var deviation = baseline.signedDeviation(of: face)
        deviation.append(activity)
        return Entry(sample: sample, intensity: intensity, direction: VectorMath.normalized(deviation))
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
