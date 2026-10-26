import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import MemeMeCore
import os
import UniformTypeIdentifiers
import Vision

private let stickerLog = Logger(subsystem: "com.mememe.app", category: "stickers")

struct StickerCut {
    let pngURL: URL
    let faceEmbedding: [Float]     // feature print of the face crop (box expanded 20 %)
    let face: FaceFeatures?
    let intensity: Double
    let featurePrint: [Float]?     // feature print of the sticker image
    let contentHash: String
    let faceBox: CGRect            // Vision-normalized box in the source photo
}

private enum StickerError: Error {
    case unreadableImage
    case emptyCutout
    case renderFailed
    case encodingFailed
    case faceCropFailed
}

/// Cuts people out of photos (Vision subject lifting) and turns them into die-cut PNG stickers.
/// Synchronous and heavy: never call on the main thread.
enum StickerMaker {
    /// Longest side of a finished sticker, in pixels.
    private static let maximumSide: CGFloat = 512
    /// A face belongs to an instance when at least this share of its box carries the instance's label.
    private static let minimumLabelShare = 0.1
    /// Minimum overlap between an eligible box and a landmark observation to treat them as the same face.
    private static let minimumFaceOverlap: CGFloat = 0.3
    /// One context for every render (Core Image contexts are expensive and thread-safe).
    private static let renderContext = CIContext(options: [.cacheIntermediates: false])

    /// Facts + Vision-normalized boxes of eligible faces (StickerEligibility). Empty faces → not a photo of people.
    static func eligibleFaces(in url: URL) throws -> (facts: ImageFacts, faces: [CGRect]) {
        let analysis = try ImageAnalyzer.analyze(url: url, includeText: true)
        let boxes = analysis.faceBoxes
        let heights = boxes.map { Double($0.height) }
        let indices = StickerEligibility.eligibleFaceIndices(facts: analysis.facts, faceHeightFractions: heights)
        let faces = indices.filter { $0 >= 0 && $0 < boxes.count }.map { boxes[$0] }
        return (facts: analysis.facts, faces: faces)
    }

    /// macOS 14 subject lifting (VNGenerateForegroundInstanceMaskRequest): one sticker per person instance that
    /// contains an eligible face; white die-cut outline (radius ≈ 2.5 % of the longer side, ≥ 6 px);
    /// scaled to ≤ 512 px; PNG files written into `directory`.
    static func makeStickers(from url: URL, into directory: URL, faces: [CGRect], outline: Bool = true) throws -> [StickerCut] {
        guard !faces.isEmpty else { return [] }
        // Same decoding as ImageAnalyzer (orientation applied), so the normalized face boxes line up.
        guard let loaded = ImageAnalyzer.load(url: url) else { throw StickerError.unreadableImage }
        let image = loaded.cgImage

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let maskRequest = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([maskRequest])
        guard let observation = typed(maskRequest.results ?? [], as: VNInstanceMaskObservation.self).first else {
            return []
        }
        let instances = observation.allInstances
        guard !instances.isEmpty else { return [] }

        // Each face → the instance label that covers most of its box; keep the largest face per instance.
        let labels = instanceLabels(for: faces, mask: observation.instanceMask, instances: instances)
        var faceIndexForLabel: [Int: Int] = [:]
        var labelOrder: [Int] = []
        for (faceIndex, label) in labels.enumerated() {
            guard let label = label else { continue }
            if let current = faceIndexForLabel[label] {
                if area(faces[faceIndex]) > area(faces[current]) {
                    faceIndexForLabel[label] = faceIndex
                }
            } else {
                faceIndexForLabel[label] = faceIndex
                labelOrder.append(label)
            }
        }
        guard !labelOrder.isEmpty else { return [] }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let landmarkFaces = detectLandmarkFaces(handler: handler)

        var cuts: [StickerCut] = []
        for label in labelOrder {
            guard let faceIndex = faceIndexForLabel[label] else { continue }
            do {
                let cut = try makeCut(
                    instance: label,
                    observation: observation,
                    handler: handler,
                    image: image,
                    faceBox: faces[faceIndex],
                    landmarkFaces: landmarkFaces,
                    directory: directory,
                    outline: outline
                )
                cuts.append(cut)
            } catch {
                stickerLog.error("Sticker cut failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return cuts
    }

    // MARK: - One sticker

    private static func makeCut(
        instance: Int,
        observation: VNInstanceMaskObservation,
        handler: VNImageRequestHandler,
        image: CGImage,
        faceBox: CGRect,
        landmarkFaces: [VNFaceObservation],
        directory: URL,
        outline: Bool
    ) throws -> StickerCut {
        let maskedBuffer = try observation.generateMaskedImage(
            ofInstances: IndexSet(integer: instance),
            from: handler,
            croppedToInstancesExtent: true
        )
        let masked = CIImage(cvPixelBuffer: maskedBuffer)
        let cutout = masked.transformed(by: CGAffineTransform(translationX: -masked.extent.minX, y: -masked.extent.minY))
        let sticker = try render(cutout: cutout, outline: outline)
        let pngData = try encodePNG(sticker)

        let embedding = (try? faceEmbedding(image: image, faceBox: faceBox)) ?? []
        let face = bestLandmarkFace(for: faceBox, among: landmarkFaces).flatMap { FaceFeatureExtractor.features(from: $0) }
        let intensity = face.map { RestingBaseline().intensity(of: $0) } ?? 0
        let stickerPrint = try? ImageAnalyzer.featurePrint(of: sticker)

        let fileURL = directory.appendingPathComponent("sticker-\(UUID().uuidString).png", isDirectory: false)
        try pngData.write(to: fileURL, options: .atomic)

        return StickerCut(
            pngURL: fileURL,
            faceEmbedding: embedding,
            face: face,
            intensity: intensity,
            featurePrint: stickerPrint,
            contentHash: ImageAnalyzer.sha256Hex(pngData),
            faceBox: faceBox
        )
    }

    /// Scales the cut-out to fit 512 px (outline included), pads it, and adds the white die-cut outline.
    private static func render(cutout: CIImage, outline: Bool) throws -> CGImage {
        let extent = cutout.extent
        let longestSide = max(extent.width, extent.height)
        guard longestSide >= 1, extent.width.isFinite, extent.height.isFinite else { throw StickerError.emptyCutout }

        let radius: CGFloat = outline ? max(6, (0.025 * min(longestSide, maximumSide)).rounded()) : 0
        let padding: CGFloat = outline ? radius + 2 : 0
        let scale = min(1, (maximumSide - 2 * padding) / longestSide)

        var scaled = cutout
        if scale < 1 {
            scaled = cutout.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1.0,
            ])
        }
        let scaledExtent = scaled.extent
        scaled = scaled.transformed(by: CGAffineTransform(
            translationX: padding - scaledExtent.minX,
            y: padding - scaledExtent.minY
        ))
        let canvas = CGRect(
            x: 0,
            y: 0,
            width: min(maximumSide, (scaledExtent.width + 2 * padding).rounded(.up)),
            height: min(maximumSide, (scaledExtent.height + 2 * padding).rounded(.up))
        )

        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: canvas)
        let padded = scaled.composited(over: clear).cropped(to: canvas)

        var result = padded
        if outline {
            // Dilate the alpha, fill it with white, and put the cut-out on top.
            let dilated = padded
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: canvas)
            let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: canvas)
            let silhouette = white.applyingFilter("CISourceInCompositing", parameters: [
                kCIInputBackgroundImageKey: dilated,
            ])
            result = padded.applyingFilter("CISourceOverCompositing", parameters: [
                kCIInputBackgroundImageKey: silhouette,
            ])
        }
        result = result.cropped(to: canvas)

        guard let rendered = renderContext.createCGImage(
            result,
            from: canvas,
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        ) else {
            throw StickerError.renderFailed
        }
        return rendered
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw StickerError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw StickerError.encodingFailed }
        return output as Data
    }

    // MARK: - Faces

    /// Feature print of the face crop (box expanded 20 %, clamped to the image).
    private static func faceEmbedding(image: CGImage, faceBox: CGRect) throws -> [Float] {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        // Vision boxes are normalized with the origin at the bottom-left; CGImage cropping uses the top-left.
        var rect = CGRect(
            x: faceBox.minX * width,
            y: (1 - faceBox.maxY) * height,
            width: faceBox.width * width,
            height: faceBox.height * height
        )
        rect = rect.insetBy(dx: -rect.width * 0.1, dy: -rect.height * 0.1)
        rect = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !rect.isNull, !rect.isEmpty else { throw StickerError.faceCropFailed }
        rect = rect.integral
        guard rect.width >= 8, rect.height >= 8, let crop = image.cropping(to: rect) else {
            throw StickerError.faceCropFailed
        }
        return try ImageAnalyzer.featurePrint(of: crop)
    }

    private static func detectLandmarkFaces(handler: VNImageRequestHandler) -> [VNFaceObservation] {
        let request = VNDetectFaceLandmarksRequest()
        do {
            try handler.perform([request])
        } catch {
            stickerLog.error("Face landmarks failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        return typed(request.results ?? [], as: VNFaceObservation.self)
    }

    private static func bestLandmarkFace(for box: CGRect, among faces: [VNFaceObservation]) -> VNFaceObservation? {
        var best: VNFaceObservation?
        var bestOverlap = minimumFaceOverlap
        for face in faces {
            let overlap = intersectionOverUnion(box, face.boundingBox)
            if overlap >= bestOverlap {
                best = face
                bestOverlap = overlap
            }
        }
        return best
    }

    // MARK: - Instance mask

    /// For each face, the most common non-zero instance label inside its box (nil when too little of the box is lifted).
    private static func instanceLabels(for faces: [CGRect], mask: CVPixelBuffer, instances: IndexSet) -> [Int?] {
        let none: [Int?] = faces.map { _ in nil }
        guard CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent8 else {
            // Unknown layout: only a single instance can be assigned safely.
            if instances.count == 1, let only = instances.first {
                return faces.map { _ -> Int? in only }
            }
            return none
        }

        _ = CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { _ = CVPixelBufferUnlockBaseAddress(mask, .readOnly) }

        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(mask) else { return none }
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        return faces.map { box -> Int? in
            let maskWidth = CGFloat(width)
            let maskHeight = CGFloat(height)
            // Rows are top-down; Vision's y axis points up.
            let minColumn = clamp(Int((box.minX * maskWidth).rounded(.down)), lower: 0, upper: width - 1)
            let maxColumn = clamp(Int((box.maxX * maskWidth).rounded(.up)), lower: minColumn + 1, upper: width)
            let minRow = clamp(Int(((1 - box.maxY) * maskHeight).rounded(.down)), lower: 0, upper: height - 1)
            let maxRow = clamp(Int(((1 - box.minY) * maskHeight).rounded(.up)), lower: minRow + 1, upper: height)

            var counts = [Int](repeating: 0, count: 256)
            var total = 0
            for row in minRow..<maxRow {
                let rowStart = row * bytesPerRow
                for column in minColumn..<maxColumn {
                    counts[Int(pixels[rowStart + column])] += 1
                    total += 1
                }
            }
            guard total > 0 else { return nil }

            var bestLabel: Int?
            var bestCount = 0
            for label in 1..<256 where counts[label] > bestCount && instances.contains(label) {
                bestLabel = label
                bestCount = counts[label]
            }
            guard let label = bestLabel, Double(bestCount) / Double(total) >= minimumLabelShare else { return nil }
            return label
        }
    }

    // MARK: - Helpers

    /// Typed view of a request's results that works whether the SDK types `results` precisely or as `[VNObservation]`.
    private static func typed<T>(_ results: [Any], as type: T.Type) -> [T] {
        results.compactMap { $0 as? T }
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }

    private static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let shared = intersection.width * intersection.height
        let union = area(a) + area(b) - shared
        return union > 0 ? shared / union : 0
    }

    private static func clamp(_ value: Int, lower: Int, upper: Int) -> Int {
        min(max(value, lower), upper)
    }
}
