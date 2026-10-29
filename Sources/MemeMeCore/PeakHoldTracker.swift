import Foundation

/// Tuning for `PeakHoldTracker`.
public struct PeakHoldConfig: Sendable {
    /// How long an expression is held before it becomes the first query, a version of the query `strongerRatio`
    /// stronger replaces it, or (once the face has been calm for `rearmAfterCalm`) a new expression replaces it.
    public var holdDuration: TimeInterval = 0.3
    /// How long a new expression with a clear gesture is held before it replaces the query: arms on their way to a
    /// pose pass through others. A shape held up only by its strength floor is held this long even after a calm face.
    public var newExpressionHold: TimeInterval = 1.0
    /// How long a new expression of the face (no clear gesture) is held before it replaces the query: another face,
    /// or a tongue out or a wink on the one held.
    public var newFaceHold: TimeInterval = 0.6
    /// A face calm (under `minimumIntensity`) for this long re-arms the tracker: until the next query, a new expression
    /// replaces the query after `holdDuration`, as the first one did. Relaxing between two faces says the second one is
    /// meant; talking never stays calm this long between words.
    public var rearmAfterCalm: TimeInterval = 0.4
    public var strongerRatio: Double = 1.15
    public var sameDirectionCosine: Double = 0.85
    public var minimumIntensity: Double = 0.12
    public var bufferWindow: TimeInterval = 0.5
    /// A frame without a face (a hand over it, say) still counts when its gesture is at least this strong.
    public var minimumGestureWithoutFace: Double = 0.5
    /// A gesture being held survives frames that miss it (a joint lost for a frame, the face flickering at a distance)
    /// for this long; an expression of the face gets no grace.
    public var gestureGrace: TimeInterval = 0.3
    /// After a held gesture, a clear gesture less alike than this (`PoseDescriptor.compare`, the better of as-is and
    /// mirrored) is a new one even with the same word, or none: arms straight up after a star jump, flex after a T-pose.
    public var newPoseSimilarity: Double = 0.6

    public init() {}
}

/// Turns a stream of analyzed frames into a stable query: a held expression becomes the query,
/// relaxing or talking does nothing, a stronger version of the same expression or a different
/// expression held long enough replaces it (`newFaceHold` for a face, `newExpressionHold` for a
/// gesture, only `holdDuration` once the face has relaxed in between).
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

    /// A frame with its effective intensity and unit direction (7 signed face deviations + 9 gesture numbers + 6 face
    /// cues).
    private struct Entry {
        let sample: ExpressionSample
        let intensity: Double
        let direction: [Double]
        /// The pose's gesture strength (0 without a pose).
        let strength: Double
        /// The pose's word (`MoodClassifier.gestureMood`) when the gesture is clear, else nil.
        let word: Mood?
        /// The face's clear cue (`FaceCues.clearCue`: a tongue out, a wink, ...), else nil.
        let cue: FaceCues.Cue?
        /// Each cue's strength, in `FaceCues.Cue.allCases` order (zeros without a shape).
        let cueValues: [Double]
        let shape: BodyShape?
        /// Held up only by the shape's strength floor (hands on hips, arms crossed, a bow): the arms alone are near
        /// rest, and no hand sign or face carries it. Such a shape is held for `newExpressionHold`, so a frame or two
        /// of hands in pockets that happen to look like one don't become the search.
        let isCarriedByShape: Bool

        var score: Double { intensity * sample.sharpness }
    }

    /// Consecutive candidate frames inside the cone of the run's first frame, or with the shape the run holds.
    private struct Run {
        let start: TimeInterval
        let direction: [Double]
        /// The run's first frame, whose face a frame joining by its shape must agree with.
        let first: ExpressionSample
        var entries: [Entry]
        /// The run's first frame was a clear gesture: frames that miss it are bridged for `gestureGrace`.
        let isGesture: Bool
        /// The run's first frame's clear cue: a frame showing another starts a run of its own (`keepsCue`).
        let cue: FaceCues.Cue?
        /// When the run last took a frame.
        var lastAccepted: TimeInterval
        /// The frames skipped since then for lying outside the run (its grace), oldest first: a run started once the
        /// grace is over takes the newest of them that point its way and counts from the first of those, as they were
        /// most likely the new expression already. A frame under a gate in between drops them.
        var skipped: [Entry] = []
    }

    /// What a frame's face says against the baseline: its seven signed deviations, its cues × `cueWeight` (zeros
    /// without a shape), its clear cue, and how strongly it shows (the larger of its intensity and `cueWeight` × its
    /// strongest cue when that is at least `minimumCue`).
    private struct FaceReading {
        let intensity: Double
        let deviation: [Double]
        let cues: [Double]
        let cue: FaceCues.Cue?

        var direction: [Double] { deviation + cues }
    }

    private var run: Run?
    private var queryDirection: [Double]?
    /// The query's pose word, face cue and shape, as read when it became the query.
    private var queryWord: Mood?
    private var queryCue: FaceCues.Cue?
    private var queryShape: BodyShape?
    /// The last sample with a face, or with a gesture strong enough to stand in for one: what `snap` takes.
    private var lastSeenSample: ExpressionSample?
    /// When the face became calm (a frame with a face under `minimumIntensity`); nil while it isn't.
    private var calmSince: TimeInterval?
    /// The face has been calm for `rearmAfterCalm` since the query was set: a new expression needs only
    /// `holdDuration`.
    private var rearmed = false

    /// A gesture weaker than this adds nothing to a frame's intensity (`Ranker.gestureWithoutFace`).
    private static let minimumGesture = Ranker.gestureWithoutFace

    /// A face cue weaker than this adds nothing to a frame's intensity.
    private static let minimumCue = 0.3

    /// A face cue's weight in a frame's intensity and direction, as a clear gesture's in its intensity.
    private static let cueWeight = 0.8

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
            baseline.observe(face, shape: sample.shape)
            noteCalm(entry)
            return hold(entry)
        }
        // A frame without a face isn't calm.
        calmSince = nil
        // No face: only a clear gesture (a facepalm hides the face) keeps the hold going.
        guard (sample.pose?.gestureStrength ?? 0) >= config.minimumGestureWithoutFace else {
            skipUnderGate(at: sample.timestamp)
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
            skipUnderGate(at: sample.timestamp)
            return false
        }

        var current: Run
        // A frame with a shape the run already holds continues it whatever its direction: next to a shape held up
        // only by its strength floor, a far face flickering in and out (or just moving) swings the direction. Not when
        // the face says something else: then its direction decides.
        let continuesShape = entry.shape != nil && (run.map { existing in
            existing.entries.contains { $0.shape == entry.shape } && facesAgree(existing.first, sample)
        } ?? false)
        if let existing = run, keepsCue(entry, existing.cue),
           VectorMath.cosine(entry.direction, existing.direction) >= config.sameDirectionCosine || continuesShape {
            current = existing
            current.entries.append(entry)
            current.lastAccepted = sample.timestamp
            current.skipped = []
            let oldest = sample.timestamp - config.bufferWindow
            current.entries.removeAll { $0.sample.timestamp < oldest }
        } else if bridgesGap(at: sample.timestamp) {
            run?.skipped.append(entry)
            return false
        } else {
            // The skipped frames just before this one that point its way: frames that point elsewhere (a face
            // flickering between two looks, say) give no head start.
            let lead = Array((run?.skipped ?? []).reversed().prefix { skipped in
                keepsCue(skipped, entry.cue)
                    && VectorMath.cosine(skipped.direction, entry.direction) >= config.sameDirectionCosine
            }.reversed())
            current = Run(start: lead.first?.sample.timestamp ?? sample.timestamp, direction: entry.direction, first: sample,
                          entries: lead + [entry], isGesture: entry.strength >= PeakHoldTracker.minimumGesture,
                          cue: entry.cue, lastAccepted: sample.timestamp)
        }

        guard let best = PeakHoldTracker.bestEntry(in: current.entries) else {
            run = current
            return false
        }

        var required: TimeInterval
        if let reference = queryDirection {
            // The same shape is the same expression whatever the direction, unless the faces say different things.
            let sameShapeAsQuery = best.shape != nil && best.shape == queryShape
                && (query.map { facesAgree($0, best.sample) } ?? false)
            let sameDirection = VectorMath.cosine(current.direction, reference) >= config.sameDirectionCosine || sameShapeAsQuery
            if sameDirection, !changesGestureWord(best), !changesCue(best), !isNewPose(best) {
                guard best.intensity >= queryIntensity * config.strongerRatio else {
                    // Same expression, not clearly stronger (relaxing in between changes nothing): nothing to hold
                    // toward. Dropping the run means a later, stronger version is held for the full `holdDuration`
                    // from its first frame.
                    clearCandidate()
                    return false
                }
                required = config.holdDuration
                candidateIsNewExpression = false
            } else {
                required = holdForNewExpression(best)
                candidateIsNewExpression = true
            }
        } else {
            required = config.holdDuration
            candidateIsNewExpression = false
        }
        // A shape held up only by its strength floor needs the long hold even after a calm face.
        if best.isCarriedByShape {
            required = max(required, config.newExpressionHold)
        }

        let elapsed = sample.timestamp - current.start
        let progress = required > 0 ? elapsed / required : 1
        if progress >= 1 - PeakHoldTracker.progressTolerance {
            setQuery(best)
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
        setQuery(makeEntry(for: sample))
        clearCandidate()
        return true
    }

    /// Drops the expression being held toward the query (keeps the query and the baseline): frames stopped coming in
    /// for a while (the capture view was open), so the next one starts a new hold, and a calm face before the gap
    /// doesn't count toward re-arming (`rearmAfterCalm`).
    public func clearHold() {
        clearCandidate()
        calmSince = nil
    }

    /// Clears the query, the candidate and the re-arming (keeps the baseline).
    public func reset() {
        query = nil
        queryIntensity = 0
        queryDirection = nil
        queryWord = nil
        queryCue = nil
        queryShape = nil
        rearmed = false
        calmSince = nil
        clearCandidate()
    }

    // MARK: Private

    /// Makes `entry` the query; the face must relax again (`rearmAfterCalm`) before a new expression is held for only
    /// `holdDuration`.
    private func setQuery(_ entry: Entry) {
        query = entry.sample
        queryIntensity = entry.intensity
        queryDirection = entry.direction
        queryWord = entry.word
        queryCue = entry.cue
        queryShape = entry.shape
        rearmed = false
        calmSince = nil
    }

    /// A frame with a face under `minimumIntensity` (no expression, cue or clear gesture) is calm; calm frames for
    /// `rearmAfterCalm` re-arm the tracker. Any other frame ends the calm, not the re-arming: that lasts until the
    /// next query.
    private func noteCalm(_ entry: Entry) {
        guard entry.intensity < config.minimumIntensity else {
            calmSince = nil
            return
        }
        let timestamp = entry.sample.timestamp
        let since = calmSince ?? timestamp
        calmSince = since
        if timestamp - since >= config.rearmAfterCalm - PeakHoldTracker.progressTolerance {
            rearmed = true
        }
    }

    /// How long a new expression is held before it replaces the query: `holdDuration` once the face has been calm
    /// since the query was set (`rearmAfterCalm`); else `newExpressionHold` for a clear gesture (at least
    /// `minimumGesture`), `newFaceHold` for the face alone.
    private func holdForNewExpression(_ entry: Entry) -> TimeInterval {
        if rearmed {
            return config.holdDuration
        }
        return entry.strength >= PeakHoldTracker.minimumGesture ? config.newExpressionHold : config.newFaceHold
    }

    /// Whether two frames' faces say the same thing: both calm (below `minimumIntensity`, cues included) or not seen,
    /// or both moved the same way, cues included (`sameDirectionCosine`).
    private func facesAgree(_ a: ExpressionSample, _ b: ExpressionSample) -> Bool {
        func expressive(_ sample: ExpressionSample) -> FaceReading? {
            guard let reading = faceReading(of: sample), reading.intensity >= config.minimumIntensity else { return nil }
            return reading
        }
        switch (expressive(a), expressive(b)) {
        case (nil, nil):
            return true
        case let (first?, second?):
            return VectorMath.cosine(first.direction, second.direction) >= config.sameDirectionCosine
        default:
            return false
        }
    }

    /// The face of `sample` against the baseline (`FaceReading`); nil without a face.
    private func faceReading(of sample: ExpressionSample) -> FaceReading? {
        guard let face = sample.face else { return nil }
        let cues = baseline.cues(of: sample.shape)
        let strongest = cues.strongest?.value ?? 0
        let cueIntensity = strongest >= PeakHoldTracker.minimumCue ? PeakHoldTracker.cueWeight * strongest : 0
        return FaceReading(intensity: max(baseline.intensity(of: face), cueIntensity),
                           deviation: baseline.signedDeviation(of: face),
                           cues: cues.values.map { PeakHoldTracker.cueWeight * $0 },
                           cue: cues.clearCue)
    }

    /// Whether a frame keeps a run's clear cue (`cue`): it shows the same one, or none while that one still shows at
    /// `minimumCue` or more (a cue hovering around `FaceCues.clear` doesn't break its own hold). A cue the run didn't
    /// start with starts a run of its own, so one frame of it never names a face held without it.
    private func keepsCue(_ entry: Entry, _ cue: FaceCues.Cue?) -> Bool {
        if entry.cue == cue { return true }
        guard entry.cue == nil, let cue, let index = FaceCues.Cue.allCases.firstIndex(of: cue),
              index < entry.cueValues.count else { return false }
        return entry.cueValues[index] >= PeakHoldTracker.minimumCue
    }

    /// A frame under a gate (no face and no clear gesture, or too little intensity): bridged within a gesture run's
    /// grace, though the frames skipped before it no longer lead into a new run; else the hold is over.
    private func skipUnderGate(at timestamp: TimeInterval) {
        if bridgesGap(at: timestamp) {
            run?.skipped = []
        } else {
            clearCandidate()
        }
    }

    /// Whether a frame that misses the run (under a gate, or another direction without the run's shape) is skipped
    /// rather than ending it: only a gesture run, within `gestureGrace` of the last frame it took.
    private func bridgesGap(at timestamp: TimeInterval) -> Bool {
        guard config.gestureGrace > 0, let run, run.isGesture else { return false }
        return timestamp - run.lastAccepted <= config.gestureGrace + PeakHoldTracker.progressTolerance
    }

    private func clearCandidate() {
        run = nil
        candidate = nil
        holdProgress = 0
        candidateIsNewExpression = false
    }

    /// intensity = max(face intensity, 0.8 × gesture strength when ≥ 0.4, 0.8 × the face's strongest cue when ≥ 0.3);
    /// direction = the face's signed deviations (zeros without a face) + the pose's gesture numbers × 0.5 × its gesture
    /// strength, so arms at rest or on a desk coming into view don't turn the same face into a new expression (a pose
    /// measured the old way: [activity, 0, 0, 0, 0, 0, 0, 0, 0]) + the face's cues × 0.8 (zeros without a shape), so a
    /// tongue out on a held smile points elsewhere. The cues are read against the resting shape (`FaceCues`).
    private func makeEntry(for sample: ExpressionSample) -> Entry {
        let face = faceReading(of: sample)
        let faceIntensity = face?.intensity ?? 0
        // Only a clear gesture stands in for a face: a neutral face with half-raised arms isn't an expression.
        let strength = sample.pose?.gestureStrength ?? 0
        let gesture = strength >= PeakHoldTracker.minimumGesture ? strength : 0
        let intensity = max(faceIntensity, 0.8 * gesture)
        let descriptor = sample.pose?.descriptor
        var direction = face?.deviation ?? [Double](repeating: 0, count: 7)
        if let descriptor {
            direction += descriptor.gestureDirection.map { 0.5 * strength * $0 }
        } else {
            direction += [sample.pose?.activity ?? 0, 0, 0, 0, 0, 0, 0, 0, 0]
        }
        direction += face?.cues ?? [Double](repeating: 0, count: FaceCues.Cue.allCases.count)
        let word = gesture > 0 ? descriptor.flatMap { MoodClassifier.gestureMood($0, face: sample.face, baseline: baseline) } : nil
        let shape = descriptor?.bodyShape
        let isCarriedByShape = shape != nil && gesture > 0
            && (descriptor?.armStrength ?? 0) < PeakHoldTracker.minimumGesture
            && (descriptor?.hand?.signStrength ?? 0) < 0.7
            && faceIntensity < intensity
        let cueValues = face?.cues.map { $0 / PeakHoldTracker.cueWeight }
            ?? [Double](repeating: 0, count: FaceCues.Cue.allCases.count)
        return Entry(sample: sample, intensity: intensity, direction: VectorMath.normalized(direction), strength: strength,
                     word: word, cue: face?.cue, cueValues: cueValues, shape: shape, isCarriedByShape: isCarriedByShape)
    }

    /// A clear gesture (at least `minimumGesture`) with a word the query doesn't have: a facepalm after the hold caught
    /// the hand on its way up (as "clapping", or as nothing yet), a shrug after a held smile, mind blown after a clap.
    /// Strong gestures all reach the same intensity and many point the same way, so the word, not the strength or the
    /// direction, tells them apart: it is a new expression, held for `newExpressionHold` like any other. Forearms on
    /// armrests (a shrug's shape, too weak to be a gesture) aren't one.
    private func changesGestureWord(_ entry: Entry) -> Bool {
        guard query != nil, let word = entry.word else { return false }
        return word != queryWord
    }

    /// A clear face cue (`FaceCues.clearCue`) the query doesn't have: a tongue out or a wink on a held smile, a smirk
    /// after a wink. On a strong face a cue moves the direction and the intensity too little to tell, so the cue does:
    /// it is a new expression, held for `newFaceHold`. The query's own cue on the same face is the same expression; a
    /// cue fading below `FaceCues.clear` isn't a new one.
    private func changesCue(_ entry: Entry) -> Bool {
        guard query != nil, let cue = entry.cue else { return false }
        return cue != queryCue
    }

    /// A clear gesture after a clear gesture that is shaped quite differently (`newPoseSimilarity`), though both have
    /// the same word or none: strong poses all reach the same intensity, and many point the same way, so without this
    /// a second pose could never replace the first. The same shape is never new; poses with too little in common to
    /// compare (an arm out of frame) aren't either.
    private func isNewPose(_ entry: Entry) -> Bool {
        guard let query, entry.strength >= PeakHoldTracker.minimumGesture,
              (query.pose?.gestureStrength ?? 0) >= PeakHoldTracker.minimumGesture,
              let held = query.pose?.descriptor, let new = entry.sample.pose?.descriptor else { return false }
        if let shape = entry.shape, shape == queryShape { return false }
        let similarity = [PoseDescriptor.compare(held, new), PoseDescriptor.compare(held, new.mirrored)]
            .map { $0.coverage >= 0.6 ? $0.similarity : 1 }
            .max() ?? 1
        return similarity < config.newPoseSimilarity
    }

    /// The frame that stands for the run: the highest `intensity * sharpness` (the newest winning ties) among the
    /// frames with the run's word: the word most of its frames have (the newest frame's on a tie), when three or more
    /// have it (the body is read every other frame, so a reading fills two) or the newest does; else among the frames
    /// without one. So one noisy reading neither takes a held pose's word away nor gives one to a pose without; arms
    /// caught rising into a celebration (no word yet) take its word the moment it shows. Frames of the face alone have
    /// no word and all count.
    private static func bestEntry(in entries: [Entry]) -> Entry? {
        guard let newest = entries.last else { return nil }
        var counts: [Mood: Int] = [:]
        for entry in entries {
            if let word = entry.word {
                counts[word, default: 0] += 1
            }
        }
        var word: Mood?
        if let most = counts.values.max() {
            let tied = Set(counts.filter { $0.value == most }.map(\.key))
            let candidate = entries.last(where: { $0.word.map(tied.contains) ?? false })?.word
            if most >= 3 || candidate == newest.word {
                word = candidate
            }
        }
        let pool = entries.filter { $0.word == word }
        return PeakHoldTracker.highestScore(in: pool.isEmpty ? entries : pool)
    }

    /// Highest `intensity * sharpness`; the newest wins ties.
    private static func highestScore(in entries: [Entry]) -> Entry? {
        var best: Entry?
        for entry in entries {
            if let current = best, entry.score < current.score { continue }
            best = entry
        }
        return best
    }
}
