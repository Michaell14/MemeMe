import AppKit
import Foundation
import ImageIO

/// A decoded thumbnail handed from the decoding task to the main actor. CGImage is immutable.
private struct DecodedThumbnail: @unchecked Sendable {
    let image: CGImage
}

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private final class Entry {
        let image: NSImage
        let maxPixel: Int

        init(image: NSImage, maxPixel: Int) {
            self.image = image
            self.maxPixel = maxPixel
        }
    }

    private let cache = NSCache<NSString, Entry>()
    /// Decodes in progress, keyed by size and URL, so concurrent requests share one decode.
    private var inFlight: [String: Task<DecodedThumbnail?, Never>] = [:]

    private init() {
        cache.countLimit = 300
    }

    /// Only entries decoded at `minPixel` or larger, so a 96 px HUD/avatar decode never stands in for a grid tile.
    func cached(_ url: URL, minPixel: Int = 256) -> NSImage? {
        guard let entry = cache.object(forKey: url.absoluteString as NSString),
              entry.maxPixel >= minPixel else { return nil }
        return entry.image
    }

    /// CGImageSourceCreateThumbnailAtIndex off the main actor; NSCache (≈300 entries).
    func thumbnail(for url: URL, maxPixel: Int = 256) async -> NSImage? {
        let urlKey = url.absoluteString
        let cacheKey = urlKey as NSString
        let pixelSize = max(1, maxPixel)
        if let entry = cache.object(forKey: cacheKey), entry.maxPixel >= pixelSize {
            return entry.image
        }

        let taskKey = "\(pixelSize)|\(urlKey)"
        let task: Task<DecodedThumbnail?, Never>
        if let running = inFlight[taskKey] {
            task = running
        } else {
            task = Task.detached(priority: .utility) {
                ThumbnailCache.decodeThumbnail(url: url, maxPixel: pixelSize)
            }
            inFlight[taskKey] = task
        }

        let decoded = await task.value
        inFlight[taskKey] = nil

        // Another caller may have stored this thumbnail while we were waiting.
        if let entry = cache.object(forKey: cacheKey), entry.maxPixel >= pixelSize {
            return entry.image
        }
        guard let decoded else { return nil }
        let image = NSImage(
            cgImage: decoded.image,
            size: NSSize(width: decoded.image.width, height: decoded.image.height)
        )
        cache.setObject(Entry(image: image, maxPixel: pixelSize), forKey: cacheKey)
        return image
    }

    /// First frame, EXIF orientation applied, longest side ≤ `maxPixel`.
    private nonisolated static func decodeThumbnail(url: URL, maxPixel: Int) -> DecodedThumbnail? {
        guard url.isFileURL else { return nil }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return DecodedThumbnail(image: image)
    }
}
