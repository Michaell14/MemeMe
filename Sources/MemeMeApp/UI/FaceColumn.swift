import AppKit
import MemeMeCore
import SwiftUI

/// The camera's column, beside the grid while face search is on (⌘F) or an image is searched with: your face, live, in a
/// circle, its parts glowing by how much they count (the part the search leans on in the signal color); a click on a
/// part leans the search on it. Under it the word the search goes by and what it was read from, else the hint; then a
/// meter for each part, which leans on it too. While the face editor is open the mirror dims and the hint offers
/// "Back to your face".
struct FaceColumn: View {
    @ObservedObject var model: AppModel

    /// The ring's flash when a pose becomes the search: 1 the moment it is caught, fading out.
    @State private var catchFlash: Double = 0

    private let size: CGFloat = Theme.faceMirrorSize
    /// The ring sits 2 pt outside the mirror and is 3 pt wide.
    private let ringInset: CGFloat = -3.5

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            mirror
                .padding(.top, 16)
            if model.faceEdit == nil, let readout = model.readout {
                ReadoutCaption(readout: readout, detail: leanCaption)
            } else {
                hint
            }
            if showsMeters {
                meters
            }
            Spacer(minLength: 0)
        }
        .frame(width: Theme.faceColumnWidth - Theme.gridPadding, alignment: .top)
    }

    /// Under the word: which part the search leans on, if one.
    private var leanCaption: String? {
        model.leanRegion.map { "Leaning on your \($0.rawValue). Click again to undo." }
    }

    private var showsMeters: Bool {
        model.mode == .live && model.faceEdit == nil && !model.mirrorWeights.isEmpty
    }

    // MARK: Meters

    /// Brows, eyes and mouth, each with how much it counts (five steps); a click leans the search on it.
    private var meters: some View {
        VStack(spacing: 2) {
            ForEach(FaceRegion.allCases, id: \.self) { region in
                meterRow(region)
            }
        }
        .frame(width: 176)
    }

    private func meterRow(_ region: FaceRegion) -> some View {
        let leaned = model.leanRegion == region
        let level = PartMeter.level(of: model.mirrorWeights[region] ?? 0)
        return Button {
            model.leanOn(region)
        } label: {
            HStack {
                Text(verbatim: region.rawValue.capitalized)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(leaned ? Theme.text : Theme.softTitle)
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { step in
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(step < level ? (leaned ? Theme.accent : Theme.text) : Theme.line)
                            .frame(width: 15, height: 5)
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(leaned ? Theme.glassFillStrong : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.showsFaceResults)
        .help(leaned ? "Stop leaning on your \(region.rawValue)" : "Lean the search on your \(region.rawValue)")
        .accessibilityLabel(Text(verbatim: "\(region.rawValue.capitalized), \(level) of 5"
            + (leaned ? ", leaned on" : "")))
    }

    // MARK: Mirror

    private var mirror: some View {
        ZStack {
            Theme.mirrorBackground
            mirrorContent
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            // The ring's track: a quiet edge that the hold fills.
            Circle()
                .stroke(Theme.glassFillStrong, lineWidth: 3)
                .padding(ringInset)
                .allowsHitTesting(false)
        }
        .overlay {
            // Fills while an expression or pose is held; a hold that is lost winds back instead of blinking off.
            // White, not the signal color: nothing is done yet.
            if model.mode == .live {
                Circle()
                    .trim(from: 0, to: CGFloat(min(1, max(0, model.holdProgress))))
                    .stroke(Theme.text, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(ringInset)
                    .opacity(model.holdProgress >= 0.05 ? 1 : 0)
                    .animation(.easeOut(duration: 0.25), value: model.holdProgress)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            // A pose became the search: the ring flashes in the signal color and fades.
            Circle()
                .stroke(Theme.green, lineWidth: 3)
                .padding(ringInset)
                .opacity(catchFlash)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay {
            // Clip me: the ring fills in the signal color while a moving sticker records, the picture flashes when
            // it's taken, and dims while you're cut out.
            ClipMirrorOverlay(capture: model.capture, isCutting: model.isCutting, ringInset: ringInset)
        }
        .overlay(alignment: .bottomTrailing) {
            if model.faceSearchOn && model.mode == .live {
                ClipMirrorButton(model: model, capture: model.capture)
                    .offset(x: 2, y: 2)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if model.canEditFace {
                editButton
            }
        }
        .onChange(of: model.poseCatches) { _, _ in
            catchFlash = 1
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 40_000_000)
                withAnimation(.easeOut(duration: 0.6)) {
                    catchFlash = 0
                }
            }
        }
    }

    /// Opens the face editor (also ⌘E). Above the mirror, like the camera button.
    private var editButton: some View {
        Button {
            model.openFaceEditor()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.text)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.glassFillStrong))
                .overlay(Circle().strokeBorder(Theme.glassEdge, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .offset(x: -2, y: 2)
        .help("Edit your face: push a feature further, or draw on it (⌘E)")
        .accessibilityLabel("Edit your face")
    }

    @ViewBuilder
    private var mirrorContent: some View {
        switch model.mode {
        case .live:
            if model.faceEdit != nil {
                // The editor's face below is the search now; the camera only shows you.
                LiveMirror(camera: model.camera, weights: [:], highlighted: nil, onRegionClick: nil)
                    .opacity(0.35)
            } else {
                LiveMirror(camera: model.camera, weights: model.mirrorWeights, highlighted: model.leanRegion,
                           onRegionClick: model.showsFaceResults ? { model.leanOn($0) } : nil)
            }
        case .text:
            if model.showsFaceToken {
                LiveMirror(camera: model.camera, weights: [:], highlighted: nil, onRegionClick: nil)
                    .opacity(0.35)
            } else {
                MirrorSilhouette(size: size)
            }
        case .image, .moreLike:
            QueryImageMirror(url: model.queryImageURL ?? model.moreLikeItem?.fileURL, size: size)
        case .cameraOff:
            DropWell(size: size)
        case .idle, .prompt, .warming, .cameraBusy:
            MirrorSilhouette(size: size)
        }
    }

    // MARK: Hint

    private var hint: some View {
        VStack(alignment: .center, spacing: 4) {
            Text(model.hint.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = model.hint.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.mutedText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle = model.hint.actionTitle, !actionTitle.isEmpty {
                Button(actionTitle) {
                    model.performHintAction()
                }
                .buttonStyle(PanelCapsuleButtonStyle(
                    fontSize: 11,
                    foreground: keptStyle ? Theme.green : Theme.text
                ))
                .padding(.top, 2)
            }
        }
        .frame(width: 180)
    }

    /// "Kept · Undo" reads as a confirmation.
    private var keptStyle: Bool {
        model.mode == .image && model.imageKept
    }
}

/// How much a part counts, as five steps: the automatic weights run 1...3 (a part leaned on, 3), the editor's 0...5.
enum PartMeter {
    static func level(of weight: Double) -> Int {
        guard weight > 0.05 else { return 0 }
        return min(5, max(1, Int((weight / FaceLean.leanedWeight * 5).rounded())))
    }
}

/// The word the search goes by, under the mirror, and what it was read from ("your face", "your pose", "face and
/// pose"), then `detail`. Sparkles when the on-device model named a pose with no word of its own.
private struct ReadoutCaption: View {
    let readout: MoodReadout
    var detail: String?

    var body: some View {
        VStack(spacing: 3) {
            Text(verbatim: readout.word)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.text)
                .lineLimit(1)
            HStack(spacing: 4) {
                Image(systemName: symbolName)
                    .font(.system(size: 10))
                    .accessibilityHidden(true)
                Text(verbatim: caption)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .foregroundColor(Theme.mutedText)
            if let detail {
                Text(verbatim: detail)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.mutedText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .frame(width: 180)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Searching \(readout.word), read from \(caption)" + (detail.map { ". \($0)" } ?? "")))
    }

    private var symbolName: String {
        if readout.named { return "sparkles" }
        return readout.source == .face ? "face.smiling" : "figure.arms.open"
    }

    private var caption: String {
        switch readout.source {
        case .face: return "your face"
        case .pose: return "your pose"
        case .faceAndPose: return "face and pose"
        }
    }
}

// MARK: - Mirror contents

/// The live camera, its parts glowing by `weights` (`highlighted` in the signal color). Observes the camera so the glows
/// follow the face. A click on a glowing part calls `onRegionClick`.
private struct LiveMirror: View {
    @ObservedObject var camera: CameraController
    let weights: [FaceRegion: Double]
    let highlighted: FaceRegion?
    let onRegionClick: ((FaceRegion) -> Void)?

    var body: some View {
        CameraPreviewView(
            session: camera.session,
            regionRects: weights.isEmpty ? [:] : camera.regionRects,
            weights: weights,
            onClick: nil,
            onRegionClick: onRegionClick,
            highlighted: highlighted
        )
        .allowsHitTesting(onRegionClick != nil)
        .accessibilityLabel(Text(verbatim: onRegionClick == nil
            ? "Your live camera, mirrored"
            : "Your live camera, mirrored. Click your brows, eyes or mouth to lean the search on it"))
    }
}

/// The image being searched with (dropped / pasted image, or the "more like this" result).
private struct QueryImageMirror: View {
    let url: URL?
    let size: CGFloat

    @State var image: NSImage? = nil

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The image you are searching with")
        .task(id: url) { @MainActor in
            guard let url else {
                image = nil
                return
            }
            if let cached = ThumbnailCache.shared.cached(url) {
                image = cached
                return
            }
            let loaded = await ThumbnailCache.shared.thumbnail(for: url, maxPixel: 320)
            if !Task.isCancelled {
                image = loaded
            }
        }
    }
}

/// Head-and-shoulders placeholder while the camera is off or starting.
private struct MirrorSilhouette: View {
    let size: CGFloat

    var body: some View {
        SilhouetteShape()
            .fill(Theme.text.opacity(0.18))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Dashed drop well shown when the camera is denied.
private struct DropWell: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Theme.keycapBorder, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                .padding(6)
            VStack(spacing: 4) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 16))
                    .accessibilityHidden(true)
                Text("Drop an image")
                    .font(.system(size: 10))
                    .multilineTextAlignment(.center)
            }
            .foregroundColor(Theme.mutedText)
            .padding(14)
        }
        .frame(width: size, height: size)
    }
}

/// Head (circle) and shoulders (two curves) in a 100 × 100 design space.
private struct SilhouetteShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scaleX = rect.width / 100
        let scaleY = rect.height / 100
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scaleX, y: rect.minY + y * scaleY)
        }
        var path = Path()
        path.addEllipse(in: CGRect(
            x: rect.minX + 30 * scaleX,
            y: rect.minY + 18 * scaleY,
            width: 40 * scaleX,
            height: 40 * scaleY
        ))
        path.move(to: point(14, 100))
        path.addQuadCurve(to: point(50, 72), control: point(16, 74))
        path.addQuadCurve(to: point(86, 100), control: point(84, 74))
        path.closeSubpath()
        return path
    }
}

/// The mirror while Clip me works: the recording ring and its seconds, the shutter's flash, the dim while cutting.
private struct ClipMirrorOverlay: View {
    @ObservedObject var capture: CaptureModel
    let isCutting: Bool
    let ringInset: CGFloat
    @State private var flash: Double = 0

    var body: some View {
        ZStack {
            if case let .recording(progress) = capture.phase {
                Circle()
                    .trim(from: 0, to: CGFloat(min(1, max(0, progress))))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(ringInset)
                VStack {
                    HStack(spacing: 5) {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                        Text(String(format: "%.1f s", progress * CaptureRenderer.maximumClipDuration))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundColor(Theme.text)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(.top, 14)
                    Spacer()
                }
            }
            if isCutting || capture.phase == .saving {
                Circle().fill(Color.black.opacity(0.45))
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.text)
            }
            Circle()
                .fill(Color.white)
                .opacity(flash)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: capture.flashCount) { _, _ in
            flash = 0.8
            withAnimation(.easeOut(duration: 0.35)) { flash = 0 }
        }
    }
}

/// On the mirror's edge, while face search is on: Clip me. Tap for a still sticker; hold for a moving one.
private struct ClipMirrorButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var capture: CaptureModel
    @State private var pressed = false

    var body: some View {
        let recording: Bool = {
            if case .recording = capture.phase { return true }
            return false
        }()
        Image(systemName: recording ? "record.circle" : "scissors")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(recording ? Theme.onAccent : Theme.text)
            .frame(width: 28, height: 28)
            .background(Circle().fill(recording ? Theme.accent : Theme.glassFillStrong))
            .overlay(Circle().strokeBorder(Theme.glassEdge, lineWidth: 1))
            .contentShape(Circle())
            .opacity(model.canClip || capture.isBusy ? 1 : 0.5)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        model.clipPress(from: .mouse)
                    }
                    .onEnded { _ in
                        pressed = false
                        model.clipRelease(from: .mouse)
                    }
            )
            .help(model.screenCutHotKeyAvailable
                  ? "Clip me: tap for a sticker of your reaction, hold for a moving one (\(model.screenCutHotKey.label), ⇧Space)"
                  : "Clip me: tap for a sticker of your reaction, hold for a moving one (⇧Space)")
            .accessibilityLabel("Clip me")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.clipTap() }
    }
}
