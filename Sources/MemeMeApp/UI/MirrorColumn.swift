import AppKit
import MemeMeCore
import SwiftUI

/// Left column of the compact strip: the 120 × 120 mirror and the hint under it.
struct MirrorColumn: View {
    @ObservedObject var model: AppModel

    /// The green ring's opacity: 1 the moment a pose is caught, fading out.
    @State private var catchFlash: Double = 0

    private let mirrorSize: CGFloat = 120
    private let mirrorRadius: CGFloat = 18

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            mirror
            hint
        }
        .frame(width: mirrorSize, alignment: .topLeading)
    }

    // MARK: Mirror

    private var mirror: some View {
        ZStack {
            Theme.mirrorBackground
            mirrorContent
        }
        .frame(width: mirrorSize, height: mirrorSize)
        .clipShape(RoundedRectangle(cornerRadius: mirrorRadius, style: .continuous))
        .overlay(alignment: .topLeading) {
            if model.mode == .live, let pose = model.heldPose {
                poseLabel(pose)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.canOpenCapture {
                captureButton
            }
        }
        .overlay(
            // 3 px ring just outside the mirror.
            RoundedRectangle(cornerRadius: mirrorRadius + 1.5, style: .continuous)
                .stroke(model.mode == .live ? Theme.accent : Theme.border, lineWidth: 3)
                .padding(-1.5)
        )
        .overlay {
            // Fills while an expression or pose is held; a hold that is lost winds back instead of blinking off.
            if model.mode == .live {
                RoundedRectangle(cornerRadius: mirrorRadius + 1.5, style: .continuous)
                    .trim(from: 0, to: CGFloat(min(1, max(0, model.holdProgress))))
                    .stroke(Theme.amber, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .padding(-1.5)
                    .opacity(model.holdProgress >= 0.05 ? 1 : 0)
                    .animation(.easeOut(duration: 0.25), value: model.holdProgress)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            // A pose caught: a green ring that fades.
            RoundedRectangle(cornerRadius: mirrorRadius + 2.5, style: .continuous)
                .stroke(Theme.green, lineWidth: 5)
                .padding(-2.5)
                .shadow(color: Theme.green.opacity(0.7), radius: 8)
                .opacity(catchFlash)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
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

    /// The held pose's name on the mirror's top-left corner (the camera button has the bottom right).
    private func poseLabel(_ pose: PoseBadge) -> some View {
        Text(verbatim: pose.label)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .padding(6)
            .allowsHitTesting(false)
            .accessibilityLabel(Text(verbatim: "Your pose: \(pose.label)"))
    }

    /// Opens the capture view (also ⇧Space). Above the mirror, so its clicks never reach the eye and mouth targets.
    private var captureButton: some View {
        Button {
            model.openCapture()
        } label: {
            Image(systemName: "camera.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.black.opacity(0.55)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(7)
        .help("Send yourself: a photo or GIF of you to paste (⇧Space)")
        .accessibilityLabel("Send yourself")
    }

    @ViewBuilder
    private var mirrorContent: some View {
        switch model.mode {
        case .live:
            LiveMirror(camera: model.camera, pins: model.pins, interactive: true) { region in
                model.togglePin(region)
            }
        case .text:
            if model.showsFaceToken {
                LiveMirror(camera: model.camera, pins: model.pins, interactive: false) { _ in }
                    .opacity(0.35)
            } else {
                MirrorSilhouette()
            }
        case .image, .moreLike:
            QueryImageMirror(url: model.queryImageURL ?? model.moreLikeItem?.fileURL)
        case .cameraOff:
            DropWell()
        case .prompt, .warming, .cameraBusy:
            MirrorSilhouette()
        }
    }

    // MARK: Hint

    private var hint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.hint.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.text)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = model.hint.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.mutedText)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle = model.hint.actionTitle, !actionTitle.isEmpty {
                Button(actionTitle) {
                    model.performHintAction()
                }
                .buttonStyle(PanelCapsuleButtonStyle(
                    fontSize: 12,
                    foreground: keptStyle ? Theme.green : Theme.text
                ))
                .padding(.top, 2)
            }
        }
        .frame(width: mirrorSize, alignment: .leading)
    }

    /// "Kept · Undo" reads as a confirmation.
    private var keptStyle: Bool {
        model.mode == .image && model.imageKept
    }
}

// MARK: - Mirror contents

/// The live camera with clickable eyes / mouth. Observes the camera so the overlays follow the face.
private struct LiveMirror: View {
    @ObservedObject var camera: CameraController
    let pins: Set<FaceRegion>
    let interactive: Bool
    let onToggle: (FaceRegion) -> Void

    var body: some View {
        CameraPreviewView(
            session: camera.session,
            regionRects: interactive ? camera.regionRects : [:],
            pins: pins,
            onToggle: onToggle
        )
        .allowsHitTesting(interactive)
        .accessibilityLabel("Your live camera, mirrored")
    }
}

/// The image being searched with (dropped / pasted image, or the "more like this" result).
private struct QueryImageMirror: View {
    let url: URL?

    @State var image: NSImage? = nil

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 120, height: 120)
                    .clipped()
            }
        }
        .frame(width: 120, height: 120)
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
    var body: some View {
        SilhouetteShape()
            .fill(Theme.text.opacity(0.22))
            .frame(width: 120, height: 120)
            .accessibilityHidden(true)
    }
}

/// Dashed drop well shown when the camera is denied.
private struct DropWell: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Theme.keycapBorder, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                .padding(6)
            VStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 18))
                    .accessibilityHidden(true)
                Text("Drop an image")
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
            }
            .foregroundColor(Theme.softText)
            .padding(10)
        }
        .frame(width: 120, height: 120)
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
            x: rect.minX + 27 * scaleX,
            y: rect.minY + 15 * scaleY,
            width: 46 * scaleX,
            height: 46 * scaleY
        ))
        path.move(to: point(8, 100))
        path.addQuadCurve(to: point(50, 78), control: point(12, 80))
        path.addQuadCurve(to: point(92, 100), control: point(88, 80))
        path.closeSubpath()
        return path
    }
}
