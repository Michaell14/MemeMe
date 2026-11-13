import AppKit
import MemeMeCore
import SwiftUI

/// Left column of the drawer's body: your face, live, in a circle, its parts glowing by how much they count; under it
/// what the camera read it as ("your face", "your pose") and what counts most, else the hint; and, until you have
/// memes, "Find my memes". The word itself goes up beside the notch, in the query field. While the face editor is open
/// the mirror dims and the hint offers "Back to your face".
/// The circle is 216 pt while you make a face (the panel just opened: small changes are easy to see, and the parts
/// being read glow while you hold one) and 104 pt once a face is caught, so the tiles take over before you pick.
struct MirrorColumn: View {
    @ObservedObject var model: AppModel

    /// The ring's flash when a pose becomes the search: 1 the moment it is caught, fading out.
    @State private var catchFlash: Double = 0
    /// "Look in Documents…" was clicked: gone at once, before the indexer reports the folder.
    @State private var documentsAdded = false

    private var size: CGFloat {
        model.mirrorIsLarge ? Theme.largeMirrorSize : Theme.mirrorSize
    }
    /// The ring sits 2 pt outside the mirror and is 3 pt wide.
    private let ringInset: CGFloat = -3.5

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            mirror
            if model.faceEdit == nil, let readout = model.readout {
                ReadoutCaption(readout: readout, detail: model.weightSummary)
            } else {
                hint
            }
            libraryAction
        }
        .frame(width: size, alignment: .top)
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
                .stroke(Theme.raised2, lineWidth: 3)
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
        .overlay(alignment: .bottomTrailing) {
            if model.canOpenCapture {
                captureButton
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

    /// Opens the face editor (also ⌘E, or a click on your face). Above the mirror, like the camera button.
    private var editButton: some View {
        Button {
            model.openFaceEditor()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.text)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.raised2))
                .overlay(Circle().strokeBorder(Theme.ground, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .offset(x: -2, y: 2)
        .help("Edit your face: push a feature further, or change how much it counts (⌘E)")
        .accessibilityLabel("Edit your face")
    }

    /// Opens the capture view (also ⇧Space). Above the mirror, so its clicks never open the face editor.
    private var captureButton: some View {
        Button {
            model.openCapture()
        } label: {
            Image(systemName: "camera.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.text)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.raised2))
                .overlay(Circle().strokeBorder(Theme.ground, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .offset(x: 2, y: 2)
        .help("Send yourself: a photo or GIF of you to paste (⇧Space)")
        .accessibilityLabel("Send yourself")
    }

    @ViewBuilder
    private var mirrorContent: some View {
        switch model.mode {
        case .live:
            if model.faceEdit != nil {
                // The editor's face below is the search now; the camera only shows you.
                LiveMirror(camera: model.camera, weights: [:], onClick: nil)
                    .opacity(0.35)
            } else {
                LiveMirror(camera: model.camera, weights: model.mirrorWeights,
                           onClick: model.canEditFace ? { model.openFaceEditor() } : nil)
            }
        case .text:
            if model.showsFaceToken {
                LiveMirror(camera: model.camera, weights: [:], onClick: nil)
                    .opacity(0.35)
            } else {
                MirrorSilhouette(size: size)
            }
        case .image, .moreLike:
            QueryImageMirror(url: model.queryImageURL ?? model.moreLikeItem?.fileURL, size: size)
        case .cameraOff:
            DropWell(size: size)
        case .prompt, .warming, .cameraBusy:
            MirrorSilhouette(size: size)
        }
    }

    // MARK: Hint

    private var hint: some View {
        VStack(alignment: .center, spacing: 4) {
            Text(model.hint.title)
                .font(.system(size: 12, weight: .semibold))
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
        .frame(width: size)
    }

    /// "Kept · Undo" reads as a confirmation.
    private var keptStyle: Bool {
        model.mode == .image && model.imageKept
    }

    // MARK: Library

    /// "Find my memes" until you have memes (Downloads, Desktop and your screenshots; the menu has it too), or, when a
    /// typed search found few and Documents isn't watched, "Look in Documents…".
    @ViewBuilder
    private var libraryAction: some View {
        if showsLookInDocuments {
            Button("Look in Documents…") {
                guard let url = documentsURL else { return }
                documentsAdded = true
                model.indexer.addWatchedFolders([url])
            }
            .buttonStyle(PanelCapsuleButtonStyle(fontSize: 11, foreground: Theme.text))
        } else if !model.hasMemes && model.offersFindMyMemes {
            Button("Find my memes") {
                model.findMyMemes()
            }
            .buttonStyle(PanelCapsuleButtonStyle(fontSize: 11, foreground: Theme.text))
            .help("Collect the memes in Downloads, Desktop and your screenshots")
        }
    }

    private var documentsURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.standardizedFileURL
    }

    private var showsLookInDocuments: Bool {
        guard model.mode == .text, !documentsAdded, model.results.count < Theme.columns,
              let url = documentsURL else { return false }
        return !model.indexer.isWatching(url)
    }
}

/// What the word beside the notch was read from ("your face", "your pose", "your face and pose"), under the mirror,
/// and what counts most in it ("mostly your brows"): the mirror's glow in words.
/// Sparkles when the on-device model named a pose with no word of its own; the rule's phrase shows the pose's figure.
private struct ReadoutCaption: View {
    let readout: MoodReadout
    var detail: String?

    var body: some View {
        VStack(spacing: 2) {
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Reading \(readout.word) from \(caption)" + (detail.map { ", \($0)" } ?? "")))
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

/// The live camera, its parts glowing by `weights`. Observes the camera so the glows follow the face.
private struct LiveMirror: View {
    @ObservedObject var camera: CameraController
    let weights: [FaceRegion: Double]
    let onClick: (() -> Void)?

    var body: some View {
        CameraPreviewView(
            session: camera.session,
            regionRects: weights.isEmpty ? [:] : camera.regionRects,
            weights: weights,
            onClick: onClick
        )
        .allowsHitTesting(onClick != nil)
        .accessibilityLabel(Text(verbatim: onClick == nil
            ? "Your live camera, mirrored"
            : "Your live camera, mirrored. Click to edit your face"))
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
            let loaded = await ThumbnailCache.shared.thumbnail(for: url, maxPixel: 256)
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
