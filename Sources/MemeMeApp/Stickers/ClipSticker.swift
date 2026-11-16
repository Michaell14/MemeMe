import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers
import Vision

private let clipLog = Logger(subsystem: "com.mememe.app", category: "clip")

/// A clipped reaction, cut out: a die-cut PNG, or a moving sticker (a GIF on transparent).
struct ClipStickerData: Sendable {
    let data: Data
    let isGIF: Bool
}

/// "Clip me": you, cut out of the camera's picture by Apple's subject lifting (`VNGenerateForegroundInstanceMaskRequest`,
/// on this Mac) with a white die-cut outline. A photo becomes a still sticker; a clip becomes a moving one, each frame
/// cut out and framed alike so it doesn't jitter. Heavy: never on the main thread.
enum ClipSticker {
    /// The outline's width on a moving sticker's frames, in pixels (the clip is 320 px).
    private static let movingOutline: CGFloat = 5
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// The sticker for a capture: a still from its photo, a moving one from its GIF. nil when no one could be cut out.
    static func make(from result: CaptureResult) -> ClipStickerData? {
        if result.isGIF, let moving = moving(fromGIF: result.data) {
            return ClipStickerData(data: moving, isGIF: true)
        }
        // A photo, or a clip whose frames couldn't be cut: its best frame, still.
        guard let frame = result.stickerFrame ?? firstFrame(of: result.data), let png = still(from: frame) else {
            return nil
        }
        return ClipStickerData(data: png, isGIF: false)
    }

    /// Every subject in `frame` cut out, as a die-cut PNG (at most 512 px, `StickerMaker.render`).
    static func still(from frame: CGImage) -> Data? {
        let subjects = ScreenSubjects(image: frame)
        guard subjects.instanceCount > 0,
              let piece = try? subjects.piece(forInstances: IndexSet(integersIn: 1...subjects.instanceCount)) else {
            return nil
        }
        return try? ScreenSubjects.stickerPNG(of: piece)
    }

    // MARK: Moving

    /// Each frame cut out on transparent, cropped to the box every frame's subject fits in, with the white outline,
    /// as a looping GIF at the clip's speed. nil when no frame had anyone in it.
    private static func moving(fromGIF data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        var delay = 0.08
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
           let value = (gif[kCGImagePropertyGIFUnclampedDelayTime] ?? gif[kCGImagePropertyGIFDelayTime]) as? Double,
           value > 0 {
            delay = value
        }
        var cutouts: [CIImage] = []
        var union = CGRect.null
        for index in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let cutout = cutOut(frame)
            cutouts.append(cutout ?? CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: frame.width, height: frame.height)))
            if let cutout, let bounds = opaqueExtent(of: cutout) {
                union = union.union(bounds)
            }
        }
        guard !union.isNull, union.width >= 8, union.height >= 8 else {
            clipLog.info("No one to cut out of the clip")
            return nil
        }
        let radius = movingOutline
        let canvas = CGRect(x: 0, y: 0, width: (union.width + 2 * radius + 4).rounded(.up),
                            height: (union.height + 2 * radius + 4).rounded(.up))
        let shift = CGAffineTransform(translationX: radius + 2 - union.minX, y: radius + 2 - union.minY)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: canvas)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: canvas)
        var frames: [CGImage] = []
        for cutout in cutouts {
            let placed = cutout.transformed(by: shift).composited(over: clear).cropped(to: canvas)
            let grown = placed.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: canvas)
            let silhouette = white.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: grown])
            let framed = placed.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: silhouette])
                .cropped(to: canvas)
            if let image = context.createCGImage(framed, from: canvas, format: .RGBA8,
                                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) {
                frames.append(image)
            }
        }
        guard frames.count > 1 else { return nil }
        return CaptureEncoder.gif(frames, frameDelay: delay)
    }

    /// `frame` with everything but its subjects transparent (full size); nil when nothing stands out.
    private static func cutOut(_ frame: CGImage) -> CIImage? {
        let handler = VNImageRequestHandler(cgImage: frame, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty,
              let masked = try? observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler,
                                                                croppedToInstancesExtent: false) else {
            return nil
        }
        return CIImage(cvPixelBuffer: masked)
    }

    /// The box (Core Image's coordinates) around a cut-out's visible pixels.
    private static func opaqueExtent(of image: CIImage) -> CGRect? {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1,
              let rendered = context.createCGImage(image, from: extent, format: .RGBA8,
                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        let width = rendered.width
        let height = rendered.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let drawing = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        drawing.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where bytes[row + x * 4 + 3] > 8 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // The bitmap's first row is the top; Core Image's origin is the bottom.
        return CGRect(x: extent.minX + CGFloat(minX), y: extent.minY + CGFloat(height - 1 - maxY),
                      width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
    }

    private static func firstFrame(of data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
