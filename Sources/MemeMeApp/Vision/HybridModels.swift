import CoreGraphics
import CoreML
import Foundation
import ImageIO
import MemeMeCore
import os
import Vision

private let hybridLog = Logger(subsystem: "com.mememe.app", category: "hybrid")

/// The hybrid matcher's two Core ML models and the zero-shot prompts (`scripts/hybrid/convert_models.py`):
/// `CLIPImage` (OpenCLIP ViT-B-32-quickgelu image tower) and `HSEmotion` (EfficientNet-B0, 8 emotions).
/// The app bundle carries them compiled in Contents/Resources/Hybrid (`scripts/build-app.sh`); the environment
/// variable `MEMEME_HYBRID_MODELS` names another folder (tests, benchmarks), holding .mlmodelc or .mlpackage files.
/// Without them the app runs the classic matcher. Predictions are serialized per model; any thread may call.
final class HybridModels: @unchecked Sendable {
    static let directoryEnvironmentKey = "MEMEME_HYBRID_MODELS"

    let prompts: EmotionPrompts
    let directory: URL
    private let clip: MLModel
    private let hse: MLModel
    private let clipLock = NSLock()
    private let hseLock = NSLock()

    /// Loaded once, on first use; nil when the models aren't there or don't load.
    static let shared: HybridModels? = {
        guard let directory = defaultDirectory() else {
            hybridLog.notice("No hybrid models in the bundle: the classic matcher is used")
            return nil
        }
        do {
            return try HybridModels(directory: directory)
        } catch {
            hybridLog.error("Loading the hybrid models failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    static func defaultDirectory() -> URL? {
        if let path = ProcessInfo.processInfo.environment[directoryEnvironmentKey], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        guard let resources = Bundle.main.resourceURL else { return nil }
        let directory = resources.appendingPathComponent("Hybrid", isDirectory: true)
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("emotion_prompts.json").path)
            ? directory : nil
    }

    init(directory: URL, computeUnits: MLComputeUnits = .all) throws {
        self.directory = directory
        guard let prompts = EmotionPrompts.load(from: directory.appendingPathComponent("emotion_prompts.json")) else {
            throw HybridError.missing("emotion_prompts.json")
        }
        self.prompts = prompts
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        clip = try HybridModels.model(named: "CLIPImage", in: directory, configuration: configuration)
        hse = try HybridModels.model(named: "HSEmotion", in: directory, configuration: configuration)
    }

    private static func model(named name: String, in directory: URL, configuration: MLModelConfiguration) throws -> MLModel {
        let compiled = directory.appendingPathComponent(name + ".mlmodelc", isDirectory: true)
        if FileManager.default.fileExists(atPath: compiled.path) {
            return try MLModel(contentsOf: compiled, configuration: configuration)
        }
        let package = directory.appendingPathComponent(name + ".mlpackage", isDirectory: true)
        guard FileManager.default.fileExists(atPath: package.path) else { throw HybridError.missing(name) }
        let url = try MLModel.compileModel(at: package)
        return try MLModel(contentsOf: url, configuration: configuration)
    }

    /// CLIP of an image (open_clip's preprocessing), L2-normalized, 512 numbers.
    func clipEmbedding(_ image: RGBImage) throws -> [Float] {
        let input = HybridPreprocess.clipInput(image)
        let output = try predict(clip, lock: clipLock, input: input, output: "embedding")
        guard output.count == HybridMatcher.embeddingSize else { throw HybridError.badOutput("embedding") }
        return HybridMatcher.l2Normalized(output)
    }

    /// HSEmotion's 8 probabilities for a face crop.
    func emotion(_ face: RGBImage) throws -> [Double] {
        let input = HybridPreprocess.emotionInput(face)
        let logits = try predict(hse, lock: hseLock, input: input, output: "logits")
        guard logits.count == HSEmotionClass.allCases.count else { throw HybridError.badOutput("logits") }
        return HybridMatcher.softmax(logits.map(Double.init))
    }

    func zeroShot(_ embedding: [Float]) -> [Double] {
        HybridMatcher.zeroShot(embedding: embedding, prompts: prompts)
    }

    /// One prediction each, so the first real one doesn't pay for loading onto the Neural Engine.
    func warmUp() {
        let grey = RGBImage(width: 8, height: 8, pixels: Array(repeating: 128, count: 192))
        _ = try? clipEmbedding(grey)
        _ = try? emotion(grey)
    }

    private func predict(_ model: MLModel, lock: NSLock, input: [Float], output: String) throws -> [Float] {
        let array = try MLMultiArray(shape: [1, 3, 224, 224], dataType: .float32)
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: input.count)
        input.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: input.count) }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: array)])
        lock.lock()
        defer { lock.unlock() }
        let result = try model.prediction(from: provider)
        guard let values = result.featureValue(for: output)?.multiArrayValue else { throw HybridError.badOutput(output) }
        return HybridModels.floats(values)
    }

    static func floats(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        switch array.dataType {
        case .float32:
            let p = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            return Array(UnsafeBufferPointer(start: p, count: count))
        case .double:
            let p = array.dataPointer.bindMemory(to: Double.self, capacity: count)
            return UnsafeBufferPointer(start: p, count: count).map { Float($0) }
        default:
            return (0..<count).map { array[$0].floatValue }
        }
    }
}

enum HybridError: Error, LocalizedError {
    case missing(String)
    case badOutput(String)
    case unreadable

    var errorDescription: String? {
        switch self {
        case let .missing(name): return "hybrid model file missing: \(name)"
        case let .badOutput(name): return "unexpected model output: \(name)"
        case .unreadable: return "image could not be read"
        }
    }
}

/// The hybrid matcher's image side: pictures to `RGBImage`, the largest face, index entries and held-face queries.
enum HybridAnalyzer {
    /// The picture drawn into 8-bit sRGB (alpha dropped onto black), PIL's convert("RGB") for ordinary images.
    static func rgbImage(from image: CGImage) -> RGBImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return bytes.withUnsafeBytes { RGBImage(fourChannel: $0, width: width, height: height, bytesPerRow: bytesPerRow, bgra: false) }
    }

    /// The largest face's crop box (Vision's face detector; the benchmark's margin and rounding); nil without a face.
    static func largestFaceCrop(in image: CGImage) -> PixelRect? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        return largestFaceCrop(request.results ?? [], imageWidth: image.width, imageHeight: image.height)
    }

    /// Of Vision's faces, the crop of the largest whose box is at least 12 px each way.
    static func largestFaceCrop(_ faces: [VNFaceObservation], imageWidth: Int, imageHeight: Int) -> PixelRect? {
        let crops = faces.compactMap { face -> (area: Double, rect: PixelRect)? in
            let box = face.boundingBox
            guard let rect = HybridPreprocess.faceCrop(visionBox: box.minX, y: box.minY, width: box.width, height: box.height,
                                                       imageWidth: imageWidth, imageHeight: imageHeight) else { return nil }
            return (Double(box.width * box.height), rect)
        }
        return crops.max(by: { $0.area < $1.area })?.rect
    }

    /// An index entry for a picture: CLIP of the whole of it, the largest face's HSEmotion when there is one, the
    /// zero-shot probabilities of the whole picture.
    static func entry(for image: CGImage, key: String, contentHash: String, models: HybridModels) throws -> HybridIndexEntry {
        guard let rgb = rgbImage(from: image) else { throw HybridError.unreadable }
        let crop = largestFaceCrop(in: image)
        return try entry(for: rgb, faceCrop: crop, key: key, contentHash: contentHash, models: models)
    }

    static func entry(for rgb: RGBImage, faceCrop crop: PixelRect?, key: String, contentHash: String,
                      models: HybridModels) throws -> HybridIndexEntry {
        let full = try models.clipEmbedding(rgb)
        let emo = try crop.map { try models.emotion(rgb.cropped(to: $0)) }
        return HybridIndexEntry(key: key, contentHash: contentHash, clipFull: full, hasFace: crop != nil, emo: emo,
                                zs: models.zeroShot(full))
    }

    /// An image file's entry, from its first frame (animated GIFs too), oriented as shown.
    static func entry(forFile url: URL, key: String, contentHash: String, models: HybridModels) throws -> HybridIndexEntry {
        guard let image = firstFrame(of: url) else { throw HybridError.unreadable }
        return try entry(for: image, key: key, contentHash: contentHash, models: models)
    }

    static func entry(forData data: Data, key: String, contentHash: String, models: HybridModels) throws -> HybridIndexEntry {
        guard let image = firstFrame(of: data) else { throw HybridError.unreadable }
        return try entry(for: image, key: key, contentHash: contentHash, models: models)
    }

    static func firstFrame(of url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url), data.count <= 25 * 1024 * 1024 else { return nil }
        return firstFrame(of: data)
    }

    /// Frame 0 at full size, turned by its EXIF orientation (PIL's exif_transpose); at most 4096 px on its longer side.
    static func firstFrame(of data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        if orientation == 1, max(width, height) <= 4096 {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(4096, max(width, height, 1)),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The held face's query: CLIP of the whole frame, the crop's emotion (read live, `emotion`, else now), and the
    /// zero-shot probabilities of CLIP on the crop (the whole frame without a face).
    static func query(frame: RGBImage, faceCrop crop: PixelRect?, emotion: [Double]?, models: HybridModels) throws -> HybridQuery {
        let face = crop.map { frame.cropped(to: $0) } ?? frame
        let full = try models.clipEmbedding(frame)
        let faceEmbedding = crop == nil ? full : try models.clipEmbedding(face)
        let emo = try emotion ?? models.emotion(face)
        return HybridQuery(full: full, emotion: emo, zeroShot: models.zeroShot(faceEmbedding))
    }
}
