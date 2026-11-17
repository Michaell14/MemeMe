import AppKit
import MemeMeCore
import SwiftUI

/// The face editor, under the drawer's body while you edit the face the camera caught (`FaceEditSession`); the drawer
/// grows down to make room, so the tiles above never move.
///
/// Left, the face drawn from its seven numbers, the way the search reads it: round dots move a feature, the squares on
/// the rings set how much a part counts (a ring glows brighter the more its part counts, dashed when it's ignored),
/// the top dot tilts the head. Middle, what counts, with − and + per part (the keyboard's and VoiceOver's way to the
/// weights). Right, what the handles do, Reset and Undo. The tiles re-rank as you drag; GIPHY is searched once you let go.
struct FaceEditorView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let edit = model.faceEdit {
            HStack(alignment: .top, spacing: 24) {
                FaceCanvas(model: model, edit: edit)
                    .frame(width: Theme.editorFaceSize, height: Theme.editorFaceSize)
                WeightList(model: model, edit: edit)
                    .frame(width: 236, alignment: .topLeading)
                EditorTools(model: model, edit: edit)
                    .frame(maxWidth: .infinity, minHeight: Theme.editorFaceSize, alignment: .topLeading)
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - The face

/// The editor's face: drawn with Canvas from `FaceSketch` (one point per unit at 200 points), taking the drags and the
/// pinches.
private struct FaceCanvas: View {
    @ObservedObject var model: AppModel
    let edit: FaceEditSession

    /// The handle under the pointer: drawn larger, with a cursor that says what it does.
    @State private var hovered: FaceHandle?
    /// The drag in progress began on a handle (true) or on nothing (false: it does nothing); nil between drags.
    @State private var dragOnHandle: Bool?
    @State private var pinchStarted = false
    @State private var pinchRegion: FaceRegion?

    private var scale: CGFloat { Theme.editorFaceSize / CGFloat(FaceSketch.size) }

    var body: some View {
        let sketch = edit.sketch
        let weights = edit.weightValues
        let highlighted = edit.draggedHandle ?? hovered
        let ghost = FaceCanvas.ghost(of: edit)
        Canvas { context, size in
            FaceCanvas.draw(sketch: sketch, weights: weights, highlighted: highlighted, ghost: ghost,
                            in: &context, size: size)
        }
        .contentShape(Circle())
        .gesture(dragGesture(sketch: sketch, weights: weights))
        .simultaneousGesture(pinchGesture(sketch: sketch, weights: weights))
        .onContinuousHover(coordinateSpace: .local) { phase in
            hover(phase, sketch: sketch, weights: weights)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Your face, as the search reads it"))
        .accessibilityHint(Text(verbatim: "Drag a feature to push it further. The list beside it changes how much each part counts."))
    }

    private func point(_ location: CGPoint) -> SketchPoint {
        SketchPoint(x: Double(location.x / scale), y: Double(location.y / scale))
    }

    private func dragGesture(sketch: FaceSketch, weights: [FaceRegion: Double]) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if dragOnHandle == nil {
                    let start = sketch.toFace(point(value.startLocation))
                    if let handle = sketch.handle(at: start, weights: weights) {
                        dragOnHandle = true
                        model.beginFaceDrag(handle)
                        NSCursor.closedHand.set()
                    } else {
                        dragOnHandle = false
                    }
                }
                guard dragOnHandle == true else { return }
                let movement = SketchPoint(x: Double(value.translation.width / scale),
                                           y: Double(value.translation.height / scale))
                model.dragFace(by: movement, pointer: point(value.location))
            }
            .onEnded { _ in
                if dragOnHandle == true {
                    model.endFaceDrag()
                }
                dragOnHandle = nil
            }
    }

    /// A pinch on a part changes how much it counts, like dragging its ring's square.
    private func pinchGesture(sketch: FaceSketch, weights: [FaceRegion: Double]) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if !pinchStarted {
                    pinchStarted = true
                    pinchRegion = sketch.region(at: sketch.toFace(point(value.startLocation)), weights: weights)
                    if let region = pinchRegion {
                        model.beginFaceDrag(.ring(region))
                    }
                }
                guard pinchRegion != nil else { return }
                model.pinchFace(by: Double(value.magnification))
            }
            .onEnded { _ in
                if pinchRegion != nil {
                    model.endFaceDrag()
                }
                pinchStarted = false
                pinchRegion = nil
            }
    }

    private func hover(_ phase: HoverPhase, sketch: FaceSketch, weights: [FaceRegion: Double]) {
        switch phase {
        case let .active(location):
            guard dragOnHandle == nil else { return }
            let handle = sketch.handle(at: sketch.toFace(point(location)), weights: weights)
            if hovered != handle { hovered = handle }
            FaceCanvas.cursor(for: handle).set()
        case .ended:
            if hovered != nil { hovered = nil }
            NSCursor.arrow.set()
        }
    }

    /// The part being dragged as it was when the drag began; nil unless a feature is held (not a ring or the tilt).
    static func ghost(of edit: FaceEditSession) -> (sketch: FaceSketch, region: FaceRegion)? {
        guard let handle = edit.draggedHandle, let start = edit.dragStartSketch else { return nil }
        switch handle {
        case .ring, .tilt:
            return nil
        default:
            guard let region = handle.region else { return nil }
            return (sketch: start, region: region)
        }
    }

    static func cursor(for handle: FaceHandle?) -> NSCursor {
        switch handle {
        case .none: return .arrow
        case .ring?: return .resizeLeftRight
        default: return .openHand
        }
    }

    // MARK: Drawing

    /// The well, the head, the rings, the dragged part's starting shape, the features, then the handles.
    static func draw(sketch: FaceSketch, weights: [FaceRegion: Double],
                     highlighted: FaceHandle?, ghost: (sketch: FaceSketch, region: FaceRegion)?,
                     in context: inout GraphicsContext, size: CGSize) {
        let scale = size.width / CGFloat(FaceSketch.size)
        context.scaleBy(x: scale, y: scale)
        context.fill(Path(ellipseIn: CGRect(x: 0, y: 0, width: FaceSketch.size, height: FaceSketch.size)),
                     with: .color(Theme.raised))

        var face = context
        let center = point(FaceSketch.center)
        face.translateBy(x: center.x, y: center.y)
        face.rotate(by: .degrees(sketch.tiltDegrees))
        face.translateBy(x: -center.x, y: -center.y)

        var stem = Path()
        stem.move(to: CGPoint(x: 100, y: FaceSketch.tiltHandlePoint.y + 3))
        stem.addLine(to: CGPoint(x: 100, y: FaceSketch.center.y - FaceSketch.headRadius))
        face.stroke(stem, with: .color(Theme.line), lineWidth: 1.2)
        face.stroke(circle(center, CGFloat(FaceSketch.headRadius)), with: .color(Theme.line), lineWidth: 2)

        // The rings: brighter the more their part counts, dashed when it's ignored.
        for region in FaceRegion.allCases {
            let weight = weights[region] ?? 1
            let ring = sketch.ring(region, weight: weight)
            let rect = CGRect(x: ring.minX, y: ring.minY, width: ring.width, height: ring.height)
            let shape = Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2)
            if weight <= 0.05 {
                face.stroke(shape, with: .color(Theme.mutedText), style: StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
            } else {
                let lift: Double = highlighted == .ring(region) ? 0.15 : 0
                face.fill(shape, with: .color(Theme.text.opacity(0.03 + 0.025 * weight)))
                face.stroke(shape, with: .color(Theme.text.opacity(min(1, 0.25 + 0.15 * weight + lift))), lineWidth: 1.5)
            }
        }

        // The dragged part where it started, dashed, so you see how far you pushed it.
        if let ghost {
            let dashed = StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [3, 3])
            let shading = GraphicsContext.Shading.color(Theme.mutedText)
            switch ghost.region {
            case .brows:
                for side in FaceSide.allCases {
                    face.stroke(browPath(ghost.sketch, side), with: shading, style: dashed)
                }
            case .eyes:
                for side in FaceSide.allCases {
                    face.stroke(eyePath(ghost.sketch, side), with: shading, style: dashed)
                }
            case .mouth:
                face.stroke(mouthPath(ghost.sketch), with: shading, style: dashed)
            }
        }

        // The features; an ignored part's are dimmed.
        func ink(_ region: FaceRegion) -> Color {
            Theme.text.opacity((weights[region] ?? 1) <= 0.05 ? 0.35 : 1)
        }
        for side in FaceSide.allCases {
            face.stroke(browPath(sketch, side), with: .color(ink(.brows)), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
        }
        for side in FaceSide.allCases {
            let eye = eyePath(sketch, side)
            face.fill(eye, with: .color(Theme.ground))
            face.stroke(eye, with: .color(ink(.eyes)), lineWidth: 2.2)
            if sketch.pupilRadius > 0 {
                face.fill(circle(point(sketch.pupilCenter(side)), CGFloat(sketch.pupilRadius)), with: .color(ink(.eyes)))
            }
        }
        let mouth = mouthPath(sketch)
        face.fill(mouth, with: .color(Theme.ground))
        face.stroke(mouth, with: .color(ink(.mouth)), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

        for handle in FaceHandle.all {
            let spot = point(sketch.position(of: handle, weights: weights))
            let isHighlighted = handle == highlighted
            if case .ring = handle {
                let side: CGFloat = isHighlighted ? 9 : 7
                let square = Path(roundedRect: CGRect(x: spot.x - side / 2, y: spot.y - side / 2, width: side, height: side),
                                  cornerRadius: 1.5)
                face.fill(square, with: .color(Theme.text))
                face.stroke(square, with: .color(Theme.ground), lineWidth: 1.5)
            } else if isHighlighted {
                face.fill(circle(spot, 9), with: .color(Theme.text.opacity(0.16)))
                face.fill(circle(spot, 4.6), with: .color(Theme.text))
            } else if case .pupil = handle {
                // The pupil is its own handle: no dot over it.
                continue
            } else {
                let radius: CGFloat = handle == .tilt ? 3.5 : 3.2
                face.fill(circle(spot, radius), with: .color(Theme.ground))
                face.stroke(circle(spot, radius), with: .color(Theme.text), lineWidth: 1.6)
            }
        }
    }

    static func point(_ point: SketchPoint) -> CGPoint {
        CGPoint(x: point.x, y: point.y)
    }

    static func browPath(_ sketch: FaceSketch, _ side: FaceSide) -> Path {
        let curve = sketch.brow(side)
        var path = Path()
        path.move(to: point(curve.start))
        path.addQuadCurve(to: point(curve.end), control: point(curve.control))
        return path
    }

    static func eyePath(_ sketch: FaceSketch, _ side: FaceSide) -> Path {
        let center = sketch.eyeCenter(side)
        return Path(ellipseIn: CGRect(x: center.x - FaceSketch.eyeRadiusX, y: center.y - sketch.eyeRadiusY,
                                      width: 2 * FaceSketch.eyeRadiusX, height: 2 * sketch.eyeRadiusY))
    }

    static func mouthPath(_ sketch: FaceSketch) -> Path {
        var path = Path()
        path.move(to: point(sketch.mouthLeft))
        path.addQuadCurve(to: point(sketch.mouthRight), control: point(sketch.upperLipControl))
        path.addQuadCurve(to: point(sketch.mouthLeft), control: point(sketch.lowerLipControl))
        path.closeSubpath()
        return path
    }

    static func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
    }
}

// MARK: - What counts

/// "What counts": a meter of five per part and − and + beside it.
private struct WeightList: View {
    @ObservedObject var model: AppModel
    let edit: FaceEditSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "What counts")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.text)
            Text(verbatim: WeightList.sentence(model.weightSummary))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.mutedText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(FaceRegion.allCases, id: \.self) { region in
                    WeightRow(region: region, weight: edit.weight(region)) { delta in
                        model.stepFaceWeight(region, by: delta)
                    }
                }
            }
            .padding(.top, 14)
        }
    }

    /// The summary as a sentence: "Mostly your mouth".
    static func sentence(_ summary: String?) -> String {
        guard let summary, let first = summary.first else { return "" }
        return first.uppercased() + summary.dropFirst()
    }
}

private struct WeightRow: View {
    let region: FaceRegion
    let weight: Int
    let step: (Int) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: name)
                .font(.system(size: 13))
                .foregroundColor(weight == 0 ? Theme.mutedText : Theme.text)
                .frame(width: 50, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(0..<FaceEditSession.maxWeight, id: \.self) { index in
                    segment(filled: index < weight)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: weight == 0
                ? "\(name): ignored"
                : "\(name): \(weight) of \(FaceEditSession.maxWeight)"))
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                StepButton(symbol: "minus", label: "Make your \(region.rawValue) count less", enabled: weight > 0) {
                    step(-1)
                }
                StepButton(symbol: "plus", label: "Make your \(region.rawValue) count more",
                           enabled: weight < FaceEditSession.maxWeight) {
                    step(1)
                }
            }
        }
        .frame(height: 32)
    }

    @ViewBuilder
    private func segment(filled: Bool) -> some View {
        if weight == 0 {
            Capsule()
                .strokeBorder(Theme.mutedText, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .frame(width: 18, height: 6)
        } else {
            Capsule()
                .fill(filled ? Theme.text : Theme.line)
                .frame(width: 18, height: 6)
        }
    }

    private var name: String {
        region.rawValue.prefix(1).uppercased() + region.rawValue.dropFirst()
    }
}

private struct StepButton: View {
    let symbol: String
    let label: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(enabled ? Theme.text : Theme.mutedText)
                .frame(width: 24, height: 24)
                .background(Circle().fill(enabled ? Theme.raised2 : Theme.raised))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Text(verbatim: label))
    }
}

// MARK: - Tools

/// What the handles do, Reset and Undo, and the keys.
private struct EditorTools: View {
    @ObservedObject var model: AppModel
    let edit: FaceEditSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "Drag a dot to push a feature further. Drag a square, or pinch on a part, to change how much it counts.")
                .font(.system(size: 11))
                .foregroundColor(Theme.mutedText)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button {
                    model.resetFaceEdit()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(PanelCapsuleButtonStyle())
                .disabled(!edit.isEdited)
                .opacity(edit.isEdited ? 1 : 0.4)
                .help("Back to the face the camera caught")

                Button("Undo") {
                    model.undoFaceEdit()
                }
                .buttonStyle(PanelLinkButtonStyle())
                .disabled(!edit.canUndo)
                .opacity(edit.canUndo ? 1 : 0.4)
                .help("Undo the last change (⌘Z)")
            }
            .padding(.top, 12)
            Spacer(minLength: 10)
            VStack(alignment: .leading, spacing: 6) {
                KeyHint(key: "esc", text: "back to your face")
                KeyHint(key: "⌘Z", text: "undo")
            }
        }
    }
}

private struct KeyHint: View {
    let key: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: key)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.text)
                .padding(.horizontal, 5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Theme.keycapBorder, lineWidth: 1)
                )
            Text(verbatim: text)
                .font(.system(size: 11))
                .foregroundColor(Theme.mutedText)
        }
        .accessibilityElement(children: .combine)
    }
}
