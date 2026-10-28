import CoreGraphics
import CoreText
import Foundation
import ImageIO
@testable import MemeMeApp
import MemeMeCore
import XCTest

/// XCTest on macOS re-exports DeveloperToolsSupport, which also declares a `LibraryItem`.
/// This module-level alias shadows it (and the app's own alias) for every test file.
typealias LibraryItem = MemeMeCore.LibraryItem

// MARK: - Temporary directories

/// A fresh temporary directory for one test. Call `remove()` in a `defer`.
struct TestSandbox {
    let url: URL

    init(_ name: String = #function) throws {
        let safeName = String(name.filter { $0.isLetter || $0.isNumber }.prefix(60))
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemeMeAppTests-\(safeName)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name, isDirectory: false)
    }

    func directory(_ name: String) throws -> URL {
        let directory = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Names of the visible files in `directory` (sorted); [] when it doesn't exist.
func visibleFileNames(in directory: URL) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter { !$0.hasPrefix(".") }.sorted()
}

// MARK: - Generated images (CoreGraphics / CoreText / ImageIO only)

enum TestImageError: Error {
    case contextUnavailable
    case encodingFailed(String)
}

enum TestImages {
    /// Opaque 8-bit RGB bitmap context (origin bottom-left).
    static func makeContext(width: Int, height: Int) throws -> CGContext {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw TestImageError.contextUnavailable
        }
        return context
    }

    static func makeImage(_ context: CGContext) throws -> CGImage {
        guard let image = context.makeImage() else { throw TestImageError.contextUnavailable }
        return image
    }

    /// A plain background with a rectangle and a circle; `seed` changes the colors, so the bytes differ.
    static func shapes(width: Int = 256, height: Int = 256, seed: Int = 0) throws -> CGImage {
        let context = try makeContext(width: width, height: height)
        let w = CGFloat(width)
        let h = CGFloat(height)
        let s = CGFloat(abs(seed) % 7) / 7
        context.setFillColor(red: 0.95, green: 0.9 - 0.3 * s, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setFillColor(red: 0.2 + 0.6 * s, green: 0.3, blue: 0.7 - 0.4 * s, alpha: 1)
        context.fill(CGRect(x: w * 0.15, y: h * 0.2, width: w * 0.4, height: h * 0.35))
        context.setFillColor(red: 0.9, green: 0.4 + 0.4 * s, blue: 0.1, alpha: 1)
        context.fillEllipse(in: CGRect(x: w * 0.5, y: h * 0.45, width: w * 0.35, height: h * 0.35))
        return try makeImage(context)
    }

    /// Large black bold text centered on white.
    static func text(_ string: String, width: Int = 1200, height: Int = 400, fontSize: CGFloat = 170) throws -> CGImage {
        let context = try makeContext(width: width, height: height)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let attributed = NSAttributedString(string: string, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        let bounds = CTLineGetImageBounds(line, context)

        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.textPosition = CGPoint(
            x: (CGFloat(width) - bounds.width) / 2 - bounds.minX,
            y: (CGFloat(height) - bounds.height) / 2 - bounds.minY
        )
        CTLineDraw(line, context)
        return try makeImage(context)
    }

    /// Sky, sun, mountains and grass: no people, no text.
    static func landscape(width: Int = 640, height: Int = 427) throws -> CGImage {
        let context = try makeContext(width: width, height: height)
        let w = CGFloat(width)
        let h = CGFloat(height)

        // Sky in bands, lighter toward the horizon.
        let bands = 12
        let bandHeight = h * 0.65 / CGFloat(bands)
        for band in 0..<bands {
            let t = CGFloat(band) / CGFloat(bands - 1)
            context.setFillColor(red: 0.35 + 0.4 * t, green: 0.55 + 0.3 * t, blue: 0.95, alpha: 1)
            context.fill(CGRect(x: 0, y: h - CGFloat(band + 1) * bandHeight, width: w, height: bandHeight + 1))
        }

        // Sun.
        context.setFillColor(red: 1, green: 0.85, blue: 0.3, alpha: 1)
        context.fillEllipse(in: CGRect(x: w * 0.72, y: h * 0.72, width: w * 0.1, height: w * 0.1))

        // Mountains.
        context.setFillColor(red: 0.42, green: 0.40, blue: 0.45, alpha: 1)
        context.beginPath()
        context.move(to: CGPoint(x: 0, y: h * 0.35))
        context.addLine(to: CGPoint(x: w * 0.25, y: h * 0.62))
        context.addLine(to: CGPoint(x: w * 0.45, y: h * 0.42))
        context.addLine(to: CGPoint(x: w * 0.65, y: h * 0.58))
        context.addLine(to: CGPoint(x: w, y: h * 0.35))
        context.closePath()
        context.fillPath()

        // Grass.
        context.setFillColor(red: 0.30, green: 0.62, blue: 0.28, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.36))
        return try makeImage(context)
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try write([image], type: "public.png", to: url, fileProperties: nil, frameProperties: nil)
    }

    /// JPEG with optional per-image metadata (e.g. TIFF Make/Model, EXIF orientation).
    static func writeJPEG(_ image: CGImage, to url: URL, properties: [String: Any]? = nil) throws {
        try write([image], type: "public.jpeg", to: url, fileProperties: nil, frameProperties: properties)
    }

    /// Looping GIF; more than one frame makes it animated.
    static func writeGIF(_ frames: [CGImage], to url: URL, delay: Double = 0.1) throws {
        let fileProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0],
        ]
        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: delay],
        ]
        try write(frames, type: "com.compuserve.gif", to: url, fileProperties: fileProperties, frameProperties: frameProperties)
    }

    private static func write(
        _ images: [CGImage],
        type: String,
        to url: URL,
        fileProperties: [String: Any]?,
        frameProperties: [String: Any]?
    ) throws {
        guard !images.isEmpty,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, images.count, nil) else {
            throw TestImageError.encodingFailed(type)
        }
        if let fileProperties = fileProperties {
            CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
        }
        let perImage = frameProperties.map { $0 as CFDictionary }
        for image in images {
            CGImageDestinationAddImage(destination, image, perImage)
        }
        guard CGImageDestinationFinalize(destination) else { throw TestImageError.encodingFailed(type) }
    }
}

// MARK: - Vision

/// `ImageAnalyzer.analyze(url:)` with a failure message that says the test machine needs Vision.
func analyzeWithVision(
    _ url: URL,
    includeText: Bool = true,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> ImageAnalysis {
    do {
        return try ImageAnalyzer.analyze(url: url, includeText: includeText)
    } catch {
        XCTFail(
            "ImageAnalyzer.analyze threw for \(url.lastPathComponent): \(error). "
                + "This test needs Vision (face landmarks, feature print, text recognition) on the test machine.",
            file: file,
            line: line
        )
        throw error
    }
}

// MARK: - Main-actor polling

/// Polls `condition` on the main actor every 10 ms until it holds (true) or `timeout` passes (false).
@MainActor
func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}
