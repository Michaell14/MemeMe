import Foundation

/// Editing the face the camera caught: the face editor shows the caught face drawn from its seven numbers, and what you
/// drag, resize or draw on it changes the search. Holding a face still is how a search starts; this only refines one
/// that was caught.
///
/// - Dragging a feature (`FaceHandle`) changes its number: the feature follows the pointer (`FaceSketch`'s travels).
///   Once a feature was dragged, the face detail the camera read (a wink, a tongue out; `FaceCues`) no longer counts,
///   since the drawing can't show it: the word follows the seven numbers.
/// - Each part (brows, eyes, mouth) counts 0 (ignored) to 5, starting from the automatic weights rounded
///   (`FeatureWeights.automatic`, 1…3). Its ring's handle steps it every `ringStepDistance` dragged; a pinch steps it
///   too; − and + step it by one.
/// - A circle drawn around a part makes it count 5, a scribble over it 0; tears drawn make the word "crying"
///   (`StrokeGesture`).
/// - Every change can be undone; Reset goes back to the face as it was caught (and can be undone too).
public struct FaceEditSession: Equatable, Sendable {
    public static let maxWeight = 5
    /// How far a ring's handle is dragged for each step.
    public static let ringStepDistance: Double = 10
    /// A pinch to twice the size adds this many steps.
    public static let pinchSteps: Double = 5
    static let undoLimit = 50

    /// What the editor shows; undo goes back through these.
    struct Snapshot: Equatable, Sendable {
        var face: FaceFeatures
        var weights: [FaceRegion: Int]
        var tears: [[SketchPoint]]
        var tiltDirection: Double
        var featuresEdited: Bool
    }

    /// A drag in progress: what it holds and what the editor showed when it began.
    struct Drag: Equatable, Sendable {
        var handle: FaceHandle
        var start: Snapshot
        var tiltDegrees: Double
    }

    /// The face the camera caught.
    public let original: ExpressionSample
    public private(set) var face: FaceFeatures
    /// How much each part counts, 0 (ignored) … `maxWeight`.
    public private(set) var weights: [FaceRegion: Int]
    /// Tears drawn on the face (face space).
    public private(set) var tears: [[SketchPoint]]
    /// The way the head tilts in the drawing (headTilt keeps no direction).
    public private(set) var tiltDirection: Double
    /// A feature was dragged: the face detail the camera read no longer counts.
    public private(set) var featuresEdited: Bool

    private let initial: Snapshot
    private var undoStack: [Snapshot] = []
    private var activeDrag: Drag?

    /// Starts from a caught query; nil when it has no face (a pose alone has nothing to edit).
    public init?(query: ExpressionSample, baseline: RestingBaseline) {
        guard let caught = query.face else { return nil }
        let face = caught.clamped()
        let automatic = FeatureWeights.automatic(deviation: baseline.deviation(of: face), poseStrength: 0)
        var weights: [FaceRegion: Int] = [:]
        for region in FaceRegion.allCases {
            weights[region] = FaceEditSession.rounded(automatic[region])
        }
        original = query
        self.face = face
        self.weights = weights
        tears = []
        tiltDirection = 1
        featuresEdited = false
        initial = Snapshot(face: face, weights: weights, tears: [], tiltDirection: 1, featuresEdited: false)
    }

    // MARK: Reading it

    public var sketch: FaceSketch { FaceSketch(face: face, tiltDirection: tiltDirection) }

    /// The weights as the drawing and the ranker take them.
    public var weightValues: [FaceRegion: Double] { weights.mapValues { Double($0) } }

    public func weight(_ region: FaceRegion) -> Int { weights[region] ?? 0 }

    /// The handle a drag in progress holds.
    public var draggedHandle: FaceHandle? { activeDrag?.handle }

    /// The face as it was when the drag in progress began (nil between drags): the editor draws the dragged part's
    /// starting shape dashed under it, so you see how far you pushed it.
    public var dragStartSketch: FaceSketch? {
        activeDrag.map { FaceSketch(face: $0.start.face, tiltDirection: $0.start.tiltDirection) }
    }

    public var canUndo: Bool { !undoStack.isEmpty }

    /// Something differs from the face as it was caught.
    public var isEdited: Bool { snapshot != initial }

    /// What the search uses: the edited face, the caught pose, and the face detail only while no feature was dragged.
    public var sample: ExpressionSample {
        ExpressionSample(face: face, pose: original.pose, shape: featuresEdited ? nil : original.shape,
                         timestamp: original.timestamp, sharpness: original.sharpness)
    }

    /// The ranker's weights: the editor's for the three parts, the pose's share as the caught query gave it.
    public func featureWeights(baseline: RestingBaseline) -> FeatureWeights {
        let deviation = original.face.map { baseline.deviation(of: $0) } ?? [:]
        let automatic = FeatureWeights.automatic(deviation: deviation, poseStrength: original.pose?.gestureStrength ?? 0)
        return automatic.overriding(weightValues)
    }

    /// The search's word: tears make it "crying", else what the edited face reads as.
    public func mood(baseline: RestingBaseline) -> Mood {
        if !tears.isEmpty { return .crying }
        let edited = sample
        return MoodClassifier.mood(for: edited.face, pose: edited.pose, shape: edited.shape, baseline: baseline)
    }

    // MARK: Dragging

    /// Takes hold of a handle; `drag(by:pointer:)` then moves it and `endDrag()` lets go.
    public mutating func beginDrag(_ handle: FaceHandle) {
        if activeDrag != nil { endDrag() }
        activeDrag = Drag(handle: handle, start: snapshot, tiltDegrees: sketch.tiltDegrees)
    }

    /// Moves the held handle: `movement` is how far the pointer went since the drag began and `pointer` where it is
    /// now, both in the drawing's space (tilted as it was when the drag began).
    public mutating func drag(by movement: SketchPoint, pointer: SketchPoint) {
        guard let drag = activeDrag else { return }
        let start = drag.start
        let moved = FaceSketch.turn(movement, by: -drag.tiltDegrees)
        var face = start.face
        var weights = start.weights
        var tiltDirection = start.tiltDirection
        switch drag.handle {
        case .brow:
            face.browRaise = FaceSketch.unit(start.face.browRaise - moved.y / FaceSketch.browTravel)
        case .eyelid:
            face.eyeOpenness = FaceSketch.unit(start.face.eyeOpenness - moved.y / FaceSketch.lidTravel)
        case .pupil:
            face.gazeSide = FaceSketch.unit(start.face.gazeSide + moved.x / FaceSketch.gazeTravel)
        case let .mouthCorner(side):
            let outward = side == .left ? -moved.x : moved.x
            face.smile = FaceSketch.unit(start.face.smile - moved.y / FaceSketch.smileTravel)
            face.mouthWidth = FaceSketch.unit(start.face.mouthWidth + outward / FaceSketch.widthTravel)
        case .lowerLip:
            face.mouthOpenness = FaceSketch.unit(start.face.mouthOpenness + moved.y / FaceSketch.openTravel)
        case .tilt:
            let tilt = FaceSketch.tilt(towards: pointer)
            face.headTilt = tilt.headTilt
            tiltDirection = tilt.direction
        case let .ring(region):
            let steps = (moved.x / FaceEditSession.ringStepDistance).rounded()
            weights[region] = FaceEditSession.clampWeight((start.weights[region] ?? 0) + Int(steps))
        }
        self.face = face
        self.weights = weights
        self.tiltDirection = tiltDirection
        if case .ring = drag.handle {
            featuresEdited = start.featuresEdited
        } else {
            featuresEdited = start.featuresEdited || face != start.face
        }
    }

    /// A pinch on a part while its ring is held (`beginDrag(.ring(region))`): `magnification` 1 changes nothing, 2
    /// adds `pinchSteps`, 0.5 takes half of them away.
    public mutating func pinch(by magnification: Double) {
        guard let drag = activeDrag, case let .ring(region) = drag.handle, magnification.isFinite,
              magnification > 0 else { return }
        let steps = (log2(magnification) * FaceEditSession.pinchSteps).rounded()
        weights[region] = FaceEditSession.clampWeight((drag.start.weights[region] ?? 0) + Int(steps))
    }

    /// Lets go of the held handle. A drag that changed something can be undone.
    public mutating func endDrag() {
        guard let drag = activeDrag else { return }
        activeDrag = nil
        if snapshot != drag.start {
            remember(drag.start)
        }
    }

    // MARK: Steps, strokes, undo

    /// − and +: one step less or more (clamped to 0…`maxWeight`).
    public mutating func step(_ region: FaceRegion, by delta: Int) {
        let value = FaceEditSession.clampWeight(weight(region) + delta)
        guard value != weight(region) else { return }
        remember(snapshot)
        weights[region] = value
    }

    /// Applies what a pen stroke meant; `stroke` is kept when it drew a tear.
    public mutating func apply(_ gesture: StrokeGesture, stroke: [SketchPoint]) {
        let before = snapshot
        switch gesture {
        case let .circle(region):
            weights[region] = FaceEditSession.maxWeight
        case let .scribble(region):
            weights[region] = 0
        case .tear:
            tears.append(stroke)
        }
        if snapshot != before {
            remember(before)
        }
    }

    /// Goes back one change; false when there is none.
    @discardableResult
    public mutating func undo() -> Bool {
        if activeDrag != nil { endDrag() }
        guard let last = undoStack.popLast() else { return false }
        restore(last)
        return true
    }

    /// Back to the face as it was caught.
    public mutating func reset() {
        if activeDrag != nil { endDrag() }
        guard snapshot != initial else { return }
        remember(snapshot)
        restore(initial)
    }

    // MARK: Private

    private var snapshot: Snapshot {
        Snapshot(face: face, weights: weights, tears: tears, tiltDirection: tiltDirection, featuresEdited: featuresEdited)
    }

    private mutating func remember(_ snapshot: Snapshot) {
        undoStack.append(snapshot)
        if undoStack.count > FaceEditSession.undoLimit {
            undoStack.removeFirst(undoStack.count - FaceEditSession.undoLimit)
        }
    }

    private mutating func restore(_ snapshot: Snapshot) {
        face = snapshot.face
        weights = snapshot.weights
        tears = snapshot.tears
        tiltDirection = snapshot.tiltDirection
        featuresEdited = snapshot.featuresEdited
    }

    static func clampWeight(_ value: Int) -> Int {
        max(0, min(maxWeight, value))
    }

    /// An automatic weight (1…3) as a step.
    static func rounded(_ weight: Double) -> Int {
        guard weight.isFinite else { return 1 }
        return clampWeight(Int(weight.rounded()))
    }
}
