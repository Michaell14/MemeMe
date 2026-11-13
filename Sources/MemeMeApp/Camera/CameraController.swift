@preconcurrency import AVFoundation
import Combine
import CoreMedia
import Foundation
import MemeMeCore
import os
import QuartzCore
import Vision

private let cameraLog = Logger(subsystem: "com.mememe.app", category: "camera")

/// Observes `session.isRunning` from a nonisolated context, so the KVO callback is never
/// treated as main-actor code; `onChange` runs on whatever thread AVFoundation reports from.
private func observeSessionRunning(
    _ session: AVCaptureSession,
    onChange: @escaping @Sendable (Bool) -> Void
) -> NSKeyValueObservation {
    session.observe(\.isRunning, options: [.new]) { observed, _ in
        onChange(observed.isRunning)
    }
}

/// Owns the capture session and turns camera frames into expression samples.
///
/// Configuration and start/stop run on a private serial queue; frame analysis runs on a
/// separate video queue inside `FrameProcessor`; published state is only touched on the main actor.
@MainActor
final class CameraController: NSObject, ObservableObject {
    @Published private(set) var authorization: AVAuthorizationStatus = .notDetermined
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var faceVisible: Bool = false
    @Published private(set) var regionRects: [FaceRegion: CGRect] = [:]   // latest face, Vision-normalized image coordinates

    let session = AVCaptureSession()
    var onSample: ((ExpressionSample) -> Void)?   // delivered on the main actor, ≤ 10 per second
    /// The width of the body last read across the frame (`BodyJoints.widthInImage`), nil without one; set before each
    /// `onSample`.
    private(set) var bodyWidth: Double?
    /// The capture view's filtered picture, delivered on the main actor for every camera frame while the view is open.
    var onCapturePreview: ((CGImage) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.mememe.camera.session")
    private let frameQueue = DispatchQueue(label: "com.mememe.camera.frames", qos: .userInitiated)
    private let processor = FrameProcessor()
    private var wantsRunning = false
    private var lastFaceTimestamp: TimeInterval = 0
    private var runningObservation: NSKeyValueObservation?

    /// Region rects survive this long without a face, so a single missed detection doesn't flicker the overlays.
    private let regionGracePeriod: TimeInterval = 0.5

    override init() {
        super.init()
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        processor.controller = self
        processor.renderer.onPreview = { [weak self] image in
            let controller = self
            Task { @MainActor in
                controller?.onCapturePreview?(image)
            }
        }
        runningObservation = observeSessionRunning(session) { [weak self] running in
            let controller = self
            Task { @MainActor in
                controller?.sessionRunningChanged(running)
            }
        }
    }

    /// The preferred usable camera's isInUseByAnotherApplication.
    var isInUseByAnotherApplication: Bool {
        CameraController.preferredDevice()?.isInUseByAnotherApplication ?? false
    }

    /// False when no connected, unsuspended camera exists (Mac mini/Studio without a webcam, or a closed lid without another camera).
    var hasUsableCamera: Bool { CameraController.preferredDevice() != nil }

    func refreshAuthorization() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status != authorization {
            authorization = status
        }
    }

    func requestAccess() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        refreshAuthorization()
        return granted
    }

    /// No-op unless authorized; lazily configures the session, then starts it on the session queue.
    func start() {
        refreshAuthorization()
        guard authorization == .authorized else { return }
        wantsRunning = true

        let session = self.session
        let processor = self.processor
        let frameQueue = self.frameQueue
        frameQueue.async {
            processor.reset()
        }
        sessionQueue.async {
            let configured = CameraController.configureIfNeeded(
                session: session,
                processor: processor,
                frameQueue: frameQueue
            )
            if configured && !session.isRunning {
                session.startRunning()
            }
            let running = configured && session.isRunning
            Task { @MainActor in
                self.sessionRunningChanged(running)
            }
        }
    }

    /// Stops the session on the session queue; clears faceVisible and regionRects.
    func stop() {
        wantsRunning = false
        if isRunning { isRunning = false }
        if faceVisible { faceVisible = false }
        if !regionRects.isEmpty { regionRects = [:] }
        bodyWidth = nil

        let session = self.session
        let processor = self.processor
        frameQueue.async {
            // A still waiting for a frame gets nil instead of waiting forever.
            processor.renderer.reset()
        }
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    // MARK: - Capture view

    /// Renders every frame for the capture view (`onCapturePreview`) with `filter` while `active`.
    func setCaptureView(active: Bool, filter: CameraFilter) {
        let processor = self.processor
        frameQueue.async {
            processor.renderer.isActive = active
            processor.renderer.filter = filter
            if !active {
                processor.renderer.cancelClip()
            }
        }
    }

    /// The next frame as the capture view shows it (480 px square at VGA, filtered); nil when no frame comes within 1 s.
    func captureStill() async -> CGImage? {
        guard isRunning else { return nil }
        let processor = self.processor
        let frameQueue = self.frameQueue
        return await withCheckedContinuation { continuation in
            frameQueue.async {
                let token = processor.renderer.requestStill(continuation)
                frameQueue.asyncAfter(deadline: .now() + 1) {
                    processor.renderer.expireStill(token)
                }
            }
        }
    }

    /// Starts keeping frames for a clip (up to 12.5 a second, 320 px, at most 3 s).
    func beginClip() {
        let processor = self.processor
        frameQueue.async {
            processor.renderer.beginClip()
        }
    }

    /// The clip recorded since `beginClip`; nil when none was recording.
    func endClip() async -> CapturedClip? {
        let processor = self.processor
        let frameQueue = self.frameQueue
        return await withCheckedContinuation { continuation in
            frameQueue.async {
                continuation.resume(returning: processor.renderer.endClip())
            }
        }
    }

    /// Drops a clip being recorded.
    func cancelClip() {
        let processor = self.processor
        frameQueue.async {
            processor.renderer.cancelClip()
        }
    }

    // MARK: - Hybrid matcher

    /// With models, every analyzed frame with a face also gets HSEmotion on the face crop (`ExpressionSample.emotion`),
    /// and the last frames are kept (`heldFrame(at:)`) for the held face's CLIP passes. nil turns both off.
    func setHybridModels(_ models: HybridModels?) {
        let processor = self.processor
        frameQueue.async {
            processor.hybrid = models
            processor.clearHeldFrames()
        }
    }

    /// The frame (and its face crop and emotion) of the sample with this timestamp, while it is among the last
    /// `FrameProcessor.heldFrameWindow` seconds of frames with a face; nil otherwise. Frames never leave the Mac.
    func heldFrame(at timestamp: TimeInterval) async -> HeldFrame? {
        let processor = self.processor
        return await withCheckedContinuation { continuation in
            frameQueue.async {
                continuation.resume(returning: processor.heldFrame(at: timestamp))
            }
        }
    }

    // MARK: - Main-actor callbacks

    private func sessionRunningChanged(_ running: Bool) {
        let value = running && wantsRunning
        if isRunning != value {
            isRunning = value
        }
    }

    /// Called by `FrameProcessor` (via the main actor) for every analyzed frame.
    fileprivate func deliver(_ sample: ExpressionSample, regionRects rects: [FaceRegion: CGRect], bodyWidth width: Double?) {
        guard wantsRunning else { return }
        bodyWidth = width
        let hasFace = sample.face != nil
        if faceVisible != hasFace {
            faceVisible = hasFace
        }
        if hasFace {
            lastFaceTimestamp = sample.timestamp
            if regionRects != rects {
                regionRects = rects
            }
        } else if !regionRects.isEmpty && sample.timestamp - lastFaceTimestamp > regionGracePeriod {
            regionRects = [:]
        }
        onSample?(sample)
    }

    // MARK: - Session setup (session queue)

    /// A camera that can deliver frames: connected and not suspended (a closed MacBook lid suspends the built-in one).
    private nonisolated static func isUsable(_ device: AVCaptureDevice) -> Bool {
        device.isConnected && !device.isSuspended
    }

    /// Built-in camera first, then any external or Continuity Camera, then the system default;
    /// disconnected or suspended cameras are skipped.
    private nonisolated static func preferredDevice() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        let devices = discovery.devices.filter { isUsable($0) }
        if let builtIn = devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) {
            return builtIn
        }
        if let other = devices.first {
            return other
        }
        if let fallback = AVCaptureDevice.default(for: .video), isUsable(fallback) {
            return fallback
        }
        return nil
    }

    /// Adds the camera input and a BGRA video data output once. Returns true when the session is ready to run.
    private nonisolated static func configureIfNeeded(
        session: AVCaptureSession,
        processor: FrameProcessor,
        frameQueue: DispatchQueue
    ) -> Bool {
        // Reuse the configured camera only while it can still deliver frames (unplugged webcam, closed lid → reconfigure).
        let currentDevice = session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }.first
        if let currentDevice, isUsable(currentDevice), !session.outputs.isEmpty {
            return true
        }
        guard let device = preferredDevice() else {
            cameraLog.error("No video capture device available")
            return false
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            cameraLog.error("Could not open camera: \(error.localizedDescription, privacy: .public)")
            return false
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(processor, queue: frameQueue)

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for existing in session.inputs {
            session.removeInput(existing)
        }
        for existing in session.outputs {
            session.removeOutput(existing)
        }

        guard session.canAddInput(input) else {
            cameraLog.error("Camera input rejected by the capture session")
            return false
        }
        session.addInput(input)

        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        } else if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        }

        guard session.canAddOutput(output) else {
            cameraLog.error("Video output rejected by the capture session")
            session.removeInput(input)
            return false
        }
        session.addOutput(output)
        return true
    }
}

/// A camera frame kept for the hybrid matcher's held-face search.
struct HeldFrame: Sendable {
    let timestamp: TimeInterval
    let frame: RGBImage
    let faceCrop: PixelRect?   // nil: no face box of 12 px or more; the whole frame stands for the face
    let emotion: [Double]?
}

// MARK: - Frame processing

/// Sample-buffer delegate that runs Vision on the video queue. All of its mutable state is
/// confined to that serial queue; results reach the controller on the main actor.
private final class FrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    weak var controller: CameraController?

    private let faceRequest = VNDetectFaceLandmarksRequest()
    private let bodyRequest = VNDetectHumanBodyPoseRequest()
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        return request
    }()
    /// Slightly under 0.1 s so 30 and 60 fps sources yield exactly 10 analyzed frames per second.
    private let minimumFrameInterval: Double = 0.099
    private var lastFrameTime: Double?
    private var frameCounter = 0
    private var lastPose: PoseFeatures?
    /// The capture view's picture and captures.
    let renderer = CaptureRenderer()
    /// The body last read (on even frames) and the sign of its hands (read on odd frames while a wrist is in view).
    private var lastBody: BodyJoints?
    private var lastHand: HandShape?
    /// The hybrid matcher's models (nil: off); set on the frame queue.
    var hybrid: HybridModels?
    /// Frames with a face from the last `heldFrameWindow` seconds, oldest first (about 640 × 480 × 3 bytes each).
    private var heldFrames: [HeldFrame] = []
    static let heldFrameWindow: TimeInterval = 1.5

    func clearHeldFrames() {
        heldFrames.removeAll()
    }

    func heldFrame(at timestamp: TimeInterval) -> HeldFrame? {
        heldFrames.first { abs($0.timestamp - timestamp) < 0.001 }
    }

    /// HSEmotion on the face crop of this frame, and the frame kept for a held-face search.
    private func readEmotion(_ pixelBuffer: CVPixelBuffer, faces: [VNFaceObservation], timestamp: TimeInterval,
                             models: HybridModels) -> [Double]? {
        guard let frame = FrameProcessor.rgbImage(of: pixelBuffer) else { return nil }
        let crop = HybridAnalyzer.largestFaceCrop(faces, imageWidth: frame.width, imageHeight: frame.height)
        let emotion: [Double]?
        do {
            emotion = try models.emotion(crop.map { frame.cropped(to: $0) } ?? frame)
        } catch {
            emotion = nil
        }
        heldFrames.removeAll { timestamp - $0.timestamp > FrameProcessor.heldFrameWindow }
        heldFrames.append(HeldFrame(timestamp: timestamp, frame: frame, faceCrop: crop, emotion: emotion))
        return emotion
    }

    /// The 32BGRA frame as RGB; nil for another format.
    private static func rgbImage(of pixelBuffer: CVPixelBuffer) -> RGBImage? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0 else { return nil }
        let buffer = UnsafeRawBufferPointer(start: base, count: bytesPerRow * height)
        return RGBImage(fourChannel: buffer, width: width, height: height, bytesPerRow: bytesPerRow, bgra: true)
    }

    func reset() {
        lastFrameTime = nil
        frameCounter = 0
        lastPose = nil
        lastBody = nil
        lastHand = nil
        heldFrames.removeAll()
        renderer.reset()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let presentationTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let frameTime = presentationTime.isFinite ? presentationTime : CACurrentMediaTime()
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // The capture view shows every frame; Vision reads at most 10 a second.
        renderer.render(pixelBuffer, time: frameTime)
        if let last = lastFrameTime, frameTime >= last, frameTime - last < minimumFrameInterval {
            return
        }
        lastFrameTime = frameTime

        // While the capture view is open the search is paused: only the face is read (for the filters).
        let readsBody = !renderer.isActive
        let analyzeBody = frameCounter % 2 == 0
        frameCounter &+= 1
        let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
        let imageHeight = CVPixelBufferGetHeight(pixelBuffer)

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([faceRequest])
        } catch {
            return
        }

        let faces = visionResults(faceRequest.results ?? [], as: VNFaceObservation.self)
        let face = faces.max(by: { boxArea($0.boundingBox) < boxArea($1.boundingBox) })
        let features = face.flatMap { FaceFeatureExtractor.features(from: $0) }
        // The face's details (each eye and brow, the lips, the tongue's color) from the same landmarks and this
        // frame's pixels: no further Vision request.
        let shape = features == nil ? nil : face.flatMap { FaceFeatureExtractor.shape(from: $0, pixelBuffer: pixelBuffer) }
        let rects = face.map { FaceFeatureExtractor.regionRects(from: $0) } ?? [:]
        if renderer.needsFrames {
            renderer.updateFace(face.flatMap { FaceGeometry.geometry(from: $0) }, at: frameTime)
            if let features {
                renderer.noteExpression(intensity: RestingBaseline().intensity(of: features))
            }
        }

        // Body pose on even frames and hand pose on odd ones (only while a wrist is in view), so a frame never
        // runs more than two Vision requests.
        if !readsBody {
            lastPose = nil
        } else if analyzeBody {
            do {
                try handler.perform([bodyRequest])
                let bodies = visionResults(bodyRequest.results ?? [], as: VNHumanBodyPoseObservation.self)
                lastBody = FaceFeatureExtractor.primaryBody(bodies, faceBox: face?.boundingBox,
                                                            imageWidth: imageWidth, imageHeight: imageHeight)
                if lastBody?[.leftWrist] == nil && lastBody?[.rightWrist] == nil {
                    lastHand = nil
                }
                lastPose = lastBody.map { PoseFeatures(joints: $0, hand: lastHand) } ?? PoseFeatures.none
            } catch {
                // Keep the previous pose; the next body frame will refresh it.
            }
        } else if let body = lastBody, body[.leftWrist] != nil || body[.rightWrist] != nil {
            do {
                try handler.perform([handRequest])
                let hands = visionResults(handRequest.results ?? [], as: VNHumanHandPoseObservation.self)
                let joints = FaceFeatureExtractor.handJoints(hands, imageWidth: imageWidth, imageHeight: imageHeight)
                let box = FaceFeatureExtractor.poseBox(face?.boundingBox, imageWidth: imageWidth, imageHeight: imageHeight)
                lastHand = HandShape.strongest(of: body.ownHands(joints), on: body, faceBox: box)
                lastPose = PoseFeatures(joints: body, hand: lastHand)
            } catch {
                // Keep the previous hand; the next odd frame will refresh it.
            }
        }

        let timestamp = CACurrentMediaTime()
        // The hybrid matcher's live emotion reading (not in the capture view, whose camera doesn't search).
        let emotion: [Double]?
        if readsBody, features != nil, let models = hybrid {
            emotion = readEmotion(pixelBuffer, faces: faces, timestamp: timestamp, models: models)
        } else {
            emotion = nil
        }
        let sample = ExpressionSample(
            face: features,
            pose: lastPose,
            shape: shape,
            timestamp: timestamp,
            sharpness: 1,
            emotion: emotion
        )
        let bodyWidth = readsBody ? lastBody?.widthInImage(aspect: Double(imageWidth) / Double(max(imageHeight, 1))) : nil
        let target = controller
        Task { @MainActor in
            target?.deliver(sample, regionRects: rects, bodyWidth: bodyWidth)
        }
    }
}

/// Typed view of a request's results that works whether the SDK types `results` precisely or as `[VNObservation]`.
private func visionResults<T>(_ results: [Any], as type: T.Type) -> [T] {
    results.compactMap { $0 as? T }
}

private func boxArea(_ rect: CGRect) -> CGFloat {
    rect.width * rect.height
}
