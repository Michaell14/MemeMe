import AppKit
import Foundation
import ImageIO
import MemeMeCore
import os

private let templateLog = Logger(subsystem: "com.mememe.app", category: "templates")

/// Imgflip's free list of popular templates (no key).
private let imgflipListURL = URL(string: "https://api.imgflip.com/get_memes")!

/// A decoded tile image handed from a background task to the main actor (CGImage is immutable).
private struct DecodedImage: @unchecked Sendable {
    let image: CGImage
}

/// The list as kept in the cache folder.
private struct SavedTemplateList: Codable, Sendable {
    let fetchedAt: Date
    let templates: [MemeTemplate]
}

/// Imgflip's answer: `{"success": true, "data": {"memes": [{"id", "name", "url", "width", "height", …}]}}`.
private struct ImgflipListResponse: Decodable {
    let success: Bool
    let data: Payload?

    struct Payload: Decodable {
        let memes: [Entry]
    }

    struct Entry: Decodable {
        let id: String
        let name: String
        let url: String
        let width: Int?
        let height: Int?
    }
}

/// One classic meme template from Imgflip's list of popular templates.
struct MemeTemplate: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let url: URL
    let width: Int
    let height: Int

    var ref: TemplateRef {
        TemplateRef(id: id, name: name)
    }
}

/// Imgflip's list of popular meme templates (Distracted Boyfriend, Drake, Surprised Pikachu…), for the classic memes
/// row. The list is public and the same for everyone: it is fetched at most once a day (no key, nothing about you in
/// the request) and kept in ~/Library/Caches/MemeMe/Templates. Which templates fit a face, a described pose or typed
/// words is decided on the Mac (`MemeTemplateCatalog`), so none of them goes to Imgflip. Images load from Imgflip
/// through ordinary HTTP caching; one you copy or drag goes to a short-lived file. Off with Web Discover.
@MainActor final class MemeTemplates {
    /// How long the list is used before asking Imgflip again (an older one is still used when Imgflip doesn't answer).
    static let listLifetime: TimeInterval = 24 * 3600
    private static let retryDelay: TimeInterval = 60
    private static let copyTimeout: TimeInterval = 8
    /// Files for copying and dragging are deleted after this.
    static let fileLifetime: TimeInterval = 3600
    /// Tile images are decoded at most this many pixels on a side.
    private static let tilePixelSize = 320

    private let store: LibraryStore
    private let session: URLSession
    private let root: URL
    private var list: [MemeTemplate]?
    private var listFetchedAt: Date?
    private var didLoadDiskList = false
    private var listTask: Task<[MemeTemplate]?, Never>?
    private var failedAt: Date?
    private let images = NSCache<NSString, NSImage>()
    private var imageTasks: [URL: Task<DecodedImage?, Never>] = [:]
    private var fullTasks: [URL: Task<Data?, Never>] = [:]
    private var fileTasks: [String: Task<URL?, Never>] = [:]

    /// `cacheRoot`: the cache folder (nil = ~/Library/Caches/MemeMe/Templates); tests pass a temp folder.
    /// `configuration`: the session's base configuration (nil = default); tests pass one that serves canned replies.
    init(store: LibraryStore, cacheRoot: URL?, configuration: URLSessionConfiguration? = nil) {
        self.store = store
        if let cacheRoot {
            root = cacheRoot
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
            root = caches.appendingPathComponent("MemeMe/Templates", isDirectory: true)
        }
        let config = (configuration?.copy() as? URLSessionConfiguration) ?? .default
        config.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 64 * 1024 * 1024,
                                   directory: root.appendingPathComponent("HTTP", isDirectory: true))
        config.requestCachePolicy = .useProtocolCachePolicy
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config)
        images.countLimit = 120
    }

    var isEnabled: Bool {
        store.settings.webDiscoverEnabled
    }

    /// The list from memory or the cache folder (any age); nil before it was ever fetched.
    var cachedList: [MemeTemplate]? {
        guard isEnabled else { return nil }
        loadDiskListIfNeeded()
        return list
    }

    /// Imgflip's templates, most popular first: the list from the last day at once, else a new fetch (an older list
    /// when Imgflip doesn't answer). nil when Web Discover is off or there is no list at all.
    func templates() async -> [MemeTemplate]? {
        guard isEnabled else { return nil }
        loadDiskListIfNeeded()
        if let list, let fetchedAt = listFetchedAt, abs(Date().timeIntervalSince(fetchedAt)) < MemeTemplates.listLifetime {
            return list
        }
        if let failed = failedAt, Date().timeIntervalSince(failed) < MemeTemplates.retryDelay {
            return list
        }
        let task: Task<[MemeTemplate]?, Never>
        if let running = listTask {
            task = running
        } else {
            let session = self.session
            task = Task.detached(priority: .userInitiated) {
                await MemeTemplates.fetchList(session: session)
            }
            listTask = task
        }
        let fetched = await task.value
        listTask = nil
        if let fetched, !fetched.isEmpty {
            list = fetched
            listFetchedAt = Date()
            failedAt = nil
            saveDiskList(fetched)
        } else {
            failedAt = Date()
        }
        return isEnabled ? list : nil
    }

    // MARK: - Images

    /// A tile's image if it is already decoded.
    func cachedImage(for template: MemeTemplate) -> NSImage? {
        images.object(forKey: template.url.absoluteString as NSString)
    }

    /// A tile's image, downsampled, through the HTTP cache.
    func image(for template: MemeTemplate) async -> NSImage? {
        if let image = cachedImage(for: template) {
            return image
        }
        let url = template.url
        let task: Task<DecodedImage?, Never>
        if let running = imageTasks[url] {
            task = running
        } else {
            let download = fullData(from: url, priority: .userInitiated)
            let maxPixels = MemeTemplates.tilePixelSize
            task = Task.detached(priority: .userInitiated) { () -> DecodedImage? in
                guard let data = await download.value else { return nil }
                return MemeTemplates.thumbnail(from: data, maxPixelSize: maxPixels).map { DecodedImage(image: $0) }
            }
            imageTasks[url] = task
        }
        let decoded = await task.value
        imageTasks[url] = nil
        if let image = cachedImage(for: template) {
            return image
        }
        guard let decoded else { return nil }
        let image = NSImage(cgImage: decoded.image, size: NSSize(width: decoded.image.width, height: decoded.image.height))
        images.setObject(image, forKey: url.absoluteString as NSString)
        return image
    }

    /// The template as a local file to copy or drag (gone within the hour). nil after 8 s or on failure; the
    /// download keeps going, so trying again is quick.
    func prepareForCopy(_ template: MemeTemplate) async -> URL? {
        let destination = copyFile(for: template)
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            return destination
        }
        let key = destination.lastPathComponent
        let task: Task<URL?, Never>
        if let running = fileTasks[key] {
            task = running
        } else {
            let download = fullData(from: template.url, priority: .userInitiated)
            task = Task.detached(priority: .userInitiated) { () -> URL? in
                guard let data = await download.value, !data.isEmpty else { return nil }
                do {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
                    try data.write(to: destination, options: .atomic)
                    return destination
                } catch {
                    templateLog.error("Saving a meme template to copy failed: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
            fileTasks[key] = task
            Task { [weak self] in
                _ = await task.value
                self?.fileTasks[key] = nil
            }
        }
        return await WebRace.value(of: task, timeout: MemeTemplates.copyTimeout)
    }

    /// Starts downloading a template so copying it is instant.
    func prefetchForCopy(_ template: MemeTemplate) {
        guard !FileManager.default.fileExists(atPath: copyFile(for: template).path) else { return }
        _ = fullData(from: template.url, priority: .utility)
    }

    /// Deletes copy files older than an hour.
    func pruneCache() {
        let files = filesDirectory
        let protected = Set(fileTasks.keys)
        let lifetime = MemeTemplates.fileLifetime
        Task.detached(priority: .utility) {
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
            guard let entries = try? FileManager.default.contentsOfDirectory(at: files, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
                return
            }
            let now = Date()
            for entry in entries where !protected.contains(entry.lastPathComponent) {
                let values = try? entry.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true else { continue }
                if now.timeIntervalSince(values?.contentModificationDate ?? .distantPast) > lifetime {
                    try? FileManager.default.removeItem(at: entry)
                }
            }
        }
    }

    // MARK: - Private

    private var listFile: URL {
        root.appendingPathComponent("templates.json", isDirectory: false)
    }

    private var filesDirectory: URL {
        root.appendingPathComponent("files", isDirectory: true)
    }

    /// "<id>.<jpg|png|gif>" in the files folder.
    private func copyFile(for template: MemeTemplate) -> URL {
        let id = String(template.id.unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }.map(Character.init).prefix(32))
        let pathExtension = template.url.pathExtension.lowercased()
        let safeExtension = ["jpg", "jpeg", "png", "gif"].contains(pathExtension) ? pathExtension : "jpg"
        return filesDirectory.appendingPathComponent((id.isEmpty ? "template" : id) + "." + safeExtension, isDirectory: false)
    }

    /// One shared download per image URL, through the session (so its HTTP cache keeps it).
    private func fullData(from remote: URL, priority: TaskPriority) -> Task<Data?, Never> {
        if let running = fullTasks[remote] { return running }
        let session = self.session
        let task = Task.detached(priority: priority) { () async -> Data? in
            do {
                let (data, response) = try await session.data(from: remote)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else { return nil }
                return data
            } catch {
                templateLog.error("Meme template download failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        fullTasks[remote] = task
        Task { [weak self] in
            _ = await task.value
            self?.fullTasks[remote] = nil
        }
        return task
    }

    private func loadDiskListIfNeeded() {
        guard !didLoadDiskList else { return }
        didLoadDiskList = true
        guard list == nil,
              let data = try? Data(contentsOf: listFile),
              let saved = try? JSONDecoder().decode(SavedTemplateList.self, from: data),
              !saved.templates.isEmpty else { return }
        list = saved.templates
        listFetchedAt = saved.fetchedAt
    }

    /// About 20 KB, once a day: written right away.
    private func saveDiskList(_ templates: [MemeTemplate]) {
        let saved = SavedTemplateList(fetchedAt: Date(), templates: templates)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: listFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try? data.write(to: listFile, options: .atomic)
    }

    /// The templates in Imgflip's order; only https images, each id once. nil when Imgflip doesn't answer.
    nonisolated static func parseList(_ data: Data) -> [MemeTemplate]? {
        guard let response = try? JSONDecoder().decode(ImgflipListResponse.self, from: data), response.success,
              let entries = response.data?.memes else { return nil }
        var seen = Set<String>()
        var templates: [MemeTemplate] = []
        for entry in entries {
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.id.isEmpty, !name.isEmpty, !seen.contains(entry.id),
                  let url = URL(string: entry.url), url.scheme?.lowercased() == "https" else { continue }
            seen.insert(entry.id)
            templates.append(MemeTemplate(id: entry.id, name: name, url: url, width: entry.width ?? 0, height: entry.height ?? 0))
        }
        return templates
    }

    nonisolated private static func fetchList(session: URLSession) async -> [MemeTemplate]? {
        var request = URLRequest(url: imgflipListURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return parseList(data)
        } catch {
            templateLog.error("Fetching Imgflip's meme templates failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The image scaled down to at most `maxPixelSize` on a side (EXIF orientation applied).
    nonisolated static func thumbnail(from data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
