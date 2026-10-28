import AppKit
import Foundation
import ImageIO
import MemeMeCore
import os
import UniformTypeIdentifiers

private let clipboardLog = Logger(subsystem: "com.mememe.app", category: "clipboard")

private enum ClipboardError: Error {
    case emptyFile
    case writeFailed
}

/// Pasteboard and drag representations of library items. Never pastes for the user.
enum Clipboard {
    /// changeCount right after MemeMe's last write; -1 before the first write.
    @MainActor private static var writtenChangeCount: Int = -1
    /// The folder of the copy MemeMe last put on the pasteboard.
    @MainActor private static var writtenDirectory: URL?

    private static let gifType = NSPasteboard.PasteboardType("com.compuserve.gif")
    private static let jpegType = NSPasteboard.PasteboardType("public.jpeg")
    private static let heicType = NSPasteboard.PasteboardType("public.heic")
    private static let webpType = NSPasteboard.PasteboardType("org.webmproject.webp")
    /// Temp copies older than this are deleted on each copy.
    private static let temporaryCopyLifetime: TimeInterval = 3600
    /// Stills are re-encoded as PNG with the longest side at most this many pixels.
    private static let maximumPNGPixelSize = 4096

    /// Writes a pasteable representation of `fileURL` for `item`; returns the pasteboard changeCount after writing.
    ///
    /// One pasteboard item: the file URL of a temp copy named by `neutralFileName(for:)`, plus
    /// `com.compuserve.gif` data for GIFs (so chat apps keep the animation) or PNG data for stills.
    @MainActor @discardableResult
    static func copy(fileURL: URL, item: LibraryItem) throws -> Int {
        removeStaleCopies()

        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { throw ClipboardError.emptyFile }

        let isGIF = isGIFData(data)
        var pngData: Data?
        if !isGIF {
            pngData = isPNGData(data) ? data : convertToPNG(data)
        }

        var fileName = neutralFileName(for: item)
        var fileData = data
        if !keepsOwnFileName(item) {
            // Neutral names must describe the bytes they hold.
            let baseName = (fileName as NSString).deletingPathExtension
            if isGIF {
                fileName = baseName + ".gif"
            } else if let png = pngData {
                fileName = baseName + ".png"
                fileData = png
            } else {
                let originalExtension = fileURL.pathExtension.lowercased()
                fileName = baseName + "." + (originalExtension.isEmpty ? "png" : originalExtension)
            }
        }

        let directory = try makeTemporaryDirectory()
        let temporaryURL = directory.appendingPathComponent(fileName, isDirectory: false)
        try fileData.write(to: temporaryURL, options: .atomic)

        let pasteboardItem = NSPasteboardItem()
        _ = pasteboardItem.setString(temporaryURL.absoluteString, forType: .fileURL)
        if isGIF {
            _ = pasteboardItem.setData(data, forType: gifType)
        } else if let png = pngData {
            _ = pasteboardItem.setData(png, forType: .png)
        }

        let pasteboard = NSPasteboard.general
        _ = pasteboard.clearContents()
        guard pasteboard.writeObjects([pasteboardItem]) else {
            clipboardLog.error("Writing to the pasteboard failed")
            throw ClipboardError.writeFailed
        }
        writtenChangeCount = pasteboard.changeCount
        writtenDirectory = directory
        return writtenChangeCount
    }

    @MainActor static var lastWriteChangeCount: Int {
        writtenChangeCount
    }

    /// The folder of MemeMe's copy while it is still what the pasteboard holds; nil once something else was copied.
    @MainActor static var directoryOnPasteboard: URL? {
        NSPasteboard.general.changeCount == writtenChangeCount ? writtenDirectory : nil
    }

    /// When the pasteboard holds an image (or image file) that MemeMe didn't write, returns a local file URL (temp copy for raw image data).
    @MainActor static func imageOnPasteboard() -> URL? {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != writtenChangeCount else { return nil }

        let readOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: readOptions) as? [URL]) ?? []
        if !fileURLs.isEmpty {
            // Copied files: only an image file counts (Finder also puts the file's icon on the pasteboard).
            return fileURLs.first(where: { isImageFile($0) })
        }

        guard let availableTypes = pasteboard.types else { return nil }
        let rawTypes: [(type: NSPasteboard.PasteboardType, fileExtension: String)] = [
            (gifType, "gif"),
            (.png, "png"),
            (jpegType, "jpg"),
            (heicType, "heic"),
            (webpType, "webp"),
            (.tiff, "tiff"),
        ]
        for candidate in rawTypes where availableTypes.contains(candidate.type) {
            guard let data = pasteboard.data(forType: candidate.type), !data.isEmpty else { continue }
            removeStaleCopies()
            do {
                let directory = try makeTemporaryDirectory()
                let url = directory.appendingPathComponent("pasted." + candidate.fileExtension, isDirectory: false)
                try data.write(to: url, options: .atomic)
                return url
            } catch {
                clipboardLog.error("Saving pasted image failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        return nil
    }

    /// Drag representation; non-own items are dragged as a neutrally named temp copy.
    static func dragItemProvider(for item: LibraryItem, fileURL: URL) -> NSItemProvider {
        let dragURL = neutralCopyForDrag(item: item, fileURL: fileURL) ?? fileURL
        let provider = NSItemProvider(contentsOf: dragURL) ?? NSItemProvider(object: dragURL as NSURL)
        provider.suggestedName = dragURL.deletingPathExtension().lastPathComponent
        return provider
    }

    /// Own items keep their file name; else "reaction.gif" / "sticker.png" / "reaction.png".
    static func neutralFileName(for item: LibraryItem) -> String {
        if keepsOwnFileName(item) {
            let name = item.fileURL.lastPathComponent
            if !name.isEmpty && name != "/" {
                return name
            }
        }
        if item.isSticker {
            return "sticker.png"
        }
        let isGIF = item.isAnimated
            || item.fileURL.pathExtension.lowercased() == "gif"
            || item.remoteURL?.pathExtension.lowercased() == "gif"
        return isGIF ? "reaction.gif" : "reaction.png"
    }

    // MARK: - Private

    /// The user's own files (not friend stickers, whose names could identify someone).
    private static func keepsOwnFileName(_ item: LibraryItem) -> Bool {
        item.isOwn && !item.isSticker
    }

    /// Where copies for the pasteboard and for dragging live; ~/Library/Caches/MemeMe/Clipboard.
    static func clipboardDirectory() -> URL {
        let fileManager = FileManager.default
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        return caches.appendingPathComponent("MemeMe/Clipboard", isDirectory: true)
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = clipboardDirectory().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory
    }

    /// Deletes copies older than an hour, except `kept` (the copy still on the pasteboard, whose file URL it holds).
    static func removeStaleCopies(keeping kept: URL? = nil) {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: clipboardDirectory(),
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-temporaryCopyLifetime)
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            let date = values?.creationDate ?? values?.contentModificationDate ?? Date.distantPast
            if date < cutoff && entry.lastPathComponent != kept?.lastPathComponent {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    private static func neutralCopyForDrag(item: LibraryItem, fileURL: URL) -> URL? {
        guard !keepsOwnFileName(item), fileURL.isFileURL else { return nil }
        removeStaleCopies()
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe), !data.isEmpty else { return nil }

        let baseName = (neutralFileName(for: item) as NSString).deletingPathExtension
        let fileExtension: String
        if isGIFData(data) {
            fileExtension = "gif"
        } else if isPNGData(data) {
            fileExtension = "png"
        } else {
            let original = fileURL.pathExtension.lowercased()
            fileExtension = original.isEmpty ? "png" : original
        }

        do {
            let directory = try makeTemporaryDirectory()
            let destination = directory.appendingPathComponent(baseName + "." + fileExtension, isDirectory: false)
            try FileManager.default.copyItem(at: fileURL, to: destination)
            return destination
        } catch {
            clipboardLog.error("Preparing drag copy failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func isImageFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image)
        }
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.conforms(to: .image)
        }
        return false
    }

    private static func isGIFData(_ data: Data) -> Bool {
        data.count >= 6 && data.prefix(4).elementsEqual([0x47, 0x49, 0x46, 0x38])   // "GIF8"
    }

    private static func isPNGData(_ data: Data) -> Bool {
        data.count >= 8 && data.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    /// First frame with its orientation applied, encoded as PNG.
    private static func convertToPNG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPNGPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
