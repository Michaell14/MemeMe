import AVFoundation
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
        runningObservation = observeSessionRunning(session) { [weak self] running in
            let controller = self
            Task { @MainActor in
                controller?.sessionRunningChanged(running)
            }
        }
    }

    /// Default video device's isInUseByAnotherApplication.
    var isInUseByAnotherApplication: Bool {
        CameraController.preferredDevice()?.isInUseByAnotherApplication ?? false
    }

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

        let session = self.session
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
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
    fileprivate func deliver(_ sample: ExpressionSample, regionRects rects: [FaceRegion: CGRect]) {
        guard wantsRunning else { return }
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

    /// Built-in camera first, then any external camera, then the system default.
    private nonisolated static func preferredDevice() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        let devices = discovery.devices.filter { $0.isConnected }
        if let builtIn = devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) {
            return builtIn
        }
        if let other = devices.first {
            return other
        }
        return AVCaptureDevice.default(for: .video)
    }

    /// Adds the camera input and a BGRA video data output once. Returns true when the session is ready to run.
    private nonisolated static func configureIfNeeded(
        session: AVCaptureSession,
        processor: FrameProcessor,
        frameQueue: DispatchQueue
    ) -> Bool {
        if !session.inputs.isEmpty && !session.outputs.isEmpty {
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

// MARK: - Frame processing

/// Sample-buffer delegate that runs Vision on the video queue. All of its mutable state is
/// confined to that serial queue; results reach the controller on the main actor.
private final class FrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    weak var controller: CameraController?

    private let faceRequest = VNDetectFaceLandmarksRequest()
    private let bodyRequest = VNDetectHumanBodyPoseRequest()
    /// Slightly under 0.1 s so 30 and 60 fps sources yield exactly 10 analyzed frames per second.
    private let minimumFrameInterval: Double = 0.099
    private var lastFrameTime: Double?
    private var frameCounter = 0
    private var lastPose: PoseFeatures?

    func reset() {
        lastFrameTime = nil
        frameCounter = 0
        lastPose = nil
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let presentationTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let frameTime = presentationTime.isFinite ? presentationTime : CACurrentMediaTime()
        if let last = lastFrameTime, frameTime >= last, frameTime - last < minimumFrameInterval {
            return
        }
        lastFrameTime = frameTime

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let analyzeBody = frameCounter % 2 == 0
        frameCounter &+= 1

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([faceRequest])
        } catch {
            return
        }

        let faces = visionResults(faceRequest.results ?? [], as: VNFaceObservation.self)
        let face = faces.max(by: { boxArea($0.boundingBox) < boxArea($1.boundingBox) })
        let features = face.flatMap { FaceFeatureExtractor.features(from: $0) }
        let rects = face.map { FaceFeatureExtractor.regionRects(from: $0) } ?? [:]

        if analyzeBody {
            do {
                try handler.perform([bodyRequest])
                let bodies = visionResults(bodyRequest.results ?? [], as: VNHumanBodyPoseObservation.self)
                lastPose = bodies
                    .map { FaceFeatureExtractor.pose(from: $0) }
                    .max(by: { $0.bodyVisible < $1.bodyVisible }) ?? PoseFeatures.none
            } catch {
                // Keep the previous pose; the next body frame will refresh it.
            }
        }

        let sample = ExpressionSample(
            face: features,
            pose: lastPose,
            timestamp: CACurrentMediaTime(),
            sharpness: 1
        )
        let target = controller
        Task { @MainActor in
            target?.deliver(sample, regionRects: rects)
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
