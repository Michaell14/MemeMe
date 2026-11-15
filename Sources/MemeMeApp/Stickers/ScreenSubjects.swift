import AppKit
import CoreImage
import CoreVideo
import Foundation
import os
import ScreenCaptureKit
import Vision

private let screenLog = Logger(subsystem: "com.mememe.app", category: "screen-cut")

/// One selection on the screen, ready to show and to save: its cut-out (transparent around it) and where it sits on the
/// screen (normalized, origin top-left).
struct ScreenPiece: @unchecked Sendable {
    let rect: CGRect
    let cutout: CGImage
    /// The cut-out's silhouette grown by a few points, in the signal color: drawn under it, it is the outline.
    let outline: CGImage
    /// No subject was found in a dragged box: the box itself.
    let isRectangle: Bool
}

enum ScreenCutError: Error {
    case noDisplay
    case captureFailed
    case nothingCut
}

/// What is on a screen, split into subjects by Apple's subject lifting (`VNGenerateForegroundInstanceMaskRequest`,
/// macOS 14): click one to take it; a box dragged around something lifts the subjects inside it (the box itself when
/// there are none). Everything runs on this Mac. Heavy: never on the main thread.
final class ScreenSubjects: @unchecked Sendable {
    let image: CGImage
    /// How many subjects were found on the whole screen.
    let instanceCount: Int

    private let observation: VNInstanceMaskObservation?
    private let handler: VNImageRequestHandler
    /// The instance mask (one label per pixel, 0 for the background), top row first, and its size.
    private let labels: [UInt8]
    private let labelsWidth: Int
    private let labelsHeight: Int

    /// Longest side the screenshot is taken at: enough for a 512 px sticker of something small on screen.
    static let maximumSide = 2880
    /// The outline's width, in screenshot pixels.
    private static let outlineRadius: CGFloat = 4
    private static let context = CIContext(options: [.cacheIntermediates: false])
    /// Notch Black's signal color.
    private static let signal = CIColor(red: 1, green: 154.0 / 255.0, blue: 92.0 / 255.0, alpha: 1)

    init(image: CGImage) {
        self.image = image
        handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            screenLog.error("Subject lifting failed: \(error.localizedDescription, privacy: .public)")
        }
        let found = request.results?.first
        observation = found
        instanceCount = found?.allInstances.count ?? 0
        if let mask = found?.instanceMask {
            (labels, labelsWidth, labelsHeight) = ScreenSubjects.copyLabels(mask)
        } else {
            (labels, labelsWidth, labelsHeight) = ([], 0, 0)
        }
    }

    // MARK: Capturing

    /// The screen showing `screen`, without MemeMe's own windows; nil without Screen Recording access.
    static func capture(_ screen: NSScreen) async throws -> CGImage {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw ScreenCutError.noDisplay
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCutError.noDisplay
        }
        let ownBundleID = Bundle.main.bundleIdentifier
        let own = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleID }
        let filter = SCContentFilter(display: display, excludingWindows: own)
        let configuration = SCStreamConfiguration()
        let scale = min(screen.backingScaleFactor,
                        CGFloat(maximumSide) / CGFloat(max(display.width, display.height)))
        configuration.width = max(1, Int((CGFloat(display.width) * scale).rounded()))
        configuration.height = max(1, Int((CGFloat(display.height) * scale).rounded()))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    // MARK: Picking

    /// The subject under a point (normalized, origin top-left); nil over the background.
    func instance(at point: CGPoint) -> Int? {
        guard labelsWidth > 0, labelsHeight > 0, point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1 else {
            return nil
        }
        let x = min(labelsWidth - 1, Int(point.x * CGFloat(labelsWidth)))
        let y = min(labelsHeight - 1, Int(point.y * CGFloat(labelsHeight)))
        let label = Int(labels[y * labelsWidth + x])
        return label == 0 ? nil : label
    }

    /// The subjects `instances`, cut out of the screen.
    func piece(forInstances instances: IndexSet) throws -> ScreenPiece {
        guard let observation, !instances.isEmpty else { throw ScreenCutError.nothingCut }
        let masked = try observation.generateMaskedImage(ofInstances: instances, from: handler,
                                                         croppedToInstancesExtent: false)
        return try ScreenSubjects.piece(fromMasked: CIImage(cvPixelBuffer: masked), in: image, offset: .zero)
    }

    /// The subjects inside `box` (normalized, origin top-left), lifted from that part of the screen alone; the box
    /// itself when there are none.
    func piece(inBox box: CGRect) throws -> ScreenPiece {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let pixels = CGRect(x: box.minX * width, y: box.minY * height, width: box.width * width,
                            height: box.height * height).integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard pixels.width >= 8, pixels.height >= 8, let crop = image.cropping(to: pixels) else {
            throw ScreenCutError.nothingCut
        }
        let cropHandler = VNImageRequestHandler(cgImage: crop, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try? cropHandler.perform([request])
        if let found = request.results?.first, !found.allInstances.isEmpty,
           let masked = try? found.generateMaskedImage(ofInstances: found.allInstances, from: cropHandler,
                                                        croppedToInstancesExtent: false),
           let piece = try? ScreenSubjects.piece(fromMasked: CIImage(cvPixelBuffer: masked), in: image,
                                                 offset: pixels.origin) {
            return piece
        }
        // Nothing stands out: the box, as it is.
        let outline = try ScreenSubjects.outline(of: CIImage(cgImage: crop))
        return ScreenPiece(rect: CGRect(x: pixels.minX / width, y: pixels.minY / height,
                                        width: pixels.width / width, height: pixels.height / height),
                           cutout: crop, outline: outline, isRectangle: true)
    }

    // MARK: Stickers

    /// A die-cut sticker of `piece` (a white outline, at most 512 px), as PNG data.
    static func stickerPNG(of piece: ScreenPiece) throws -> Data {
        let rendered = try StickerMaker.render(cutout: CIImage(cgImage: piece.cutout), outline: !piece.isRectangle)
        return try StickerMaker.encodePNG(rendered)
    }

    /// A short name for what was cut out ("Cat", "Dog"), from Vision's image classifier; nil when it isn't sure.
    static func suggestedName(for piece: ScreenPiece) -> String? {
        let request = VNClassifyImageRequest()
        let classifier = VNImageRequestHandler(cgImage: piece.cutout, options: [:])
        try? classifier.perform([request])
        guard let best = request.results?.first(where: { $0.confidence >= 0.3 }) else { return nil }
        let words = best.identifier.split(separator: "_").joined(separator: " ")
        guard let first = words.first else { return nil }
        return String(first).uppercased() + words.dropFirst()
    }

    // MARK: Private

    /// The masked frame (transparent outside the subjects) cropped to what is left, placed at `offset` in `full`.
    private static func piece(fromMasked masked: CIImage, in full: CGImage, offset: CGPoint) throws -> ScreenPiece {
        let extent = masked.extent
        guard let frame = context.createCGImage(masked, from: extent, format: .RGBA8,
                                                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)),
              let bounds = opaqueBounds(of: frame),
              let cutout = frame.cropping(to: bounds) else {
            throw ScreenCutError.nothingCut
        }
        let outline = try ScreenSubjects.outline(of: CIImage(cgImage: cutout))
        let width = CGFloat(full.width)
        let height = CGFloat(full.height)
        return ScreenPiece(rect: CGRect(x: (offset.x + bounds.minX) / width, y: (offset.y + bounds.minY) / height,
                                        width: bounds.width / width, height: bounds.height / height),
                           cutout: cutout, outline: outline, isRectangle: false)
    }

    /// The cut-out's silhouette, grown by `outlineRadius` on every side, in the signal color (padded by the same).
    private static func outline(of cutout: CIImage) throws -> CGImage {
        let radius = outlineRadius
        let canvas = cutout.extent.insetBy(dx: -radius, dy: -radius)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: canvas)
        let padded = cutout.composited(over: clear).cropped(to: canvas)
        let grown = padded.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: canvas)
        let color = CIImage(color: signal).cropped(to: canvas)
        let silhouette = color.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: grown])
        guard let rendered = context.createCGImage(silhouette, from: canvas, format: .RGBA8,
                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw ScreenCutError.nothingCut
        }
        return rendered
    }

    /// The smallest rectangle (top-left origin, pixels) holding every pixel that isn't fully transparent.
    private static func opaqueBounds(of image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let drawing = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        drawing.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        bytes.withUnsafeBufferPointer { buffer in
            for y in 0..<height {
                let row = y * width * 4
                for x in 0..<width where buffer[row + x * 4 + 3] > 8 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // The bitmap's first row is the image's top row.
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The instance mask's labels, top row first.
    private static func copyLabels(_ buffer: CVPixelBuffer) -> ([UInt8], Int, Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            return ([], 0, 0)
        }
        var labels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                labels[y * width + x] = base[y * stride + x]
            }
        }
        return (labels, width, height)
    }
}
