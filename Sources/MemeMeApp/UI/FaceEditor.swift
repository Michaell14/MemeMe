import AppKit
import MemeMeCore
import SwiftUI

/// Adjust drags the face's handles; Draw reads pen strokes.
enum FaceEditorTool: Equatable {
    case adjust, draw
}

/// The face editor, under the drawer's body while you edit the face the camera caught (`FaceEditSession`); the drawer
/// grows down to make room, so the tiles above never move.
///
/// Left, the face drawn from its seven numbers, the way the search reads it: round dots move a feature, the squares on
/// the rings set how much a part counts (a ring glows brighter the more its part counts, dashed when it's ignored),
/// the top dot tilts the head. With the pen a circle makes a part count most, a scribble ignores it, and tears make the
/// word "crying". Middle, what counts, with − and + per part (the keyboard's and VoiceOver's way to the weights).
/// Right, the tools, Reset and Undo. The tiles re-rank as you drag; GIPHY is searched once you let go.
struct FaceEditorView: View {
    @ObservedObject var model: AppModel
    @State private var tool: FaceEditorTool = .adjust

    var body: some View {
        if let edit = model.faceEdit {
            HStack(alignment: .top, spacing: 24) {
                FaceCanvas(model: model, edit: edit, tool: tool)
                    .frame(width: Theme.editorFaceSize, height: Theme.editorFaceSize)
                WeightList(model: model, edit: edit)
                    .frame(width: 236, alignment: .topLeading)
                EditorTools(model: model, edit: edit, tool: $tool)
                    .frame(maxWidth: .infinity, minHeight: Theme.editorFaceSize, alignment: .topLeading)
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - The face

/// The editor's face: drawn with Canvas from `FaceSketch` (one point per unit at 200 points), taking the drags, the
/// pinches and the pen.
private struct FaceCanvas: View {
    @ObservedObject var model: AppModel
    let edit: FaceEditSession
    let tool: FaceEditorTool

    /// The handle under the pointer: drawn larger, with a cursor that says what it does.
    @State private var hovered: FaceHandle?
    /// The drag in progress began on a handle (true) or on nothing (false: it does nothing); nil between drags.
    @State private var dragOnHandle: Bool?
    /// The stroke being drawn with the pen (face space).
    @State private var stroke: [SketchPoint] = []
    /// A circle or scribble just read, fading out as it turns into the ring's change.
    @State private var fading: [SketchPoint] = []
    @State private var fadeOpacity: Double = 0
    @State private var pinchStarted = false
    @State private var pinchRegion: FaceRegion?

    private var scale: CGFloat { Theme.editorFaceSize / CGFloat(FaceSketch.size) }

    var body: some View {
        let sketch = edit.sketch
        let weights = edit.weightValues
        let highlighted = edit.draggedHandle ?? hovered
        let showsHandles = tool == .adjust
        let tears = edit.tears
        let drawing = stroke
        let ghost = FaceCanvas.ghost(of: edit)
        Canvas { context, size in
            FaceCanvas.draw(sketch: sketch, weights: weights, tears: tears, stroke: drawing, handles: showsHandles,
                            highlighted: highlighted, ghost: ghost, in: &context, size: size)
        }
        .overlay {
            SketchStroke(points: fading, tiltDegrees: sketch.tiltDegrees)
                .stroke(Theme.text, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                .opacity(fadeOpacity)
                .allowsHitTesting(false)
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
                let pointer = point(value.location)
                switch tool {
                case .adjust:
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
                    model.dragFace(by: movement, pointer: pointer)
                case .draw:
                    let facePoint = sketch.toFace(pointer)
                    if let last = stroke.last, last.distance(to: facePoint) < 1.5 { return }
                    stroke.append(facePoint)
                }
            }
            .onEnded { _ in
                switch tool {
                case .adjust:
                    if dragOnHandle == true {
                        model.endFaceDrag()
                    }
                    dragOnHandle = nil
                case .draw:
                    let drawn = stroke
                    stroke = []
                    if let gesture = model.drawOnFace(drawn), gesture != .tear {
                        fade(drawn)
                    }
                }
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
            guard tool == .adjust else {
                if hovered != nil { hovered = nil }
                NSCursor.crosshair.set()
                return
            }
            let handle = sketch.handle(at: sketch.toFace(point(location)), weights: weights)
            if hovered != handle { hovered = handle }
            FaceCanvas.cursor(for: handle).set()
        case .ended:
            if hovered != nil { hovered = nil }
            NSCursor.arrow.set()
        }
    }

    /// Shows a stroke that was just read for a moment, fading.
    private func fade(_ points: [SketchPoint]) {
        fading = points
        fadeOpacity = 0.8
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            withAnimation(.easeOut(duration: 0.7)) {
                fadeOpacity = 0
            }
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

    /// The well, the head, the rings, the dragged part's starting shape, the features, tears and the pen's stroke, then
    /// the handles (Adjust only).
    static func draw(sketch: FaceSketch, weights: [FaceRegion: Double], tears: [[SketchPoint]], stroke: [SketchPoint],
                     handles: Bool, highlighted: FaceHandle?, ghost: (sketch: FaceSketch, region: FaceRegion)?,
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

        if handles {
            var stem = Path()
            stem.move(to: CGPoint(x: 100, y: FaceSketch.tiltHandlePoint.y + 3))
            stem.addLine(to: CGPoint(x: 100, y: FaceSketch.center.y - FaceSketch.headRadius))
            face.stroke(stem, with: .color(Theme.line), lineWidth: 1.2)
        }
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

        let pen = StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
        for tear in tears {
            face.stroke(polyline(tear), with: .color(Theme.text.opacity(0.95)), style: pen)
        }
        if !stroke.isEmpty {
            face.stroke(polyline(stroke), with: .color(Theme.text.opacity(0.8)), style: pen)
        }

        guard handles else { return }
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

    static func polyline(_ points: [SketchPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: point(first))
        for next in points.dropFirst() {
            path.addLine(to: point(next))
        }
        return path
    }
}

/// A pen stroke in face space over the editor's face: a stroke just read, fading out.
private struct SketchStroke: Shape {
    let points: [SketchPoint]
    let tiltDegrees: Double

    func path(in rect: CGRect) -> Path {
        let scale = rect.width / CGFloat(FaceSketch.size)
        let center = CGPoint(x: FaceSketch.center.x, y: FaceSketch.center.y)
        let tilt = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: CGFloat(tiltDegrees * Double.pi / 180))
            .translatedBy(x: -center.x, y: -center.y)
        return FaceCanvas.polyline(points)
            .applying(tilt.concatenating(CGAffineTransform(scaleX: scale, y: scale)))
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

/// Adjust or Draw, what the tool does, the last stroke's notice, Reset and Undo, and the keys.
private struct EditorTools: View {
    @ObservedObject var model: AppModel
    let edit: FaceEditSession
    @Binding var tool: FaceEditorTool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToolPicker(tool: $tool)
            Text(verbatim: tool == .adjust
                ? "Drag a dot to push a feature further. Drag a square, or pinch on a part, to change how much it counts."
                : "Circle a part to make it count most, scribble one out to ignore it, or draw what the camera missed.")
                .font(.system(size: 11))
                .foregroundColor(Theme.mutedText)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            if let notice = model.editorNotice {
                // What the pen just did, with its own Undo when it changed something.
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: notice.text)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if showsNoticeUndo {
                        Button("Undo") {
                            model.undoFaceEdit()
                        }
                        .buttonStyle(PanelLinkButtonStyle(fontSize: 12))
                        .help("Undo what the pen just did (⌘Z)")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
                .padding(.top, 12)
            }
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

                if !showsNoticeUndo {
                    Button("Undo") {
                        model.undoFaceEdit()
                    }
                    .buttonStyle(PanelLinkButtonStyle())
                    .disabled(!edit.canUndo)
                    .opacity(edit.canUndo ? 1 : 0.4)
                    .help("Undo the last change (⌘Z)")
                }
            }
            .padding(.top, 12)
            Spacer(minLength: 10)
            VStack(alignment: .leading, spacing: 6) {
                KeyHint(key: "esc", text: "back to your face")
                KeyHint(key: "⌘Z", text: "undo")
            }
        }
    }

    /// The pen's notice carries Undo (and the row below leaves it out) while it describes a change Undo takes back.
    private var showsNoticeUndo: Bool {
        (model.editorNotice?.undoable ?? false) && edit.canUndo
    }
}

private struct ToolPicker: View {
    @Binding var tool: FaceEditorTool

    var body: some View {
        HStack(spacing: 2) {
            segment(.adjust, title: "Adjust", symbol: "arrow.up.and.down.and.arrow.left.and.right")
            segment(.draw, title: "Draw", symbol: "pencil.tip")
        }
        .padding(2)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raised))
    }

    private func segment(_ value: FaceEditorTool, title: String, symbol: String) -> some View {
        let selected = tool == value
        return Button {
            tool = value
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
                Text(verbatim: title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(selected ? Theme.text : Theme.mutedText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Theme.raised2 : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
