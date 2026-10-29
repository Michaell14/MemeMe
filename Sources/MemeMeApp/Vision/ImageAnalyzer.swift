import CoreGraphics
import CoreServices
import CryptoKit
import Foundation
import ImageIO
import MemeMeCore
import os
import Vision

struct LoadedImage {
    let cgImage: CGImage          // representative frame (first)
    let frames: [CGImage]         // up to 3 frames for animated images (first, middle, 3/4), else [cgImage]
    let isAnimated: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let isCameraPhoto: Bool
    let isScreenshot: Bool
    let data: Data
}

struct ImageAnalysis {
    var face: FaceFeatures?
    /// The same face's details beyond the seven features (`FaceShape`), its tongue read from the frame's colors.
    var faceShape: FaceShape?
    var pose: PoseFeatures?
    var intensity: Double
    var featurePrint: [Float]?
    var featurePrintRevision: Int
    var text: String
    var labels: [String]
    var facts: ImageFacts
    var contentHash: String
    var faceBoxes: [CGRect]        // Vision-normalized boxes of all faces in the chosen frame
    var chosenFrame: CGImage
}

/// What the background pose pass found in one file.
enum PoseReading: Sendable {
    case unreadable
    case read(PoseFeatures?)
}

/// What the background face pass found in one file: the face as `ImageAnalyzer.analyze` reads it (nil without one).
enum FaceReading: Sendable {
    case unreadable
    case read(face: FaceFeatures?, shape: FaceShape?, intensity: Double)
}

private let visionLog = Logger(subsystem: "com.mememe.app", category: "vision")

private enum ImageAnalyzerError: Error {
    case unreadableImage
    case noFeaturePrint
}

enum ImageAnalyzer {
    /// VNGenerateImageFeaturePrintRequest revision used everywhere (768 floats on macOS 14).
    static var featurePrintRevision: Int { VNGenerateImageFeaturePrintRequestRevision2 }

    private static let maximumFileSize = 25 * 1024 * 1024
    /// Longest side of the frames handed to Vision; larger images are downsampled while decoding.
    static let maximumAnalysisPixelSize = 2048
    /// Longest side of the frames read for pose alone (the background pass that measures older items again).
    static let poseAnalysisPixelSize = 1024
    /// Images whose shorter side is below this have no pose read: too small for joints to mean anything.
    private static let minimumPosePixelSize = 128
    private static let maximumTextLength = 200
    private static let minimumLabelConfidence: Float = 0.3
    private static let maximumLabelCount = 8
    private static let screenshotPrefixes = [
        "Screenshot", "Screen Shot", "CleanShot",
        "Bildschirmfoto", "Capture d’écran", "Captura de pantalla", "Schermata",
    ]
    /// Container types whose multi-image files are animations (not bursts, pages or HDR companions).
    private static let animatedTypeIdentifiers: Set<String> = [
        "com.compuserve.gif", "public.png", "org.webmproject.webp", "public.heics",
    ]

    // MARK: - Loading

    /// ImageIO; nil if not an image or > 25 MB. Frames are decoded to at most `maxPixelSize` on the longest side.
    static func load(url: URL, maxPixelSize: Int = maximumAnalysisPixelSize) -> LoadedImage? {
        guard url.isFileURL else { return nil }
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]) {
            if values.isRegularFile == false { return nil }
            if let size = values.fileSize, size > maximumFileSize { return nil }
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty, data.count <= maximumFileSize else {
            return nil
        }
        return decode(data: data, fileName: url.lastPathComponent, maxPixelSize: maxPixelSize)
    }

    private static func decode(data: Data, fileName: String, maxPixelSize: Int) -> LoadedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let imageCount = CGImageSourceGetCount(source)
        guard imageCount > 0 else { return nil }

        let typeIdentifier = CGImageSourceGetType(source).map { $0 as String } ?? ""
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]

        var width = intValue(properties[kCGImagePropertyPixelWidth as String])
        var height = intValue(properties[kCGImagePropertyPixelHeight as String])
        let orientation = intValue(properties[kCGImagePropertyOrientation as String]) ?? 1
        if orientation >= 5, orientation <= 8, let rawWidth = width, let rawHeight = height {
            // EXIF orientations 5–8 rotate by 90°, so the displayed image is transposed.
            width = rawHeight
            height = rawWidth
        }

        let isAnimated = imageCount > 1 && animatedTypeIdentifiers.contains(typeIdentifier)
        var indices = [0]
        if isAnimated {
            for index in [imageCount / 2, (imageCount * 3) / 4] where index > 0 && index < imageCount && !indices.contains(index) {
                indices.append(index)
            }
        }

        let longestSide = max(width ?? 0, height ?? 0)
        let decodeSize = longestSide > 0 ? min(maxPixelSize, longestSide) : maxPixelSize
        let frames = indices.compactMap { decodeFrame(source: source, index: $0, maxPixel: decodeSize) }
        guard let first = frames.first else { return nil }

        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let make = nonEmpty(tiff?[kCGImagePropertyTIFFMake as String] as? String)
        let model = nonEmpty(tiff?[kCGImagePropertyTIFFModel as String] as? String)
        let userComment = nonEmpty(exif?[kCGImagePropertyExifUserComment as String] as? String) ?? ""

        let isScreenshot = hasScreenshotName(fileName)
            || userComment.caseInsensitiveCompare("Screenshot") == .orderedSame
        let isCameraPhoto = !isScreenshot && (make != nil || model != nil)

        return LoadedImage(
            cgImage: first,
            frames: frames,
            isAnimated: isAnimated,
            pixelWidth: width ?? first.width,
            pixelHeight: height ?? first.height,
            isCameraPhoto: isCameraPhoto,
            isScreenshot: isScreenshot,
            data: data
        )
    }

    /// Decodes one frame with its EXIF orientation applied, downsampled to `maxPixel` on the longest side.
    private static func decodeFrame(source: CGImageSource, index: Int, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) {
            return image
        }
        return CGImageSourceCreateImageAtIndex(source, index, nil)
    }

    private static func hasScreenshotName(_ fileName: String) -> Bool {
        screenshotPrefixes.contains { prefix in
            fileName.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    // MARK: - Analysis

    /// Synchronous; never call on the main thread. For animated images analyzes up to 3 frames and keeps the most intense.
    static func analyze(url: URL, includeText: Bool = true) throws -> ImageAnalysis {
        guard let image = load(url: url) else { throw ImageAnalyzerError.unreadableImage }
        return try analyze(image, includeText: includeText)
    }

    static func analyze(_ image: LoadedImage, includeText: Bool = true) throws -> ImageAnalysis {
        let baseline = RestingBaseline()
        let frames = image.frames.isEmpty ? [image.cgImage] : image.frames

        var best: FrameAnalysis?
        var analyzed: [FrameAnalysis] = []
        for (offset, frame) in frames.enumerated() {
            let candidate: FrameAnalysis
            if offset == 0 {
                candidate = try analyzeFrame(frame, baseline: baseline)
            } else if let later = try? analyzeFrame(frame, baseline: baseline) {
                candidate = later
            } else {
                continue
            }
            analyzed.append(candidate)
            if let current = best, current.rank >= candidate.rank { continue }
            best = candidate
        }
        guard let chosen = best else { throw ImageAnalyzerError.unreadableImage }
        let pose = clearestPose(frames: analyzed, fallback: chosen)

        let handler = VNImageRequestHandler(cgImage: chosen.frame, options: [:])

        var featurePrint: [Float]?
        do {
            featurePrint = try runFeaturePrint(handler: handler)
        } catch {
            visionLog.error("Feature print failed: \(error.localizedDescription, privacy: .public)")
        }

        var labels: [String] = []
        do {
            labels = try classify(handler: handler)
        } catch {
            visionLog.error("Classification failed: \(error.localizedDescription, privacy: .public)")
        }

        var text = ""
        var textCharacterCount = 0
        if includeText {
            do {
                let recognized = try recognizeText(handler: handler)
                textCharacterCount = recognized.count
                text = String(recognized.prefix(maximumTextLength))
            } catch {
                visionLog.error("Text recognition failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        let largestFace = chosen.faceBoxes.map { Double($0.height) }.max() ?? 0
        let facts = ImageFacts(
            pixelWidth: image.pixelWidth,
            pixelHeight: image.pixelHeight,
            isAnimated: image.isAnimated,
            isCameraPhoto: image.isCameraPhoto,
            isScreenshot: image.isScreenshot,
            textCharacterCount: textCharacterCount,
            faceCount: chosen.faceBoxes.count,
            largestFaceHeightFraction: largestFace,
            labels: labels
        )

        return ImageAnalysis(
            face: chosen.face,
            faceShape: chosen.shape,
            pose: pose,
            intensity: chosen.intensity,
            featurePrint: featurePrint,
            featurePrintRevision: featurePrintRevision,
            text: text,
            labels: labels,
            facts: facts,
            contentHash: sha256Hex(image.data),
            faceBoxes: chosen.faceBoxes,
            chosenFrame: chosen.frame
        )
    }

    static func featurePrint(of cgImage: CGImage) throws -> [Float] {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        return try runFeaturePrint(handler: handler)
    }

    static func sha256Hex(_ data: Data) -> String {
        let hexDigits = Array("0123456789abcdef".utf8)
        var characters: [UInt8] = []
        characters.reserveCapacity(64)
        for byte in SHA256.hash(data: data) {
            characters.append(hexDigits[Int(byte >> 4)])
            characters.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: characters, as: UTF8.self)
    }

    /// kMDItemWhereFroms host, e.g. "reddit.com", if any.
    static func downloadedFromHost(url: URL) -> String? {
        guard url.isFileURL, let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        guard let sources = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String] else { return nil }
        for source in sources {
            guard let sourceURL = URL(string: source),
                  let scheme = sourceURL.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  var host = sourceURL.host?.lowercased(),
                  !host.isEmpty else {
                continue
            }
            if host.hasPrefix("www.") {
                host.removeFirst(4)
            }
            if !host.isEmpty {
                return host
            }
        }
        return nil
    }

    // MARK: - Vision

    private struct FrameAnalysis {
        let frame: CGImage
        let faces: FrameFaces
        let pose: PoseFeatures?

        var face: FaceFeatures? { faces.face }
        var shape: FaceShape? { faces.shape }
        var intensity: Double { faces.intensity }
        var faceBoxes: [CGRect] { faces.faceBoxes }
        var rank: Double { faces.rank }
    }

    /// One frame's faces: the largest one's features, shape and intensity, and every face's box.
    private struct FrameFaces {
        let face: FaceFeatures?
        let shape: FaceShape?
        let intensity: Double
        let faceBoxes: [CGRect]
        let primaryBox: CGRect?

        /// Frames with a face beat frames without one; among faces, the most intense wins.
        var rank: Double { face == nil ? -1 : intensity }
    }

    private static func analyzeFrame(_ frame: CGImage, baseline: RestingBaseline) throws -> FrameAnalysis {
        let handler = VNImageRequestHandler(cgImage: frame, options: [:])
        let faces = try readFaces(frame, handler: handler, baseline: baseline)
        let pose = readPose(frame, handler: handler, faceBox: faces.primaryBox)
        return FrameAnalysis(frame: frame, faces: faces, pose: pose)
    }

    /// The faces in one frame (face landmarks request): the largest face's seven features, and its `FaceShape` with
    /// the colors of the frame drawn at most `RGBAPixels.maximumSide` on its longer side.
    private static func readFaces(_ frame: CGImage, handler: VNImageRequestHandler,
                                  baseline: RestingBaseline) throws -> FrameFaces {
        let faceRequest = VNDetectFaceLandmarksRequest()
        try handler.perform([faceRequest])
        let faces = observations(faceRequest.results ?? [], as: VNFaceObservation.self)
        let primaryFace = faces.max(by: { area($0.boundingBox) < area($1.boundingBox) })
        let face = primaryFace.flatMap { FaceFeatureExtractor.features(from: $0) }
        var shape: FaceShape?
        if face != nil, let primaryFace {
            shape = FaceFeatureExtractor.shape(from: primaryFace, pixels: RGBAPixels(image: frame))
        }
        let intensity = face.map { baseline.intensity(of: $0) } ?? 0
        return FrameFaces(
            face: face,
            shape: shape,
            intensity: intensity,
            faceBoxes: faces.map { $0.boundingBox },
            primaryBox: primaryFace?.boundingBox
        )
    }

    /// The pose of the person whose face is `faceBox` (else the clearest body), hands included when a wrist is seen;
    /// nil without a body or in an image too small to read joints in.
    private static func readPose(_ frame: CGImage, handler: VNImageRequestHandler, faceBox: CGRect?) -> PoseFeatures? {
        guard min(frame.width, frame.height) >= minimumPosePixelSize else { return nil }
        let bodyRequest = VNDetectHumanBodyPoseRequest()
        guard (try? handler.perform([bodyRequest])) != nil else { return nil }
        let bodies = observations(bodyRequest.results ?? [], as: VNHumanBodyPoseObservation.self)
        guard let body = FaceFeatureExtractor.primaryBody(bodies, faceBox: faceBox, imageWidth: frame.width, imageHeight: frame.height) else {
            return nil
        }
        var hand: HandShape?
        if body[.leftWrist] != nil || body[.rightWrist] != nil {
            let handRequest = VNDetectHumanHandPoseRequest()
            handRequest.maximumHandCount = 4
            if (try? handler.perform([handRequest])) != nil {
                let hands = observations(handRequest.results ?? [], as: VNHumanHandPoseObservation.self)
                let joints = FaceFeatureExtractor.handJoints(hands, imageWidth: frame.width, imageHeight: frame.height)
                let box = FaceFeatureExtractor.poseBox(faceBox, imageWidth: frame.width, imageHeight: frame.height)
                hand = HandShape.strongest(of: body.ownHands(joints), faceBox: box)
            }
        }
        return PoseFeatures(joints: body, hand: hand)
    }

    /// The pose of the frame with the clearest gesture when it is one (an animation's gesture may peak in another
    /// frame than its face), else the chosen frame's.
    private static func clearestPose(frames: [FrameAnalysis], fallback: FrameAnalysis) -> PoseFeatures? {
        let strongest = frames.compactMap(\.pose).max { $0.gestureStrength < $1.gestureStrength }
        if let strongest, strongest.gestureStrength >= 0.3, strongest.gestureStrength > (fallback.pose?.gestureStrength ?? 0) {
            return strongest
        }
        return fallback.pose
    }

    /// Pose alone, for items analyzed before poses were described in detail: up to 3 frames, the clearest gesture
    /// wins (nil when no frame shows a body).
    static func analyzePose(url: URL) -> PoseReading {
        guard let image = load(url: url, maxPixelSize: poseAnalysisPixelSize) else { return .unreadable }
        var poses: [PoseFeatures] = []
        for frame in image.frames.isEmpty ? [image.cgImage] : image.frames {
            let handler = VNImageRequestHandler(cgImage: frame, options: [:])
            let faceRequest = VNDetectFaceRectanglesRequest()
            try? handler.perform([faceRequest])
            let faces = observations(faceRequest.results ?? [], as: VNFaceObservation.self)
            let primaryFace = faces.max(by: { area($0.boundingBox) < area($1.boundingBox) })
            if let pose = readPose(frame, handler: handler, faceBox: primaryFace?.boundingBox) {
                poses.append(pose)
            }
        }
        return .read(poses.max { $0.gestureStrength < $1.gestureStrength })
    }

    /// The face alone, for items whose face was read by an older analysis (`LibraryItem.currentFaceRevision`): the
    /// same frames as `analyze` and the same choice among them (a face beats none, the most intense face wins),
    /// without the feature print, labels, text or pose. Unreadable when the file can't be loaded or its first frame
    /// can't be read, as `analyze` would fail.
    static func analyzeFace(url: URL) -> FaceReading {
        guard let image = load(url: url) else { return .unreadable }
        let baseline = RestingBaseline()
        var best: FrameFaces?
        for (offset, frame) in (image.frames.isEmpty ? [image.cgImage] : image.frames).enumerated() {
            let handler = VNImageRequestHandler(cgImage: frame, options: [:])
            guard let candidate = try? readFaces(frame, handler: handler, baseline: baseline) else {
                if offset == 0 { return .unreadable }
                continue
            }
            if let current = best, current.rank >= candidate.rank { continue }
            best = candidate
        }
        guard let chosen = best else { return .unreadable }
        return .read(face: chosen.face, shape: chosen.shape, intensity: chosen.intensity)
    }

    private static func runFeaturePrint(handler: VNImageRequestHandler) throws -> [Float] {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = featurePrintRevision
        try handler.perform([request])
        guard let observation = observations(request.results ?? [], as: VNFeaturePrintObservation.self).first else {
            throw ImageAnalyzerError.noFeaturePrint
        }
        let values = floats(from: observation)
        guard !values.isEmpty else { throw ImageAnalyzerError.noFeaturePrint }
        return values
    }

    private static func classify(handler: VNImageRequestHandler) throws -> [String] {
        let request = VNClassifyImageRequest()
        try handler.perform([request])
        return observations(request.results ?? [], as: VNClassificationObservation.self)
            .filter { $0.confidence >= minimumLabelConfidence }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maximumLabelCount)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
    }

    /// All recognized lines joined with single spaces (not truncated).
    private static func recognizeText(handler: VNImageRequestHandler) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        try handler.perform([request])
        let lines = observations(request.results ?? [], as: VNRecognizedTextObservation.self)
            .compactMap { $0.topCandidates(1).first?.string }
        return lines
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Converts the observation's raw buffer to Float32 values, honoring its element type and count.
    private static func floats(from observation: VNFeaturePrintObservation) -> [Float] {
        let count = observation.elementCount
        let data = observation.data
        guard count > 0 else { return [] }
        switch observation.elementType {
        case .float:
            let byteCount = count * MemoryLayout<Float>.size
            guard data.count >= byteCount else { return [] }
            var values = [Float](repeating: 0, count: count)
            values.withUnsafeMutableBytes { destination in
                data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                    destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: source.prefix(byteCount)))
                }
            }
            return values
        case .double:
            let byteCount = count * MemoryLayout<Double>.size
            guard data.count >= byteCount else { return [] }
            var values = [Double](repeating: 0, count: count)
            values.withUnsafeMutableBytes { destination in
                data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                    destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: source.prefix(byteCount)))
                }
            }
            return values.map { Float($0) }
        default:
            return []
        }
    }

    /// Typed view of a request's results that works whether the SDK types `results` precisely or as `[VNObservation]`.
    private static func observations<T>(_ results: [Any], as type: T.Type) -> [T] {
        results.compactMap { $0 as? T }
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }
}
