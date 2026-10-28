import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A recorded clip: frames in order, the time each one shows, and the frame with the strongest expression
/// (for a sticker).
struct CapturedClip {
    let frames: [CGImage]
    let frameDelay: Double
    let bestFrame: CGImage?
}

/// The capture view's picture and captures. Every camera frame (while the view is open or a capture runs) is
/// cropped to the centered square, mirrored like the mirror, filtered, and shown; a still is the next such frame,
/// a clip keeps them at 12.5 per second, smaller.
///
/// Confined to the camera's frame queue: every method must be called there.
final class CaptureRenderer {
    static let clipFrameDelay = 0.08                 // 12.5 frames a second (GIF delays are in 1/100 s)
    static let clipSide = 320
    static let maximumClipDuration: TimeInterval = 3

    /// The capture view is open: render every frame for it.
    var isActive = false
    var filter: CameraFilter = .none
    /// Receives each rendered picture (on the frame queue).
    var onPreview: ((CGImage) -> Void)?

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    private var geometry: FaceGeometry?
    private var geometryTime: Double = 0
    private var anchors: FaceAnchors?
    private var pendingStills: [UUID: CheckedContinuation<CGImage?, Never>] = [:]
    private var clip: ClipRecording?
    private var lastFrame: CGImage?

    private struct ClipRecording {
        var frames: [CGImage] = []
        var start: Double?
        var lastKept: Double?
        var bestFrame: CGImage?
        var bestIntensity = -1.0
    }

    /// A face reading this old no longer places overlays.
    private static let faceLifetime: Double = 0.5

    /// Ends captures in progress (a pending still gets nil) and forgets the face; keeps `isActive` and `filter`.
    func reset() {
        for continuation in pendingStills.values {
            continuation.resume(returning: nil)
        }
        pendingStills.removeAll()
        clip = nil
        geometry = nil
        anchors = nil
        lastFrame = nil
    }

    var needsFrames: Bool {
        isActive || clip != nil || !pendingStills.isEmpty
    }

    /// The face of the latest analyzed frame (nil: none found).
    func updateFace(_ face: FaceGeometry?, at time: Double) {
        geometry = face
        geometryTime = time
    }

    /// How strong the expression of the frame just rendered was; the clip keeps its strongest frame for a sticker.
    func noteExpression(intensity: Double) {
        guard var recording = clip, let frame = lastFrame, intensity > recording.bestIntensity else { return }
        recording.bestIntensity = intensity
        recording.bestFrame = frame
        clip = recording
    }

    func render(_ pixelBuffer: CVPixelBuffer, time: Double) {
        guard needsFrames else { return }
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let side = min(width, height)
        guard side >= 16 else { return }
        let square = CGRect(x: 0, y: 0, width: side, height: side)
        let mirrored = CaptureRenderer.mirroredSquare(CIImage(cvPixelBuffer: pixelBuffer), width: width, height: height)

        if let geometry, time - geometryTime <= CaptureRenderer.faceLifetime {
            let target = FaceAnchors(geometry: geometry, imageWidth: width, imageHeight: height)
            anchors = anchors.map { $0.blended(toward: target, amount: 0.5) } ?? target
        } else {
            anchors = nil
        }

        let filtered = filter.apply(to: mirrored, face: anchors, time: time).cropped(to: square)
        guard let frame = makeImage(filtered, rect: square) else { return }
        lastFrame = frame
        if isActive {
            onPreview?(frame)
        }
        if !pendingStills.isEmpty {
            let waiting = pendingStills
            pendingStills.removeAll()
            for continuation in waiting.values {
                continuation.resume(returning: frame)
            }
        }
        if var recording = clip {
            let start = recording.start ?? time
            recording.start = start
            let due = recording.lastKept.map { time - $0 >= CaptureRenderer.clipFrameDelay - 0.01 } ?? true
            if due && time - start <= CaptureRenderer.maximumClipDuration {
                let scale = CGFloat(CaptureRenderer.clipSide) / side
                let small = filtered.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let target = CGRect(x: 0, y: 0, width: CaptureRenderer.clipSide, height: CaptureRenderer.clipSide)
                if let smallFrame = makeImage(small.cropped(to: target), rect: target) {
                    recording.frames.append(smallFrame)
                    recording.lastKept = time
                }
                if recording.bestFrame == nil {
                    recording.bestFrame = frame
                }
            }
            clip = recording
        }
    }

    /// The next rendered frame goes to `continuation`; returns a token for `expireStill`.
    func requestStill(_ continuation: CheckedContinuation<CGImage?, Never>) -> UUID {
        let token = UUID()
        pendingStills[token] = continuation
        return token
    }

    /// Gives up on a still no frame came for (the camera stopped).
    func expireStill(_ token: UUID) {
        pendingStills.removeValue(forKey: token)?.resume(returning: nil)
    }

    func beginClip() {
        clip = ClipRecording()
    }

    /// The clip so far (nil when none was recording); recording stops.
    func endClip() -> CapturedClip? {
        guard let recording = clip else { return nil }
        clip = nil
        return CapturedClip(frames: recording.frames, frameDelay: CaptureRenderer.clipFrameDelay, bestFrame: recording.bestFrame)
    }

    func cancelClip() {
        clip = nil
    }

    private func makeImage(_ image: CIImage, rect: CGRect) -> CGImage? {
        if let colorSpace {
            return context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: colorSpace)
        }
        return context.createCGImage(image, from: rect)
    }

    /// The centered square of a `width` × `height` frame, flipped left to right (as the mirror shows it), at the origin.
    static func mirroredSquare(_ frame: CIImage, width: CGFloat, height: CGFloat) -> CIImage {
        let side = min(width, height)
        let originX = (width - side) / 2
        let originY = (height - side) / 2
        let square = frame
            .cropped(to: CGRect(x: originX, y: originY, width: side, height: side))
            .transformed(by: CGAffineTransform(translationX: -originX, y: -originY))
        return square
            .transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: side, ty: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
    }
}

/// Encodes captures for the pasteboard.
enum CaptureEncoder {
    static func png(_ image: CGImage) -> Data? {
        encode([image], type: UTType.png, properties: nil, frameProperties: nil)
    }

    /// A GIF that loops forever, `frameDelay` seconds per frame.
    static func gif(_ frames: [CGImage], frameDelay: Double) -> Data? {
        guard !frames.isEmpty else { return nil }
        let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        let delay = [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: frameDelay,
            kCGImagePropertyGIFUnclampedDelayTime: frameDelay,
        ]] as CFDictionary
        return encode(frames, type: UTType.gif, properties: loop, frameProperties: delay)
    }

    private static func encode(_ images: [CGImage], type: UTType, properties: CFDictionary?, frameProperties: CFDictionary?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, images.count, nil) else {
            return nil
        }
        if let properties {
            CGImageDestinationSetProperties(destination, properties)
        }
        for image in images {
            CGImageDestinationAddImage(destination, image, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
