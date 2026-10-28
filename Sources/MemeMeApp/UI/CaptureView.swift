import AppKit
import QuartzCore
import SwiftUI

/// The capture view (replaces the panel's contents): a big mirrored, filtered picture with a shutter, and the filters.
/// Tap the shutter (or Space, ↵) for a photo; hold it for a GIF of up to 3 s. The capture is copied, ready to paste.
struct CaptureView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var capture: CaptureModel

    @State private var shutterDown = false
    @State private var flashOpacity: Double = 0

    private let stageSize: CGFloat = 300
    private let stageRadius: CGFloat = 18
    private let filterColumns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
        _capture = ObservedObject(wrappedValue: model.capture)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                stage
                side
            }
            legend
        }
    }

    // MARK: Stage

    private var stage: some View {
        ZStack(alignment: .bottom) {
            Theme.mirrorBackground
            CapturePreview(camera: model.camera)
            Color.white
                .opacity(flashOpacity)
                .allowsHitTesting(false)
            shutter
                .padding(.bottom, 14)
        }
        .frame(width: stageSize, height: stageSize)
        .clipShape(RoundedRectangle(cornerRadius: stageRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: stageRadius + 1.5, style: .continuous)
                .stroke(Theme.accent, lineWidth: 3)
                .padding(-1.5)
        )
        .overlay {
            if case let .recording(progress) = capture.phase {
                RoundedRectangle(cornerRadius: stageRadius + 1.5, style: .continuous)
                    .trim(from: 0, to: CGFloat(min(1, max(0, progress))))
                    .stroke(Theme.warning, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .padding(-1.5)
                    .animation(.linear(duration: 0.05), value: progress)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: capture.flashCount) { _, _ in
            flashOpacity = 0.85
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 40_000_000)
                withAnimation(.easeOut(duration: 0.3)) {
                    flashOpacity = 0
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your camera, mirrored, with the \(capture.filter.title) filter")
    }

    private var isRecording: Bool {
        if case .recording = capture.phase { return true }
        return false
    }

    /// Press = `press()`, release = `release()`: a short press is a photo, a long one a GIF.
    private var shutter: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.white, lineWidth: 4)
                .frame(width: 58, height: 58)
            if isRecording {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.warning)
                    .frame(width: 24, height: 24)
            } else {
                Circle()
                    .fill(Color.white.opacity(shutterDown ? 0.6 : 0.92))
                    .frame(width: 46, height: 46)
            }
        }
        .shadow(color: Color.black.opacity(0.35), radius: 6, x: 0, y: 2)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !shutterDown else { return }
                    shutterDown = true
                    capture.press(from: .mouse)
                }
                .onEnded { _ in
                    shutterDown = false
                    capture.release(from: .mouse)
                }
        )
        .opacity(capture.phase == .saving ? 0.4 : 1)
        .accessibilityElement()
        .accessibilityLabel("Shutter")
        .accessibilityHint("Takes a photo of you and copies it")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if capture.press(from: .key) {
                capture.release(from: .key)
            }
        }
    }

    // MARK: Side

    private var side: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Send yourself")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.text)
            Text(status)
                .font(.system(size: 12))
                .foregroundColor(capture.failed ? Theme.warning : Theme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: filterColumns, alignment: .leading, spacing: 6) {
                ForEach(CameraFilter.allCases) { filter in
                    Button(filter.title) {
                        capture.select(filter)
                    }
                    .buttonStyle(FilterChipStyle(selected: capture.filter == filter))
                    .accessibilityAddTraits(capture.filter == filter ? .isSelected : [])
                }
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
            Button("Back to memes") {
                model.closeCapture()
            }
            .buttonStyle(PanelLinkButtonStyle(fontSize: 12, color: Theme.softText))
        }
        .frame(maxWidth: .infinity, minHeight: stageSize, alignment: .topLeading)
    }

    private var status: String {
        if capture.failed {
            return "Couldn’t capture that. Try again."
        }
        switch capture.phase {
        case .idle:
            return "Tap the button for a photo, hold it for a GIF (up to 3 s). It’s copied, ready to paste."
        case .pressing:
            return "Keep holding for a GIF…"
        case .recording:
            return "Recording… let go to stop."
        case .saving:
            return "Copying…"
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Theme.separator)
                .frame(height: 1)
                .padding(.bottom, 10)
            Text("space or click: photo · hold: GIF · ← → filter · esc back")
                .font(.system(size: 11))
                .foregroundColor(Theme.mutedText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A filter's name; the chosen one is filled.
private struct FilterChipStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundColor(selected ? Theme.onAccent : Theme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(selected ? Theme.accent : Theme.surface.opacity(configuration.isPressed ? 0.7 : 1))
            )
            .overlay(
                Capsule().strokeBorder(selected ? Theme.accent : Theme.chipBorder, lineWidth: 1)
            )
            .contentShape(Capsule())
    }
}

/// Shows the camera's capture picture (rendered off the main thread) by setting a layer's contents, so 30 frames
/// a second never go through SwiftUI.
private struct CapturePreview: NSViewRepresentable {
    let camera: CameraController

    func makeNSView(context: Context) -> CapturePreviewNSView {
        let view = CapturePreviewNSView()
        camera.onCapturePreview = { [weak view] image in
            view?.show(image)
        }
        return view
    }

    func updateNSView(_ nsView: CapturePreviewNSView, context: Context) {}

    static func dismantleNSView(_ nsView: CapturePreviewNSView, coordinator: ()) {
        nsView.stopShowing()
    }
}

final class CapturePreviewNSView: NSView {
    /// Once dismantled, frames still in flight are ignored.
    private var isShowing = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ image: CGImage) {
        guard isShowing else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }

    func stopShowing() {
        isShowing = false
        layer?.contents = nil
    }
}
