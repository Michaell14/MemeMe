import CoreGraphics
import Foundation
import QuartzCore

enum CapturePhase: Equatable {
    case idle
    /// The shutter is down; held past `CaptureModel.holdThreshold` it records a clip.
    case pressing
    case recording(progress: Double)
    /// Encoding and copying.
    case saving
}

/// A finished capture, ready for the pasteboard.
struct CaptureResult {
    let data: Data
    let isGIF: Bool
    /// The frame a sticker is cut from: the photo itself, or the clip's strongest expression.
    let stickerFrame: CGImage?
}

/// The capture view: the filter, and the shutter (a tap takes a photo, holding records a GIF of up to 3 s).
/// The finished capture goes to `onCaptured`; AppModel copies it and closes the panel.
@MainActor final class CaptureModel: ObservableObject {
    @Published private(set) var filter: CameraFilter = .none
    @Published private(set) var phase: CapturePhase = .idle
    /// Bumped for each photo, so the view flashes.
    @Published private(set) var flashCount = 0
    /// The last capture failed ("Couldn't capture that.").
    @Published private(set) var failed = false

    var onCaptured: ((CaptureResult) -> Void)?

    /// A press held longer than this records a clip instead of taking a photo.
    static let holdThreshold: TimeInterval = 0.35
    /// A clip with fewer frames than this becomes a photo of its best frame.
    static let minimumClipFrames = 4

    private let camera: CameraController
    private var isPressed = false
    private var holdTask: Task<Void, Never>?
    private var recordTask: Task<Void, Never>?
    /// Bumped by `cancel`, so a capture that finishes after it is dropped.
    private var generation = 0

    init(camera: CameraController) {
        self.camera = camera
    }

    var isBusy: Bool {
        phase != .idle
    }

    func select(_ newFilter: CameraFilter) {
        guard newFilter != filter else { return }
        filter = newFilter
        camera.setCaptureView(active: true, filter: newFilter)
    }

    /// ← / →: the previous or next filter, wrapping around.
    func cycleFilter(by step: Int) {
        let all = CameraFilter.allCases
        guard let index = all.firstIndex(of: filter) else { return }
        let next = ((index + step) % all.count + all.count) % all.count
        select(all[next])
    }

    /// The view opened: start rendering it (with no filter, each time).
    func activate() {
        cancel()
        filter = .none
        failed = false
        camera.setCaptureView(active: true, filter: .none)
    }

    /// The view closed: stop rendering and drop a capture in progress.
    func deactivate() {
        cancel()
        camera.setCaptureView(active: false, filter: filter)
    }

    /// Shutter down (click or Space).
    func press() {
        guard phase == .idle, !isPressed else { return }
        isPressed = true
        failed = false
        phase = .pressing
        let current = generation
        holdTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(CaptureModel.holdThreshold * 1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == current, self.isPressed, self.phase == .pressing else { return }
            self.startRecording()
        }
    }

    /// Shutter up: a short press takes a photo, a long one ends the clip.
    func release() {
        guard isPressed else { return }
        isPressed = false
        switch phase {
        case .pressing:
            holdTask?.cancel()
            holdTask = nil
            takePhoto()
        case .recording:
            finishRecording()
        case .idle, .saving:
            break
        }
    }

    /// Drops whatever is in progress (Esc, the panel closing).
    func cancel() {
        generation += 1
        isPressed = false
        holdTask?.cancel()
        holdTask = nil
        recordTask?.cancel()
        recordTask = nil
        if case .recording = phase {
            camera.cancelClip()
        }
        if phase != .idle {
            phase = .idle
        }
    }

    // MARK: Private

    private func startRecording() {
        phase = .recording(progress: 0)
        camera.beginClip()
        let start = CACurrentMediaTime()
        let current = generation
        recordTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled, let self, self.generation == current, case .recording = self.phase else { return }
                let elapsed = CACurrentMediaTime() - start
                if elapsed >= CaptureRenderer.maximumClipDuration {
                    self.finishRecording()
                    return
                }
                self.phase = .recording(progress: elapsed / CaptureRenderer.maximumClipDuration)
            }
        }
    }

    private func takePhoto() {
        phase = .saving
        flashCount += 1
        let current = generation
        Task { [weak self] in
            guard let self else { return }
            let still = await self.camera.captureStill()
            guard self.generation == current else { return }
            guard let still else {
                self.finish(nil, generation: current)
                return
            }
            let data = await Task.detached(priority: .userInitiated) { CaptureEncoder.png(still) }.value
            self.finish(data.map { CaptureResult(data: $0, isGIF: false, stickerFrame: still) }, generation: current)
        }
    }

    private func finishRecording() {
        recordTask?.cancel()
        recordTask = nil
        phase = .saving
        let current = generation
        Task { [weak self] in
            guard let self else { return }
            let clip = await self.camera.endClip()
            guard self.generation == current else { return }
            guard let clip else {
                self.finish(nil, generation: current)
                return
            }
            if clip.frames.count >= CaptureModel.minimumClipFrames {
                let frames = clip.frames
                let delay = clip.frameDelay
                let data = await Task.detached(priority: .userInitiated) { CaptureEncoder.gif(frames, frameDelay: delay) }.value
                self.finish(data.map { CaptureResult(data: $0, isGIF: true, stickerFrame: clip.bestFrame) }, generation: current)
            } else if let best = clip.bestFrame {
                // Too short for a GIF (the camera stalled): a photo of its best frame.
                let data = await Task.detached(priority: .userInitiated) { CaptureEncoder.png(best) }.value
                self.finish(data.map { CaptureResult(data: $0, isGIF: false, stickerFrame: best) }, generation: current)
            } else {
                self.finish(nil, generation: current)
            }
        }
    }

    private func finish(_ result: CaptureResult?, generation current: Int) {
        guard generation == current else { return }
        phase = .idle
        guard let result else {
            failed = true
            return
        }
        onCaptured?(result)
    }
}
