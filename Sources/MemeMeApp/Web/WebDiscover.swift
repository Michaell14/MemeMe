import Combine
import CryptoKit
import Foundation
import MemeMeCore
import os

private let webLog = Logger(subsystem: "com.mememe.app", category: "web")

/// GIPHY results for one mood, analyzed on-device and cached for 24 h.
///
/// Only the mood word leaves the Mac. Searches are rate-limited (90 per rolling hour, persisted),
/// stills are downloaded in parallel and analyzed off the main actor, and slow round-trips are
/// dropped from the current grid while still filling the cache for next time.
@MainActor final class WebDiscover: ObservableObject {
    @Published private(set) var isFetching: Bool = false

    private let store: LibraryStore
    private let paths: WebPaths
    private let session: URLSession
    private let ioQueue = DispatchQueue(label: "com.mememe.web.io", qos: .utility)

    private var manifests: [Mood: MoodManifest] = [:]
    /// Moods whose manifest file has been looked for on disk.
    private var checkedDisk: Set<Mood> = []
    private var fetches: [Mood: Task<MoodManifest?, Never>] = [:]
    private var failedAt: [Mood: Date] = [:]
    /// In-flight downloads keyed by destination file name, so callers share one download.
    private var fileTasks: [String: Task<URL?, Never>] = [:]
    /// Network searches in the last hour (persisted).
    private var searchTimes: [Date] = []
    private var prefetchTask: Task<Void, Never>?
    private var prefetchGeneration = 0
    private var isPruning = false
    private var lastPruneAt = Date.distantPast

    private static let freshness: TimeInterval = 24 * 3600
    private static let searchesPerHour = 90
    /// Background prefetch stops here, keeping the rest of the hourly budget for live searches.
    private static let prefetchBudget = 60
    private static let retryDelay: TimeInterval = 60
    private static let copyTimeout: TimeInterval = 8
    private static let pruneInterval: TimeInterval = 600

    init(store: LibraryStore) {
        self.store = store
        paths = WebPaths.make()
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration)
        searchTimes = WebFetcher.loadSearchTimes(from: paths.rateURL)
        pruneSearchTimes()
    }

    /// settings.webDiscoverEnabled && an API key exists && under the rate limit.
    var isAvailable: Bool {
        store.settings.webDiscoverEnabled && apiKey != nil && recentSearchCount < WebDiscover.searchesPerHour
    }

    /// Instant: analyzed items for the mood if cached and fresh (24 h), else [].
    func cachedItems(for mood: Mood) -> [LibraryItem] {
        guard store.settings.webDiscoverEnabled, let manifest = freshManifest(for: mood) else { return [] }
        return manifest.items
    }

    /// Cache first; otherwise search + download stills in parallel + analyze off-main.
    /// Returns [] on timeout/error (the fetch continues in the background and fills the cache).
    func items(for mood: Mood, timeout: TimeInterval = 1.5) async -> [LibraryItem] {
        guard store.settings.webDiscoverEnabled else { return [] }
        if let manifest = freshManifest(for: mood) {
            return manifest.items
        }
        guard let task = startFetch(for: mood, priority: .userInitiated) else { return [] }
        let manifest = await WebRace.value(of: task, timeout: max(0, timeout))
        guard store.settings.webDiscoverEnabled else { return [] }
        return manifest?.items ?? []
    }

    /// Background warm-up for moods not cached; skipped on expensive networks or when SystemConditions.shouldDeferBackgroundWork.
    func prefetch(_ moods: [Mood]) {
        SystemConditions.startMonitoring()
        var unique: [Mood] = []
        for mood in moods where !unique.contains(mood) {
            unique.append(mood)
        }
        guard !unique.isEmpty else { return }
        let queue = unique

        prefetchTask?.cancel()
        prefetchGeneration += 1
        let generation = prefetchGeneration
        prefetchTask = Task(priority: .utility) { [weak self] in
            // Let launch settle and the network monitor report before deciding.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            for mood in queue {
                guard !Task.isCancelled, let self = self else { return }
                guard self.canPrefetch else { break }
                if self.freshManifest(for: mood) != nil { continue }
                guard let task = self.startFetch(for: mood, priority: .utility) else { continue }
                _ = await task.value
            }
            self?.prefetchFinished(generation: generation)
        }
    }

    /// Local animated preview file for a web item (downloads previewURL once), nil for non-web items.
    func localPreview(for item: LibraryItem) async -> URL? {
        guard item.kind == .web,
              let fileID = WebFetcher.fileID(of: item),
              let remote = item.previewURL ?? item.remoteURL else {
            return nil
        }
        let destination = paths.files.appendingPathComponent(fileID + "-preview.gif", isDirectory: false)
        if FileManager.default.fileExists(atPath: destination.path) {
            WebFetcher.touch(destination)
            return destination
        }
        return await downloadTask(from: remote, to: destination, requestTimeout: 20, priority: .userInitiated).value
    }

    /// Downloads remoteURL (if needed) and returns the local GIF file to copy. Times out after 8 s.
    /// Non-web items return their own file.
    func prepareForCopy(_ item: LibraryItem) async -> URL? {
        guard item.kind == .web else {
            return FileManager.default.fileExists(atPath: item.fileURL.path) ? item.fileURL : nil
        }
        guard let fileID = WebFetcher.fileID(of: item), let remote = item.remoteURL else { return nil }
        let destination = paths.files.appendingPathComponent(fileID + "-full.gif", isDirectory: false)
        if FileManager.default.fileExists(atPath: destination.path) {
            WebFetcher.touch(destination)
            return destination
        }
        let task = downloadTask(from: remote, to: destination, requestTimeout: 30, priority: .userInitiated)
        return await WebRace.value(of: task, timeout: WebDiscover.copyTimeout)
    }

    /// Starts downloading the full GIFs of the first three web items so committing them is instant.
    func prefetchForCopy(_ items: [LibraryItem]) {
        for item in items.prefix(3) where item.kind == .web {
            guard let fileID = WebFetcher.fileID(of: item), let remote = item.remoteURL else { continue }
            let destination = paths.files.appendingPathComponent(fileID + "-full.gif", isDirectory: false)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            _ = downloadTask(from: remote, to: destination, requestTimeout: 30, priority: .utility)
        }
    }

    /// 24 h TTL, LRU to 50 MB.
    func pruneCache() {
        guard !isPruning else { return }
        isPruning = true
        lastPruneAt = Date()
        let prunePaths = paths
        let protectedNames = Set(fileTasks.keys)
        Task.detached(priority: .utility) { [weak self] in
            let result = WebFetcher.prune(paths: prunePaths, protecting: protectedNames)
            await self?.didPrune(result)
        }
    }

    // MARK: - Fetching

    private var apiKey: String? {
        if let custom = store.settings.giphyAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        let bundledValue = (Bundle.main.object(forInfoDictionaryKey: "GiphyAPIKey") as? String) ?? ""
        let bundled = bundledValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bundled.isEmpty && !bundled.hasPrefix("$(") {
            return bundled
        }
        return nil
    }

    private var canPrefetch: Bool {
        store.settings.webDiscoverEnabled
            && apiKey != nil
            && !SystemConditions.isOnExpensiveNetwork
            && !SystemConditions.shouldDeferBackgroundWork
            && recentSearchCount < WebDiscover.prefetchBudget
    }

    private func freshManifest(for mood: Mood) -> MoodManifest? {
        if !checkedDisk.contains(mood) {
            checkedDisk.insert(mood)
            if manifests[mood] == nil, let loaded = WebFetcher.loadManifest(for: mood, paths: paths) {
                manifests[mood] = loaded
            }
        }
        guard let manifest = manifests[mood] else { return nil }
        let age = Date().timeIntervalSince(manifest.fetchedAt)
        guard age >= -60, age < WebDiscover.freshness else { return nil }
        return manifest
    }

    /// The running fetch for `mood`, or a new one; nil when disabled, keyless, rate-limited or recently failed.
    private func startFetch(for mood: Mood, priority: TaskPriority) -> Task<MoodManifest?, Never>? {
        if let running = fetches[mood] { return running }
        if let failed = failedAt[mood], Date().timeIntervalSince(failed) < WebDiscover.retryDelay { return nil }
        guard store.settings.webDiscoverEnabled,
              let key = apiKey,
              recentSearchCount < WebDiscover.searchesPerHour else {
            return nil
        }
        recordSearch()

        let fetchPaths = paths
        let fetchSession = session
        let provider = GiphyProvider(apiKey: key, session: fetchSession)
        let task = Task.detached(priority: priority) { () async -> MoodManifest? in
            do {
                return try await WebFetcher.fetch(mood: mood, provider: provider, paths: fetchPaths, session: fetchSession)
            } catch {
                webLog.error("GIPHY fetch failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        fetches[mood] = task
        isFetching = true
        Task { [weak self] in
            let manifest = await task.value
            self?.finishFetch(mood: mood, manifest: manifest)
        }
        return task
    }

    private func finishFetch(mood: Mood, manifest: MoodManifest?) {
        fetches[mood] = nil
        if let manifest = manifest {
            manifests[mood] = manifest
            checkedDisk.insert(mood)
            failedAt[mood] = nil
        } else {
            failedAt[mood] = Date()
        }
        isFetching = !fetches.isEmpty
        if Date().timeIntervalSince(lastPruneAt) > WebDiscover.pruneInterval {
            pruneCache()
        }
    }

    private func prefetchFinished(generation: Int) {
        if generation == prefetchGeneration {
            prefetchTask = nil
        }
    }

    /// One shared download per destination file.
    private func downloadTask(from remote: URL, to destination: URL, requestTimeout: TimeInterval, priority: TaskPriority) -> Task<URL?, Never> {
        let key = destination.lastPathComponent
        if let running = fileTasks[key] { return running }
        let downloadSession = session
        let task = Task.detached(priority: priority) { () async -> URL? in
            do {
                try await WebFetcher.download(remote, to: destination, session: downloadSession, timeout: requestTimeout)
                return destination
            } catch {
                webLog.error("GIPHY download failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        fileTasks[key] = task
        Task { [weak self] in
            _ = await task.value
            self?.fileTasks[key] = nil
        }
        return task
    }

    private func didPrune(_ result: PruneResult) {
        isPruning = false
        for name in result.removedMoods {
            // A refetch may have replaced the manifest while pruning ran; keep fresh ones.
            if let mood = Mood(rawValue: name), let manifest = manifests[mood],
               Date().timeIntervalSince(manifest.fetchedAt) >= WebDiscover.freshness {
                manifests[mood] = nil
            }
        }
        guard !result.removedFiles.isEmpty else { return }
        for (mood, manifest) in manifests {
            let kept = manifest.items.filter { !result.removedFiles.contains($0.fileURL.lastPathComponent) }
            if kept.count != manifest.items.count {
                manifests[mood] = MoodManifest(fetchedAt: manifest.fetchedAt, items: kept)
            }
        }
    }

    // MARK: - Rate guard

    private var recentSearchCount: Int {
        pruneSearchTimes()
        return searchTimes.count
    }

    private func pruneSearchTimes() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-3600)
        let future = now.addingTimeInterval(60)
        searchTimes.removeAll { $0 < cutoff || $0 > future }
    }

    private func recordSearch() {
        pruneSearchTimes()
        searchTimes.append(Date())
        let values = searchTimes.map { $0.timeIntervalSince1970 }
        let url = paths.rateURL
        ioQueue.async {
            WebFetcher.saveSearchTimes(values, to: url)
        }
    }
}

// MARK: - Cache model

/// What is cached for one mood: when it was fetched and the analyzed items.
private struct MoodManifest: Codable, Sendable {
    var fetchedAt: Date
    var items: [LibraryItem]
}

/// Only the date of a manifest, for pruning without decoding its items.
private struct ManifestHeader: Decodable {
    let fetchedAt: Date
}

private struct PruneResult: Sendable {
    var removedFiles: Set<String> = []   // file names inside Web/files
    var removedMoods: Set<String> = []   // Mood raw values whose manifest was deleted
}

private struct WebPaths: Sendable {
    let root: URL     // ~/Library/Caches/MemeMe/Web
    let files: URL    // ~/Library/Caches/MemeMe/Web/files

    var rateURL: URL {
        root.appendingPathComponent("rate.json", isDirectory: false)
    }

    func manifestURL(for mood: Mood) -> URL {
        root.appendingPathComponent(mood.rawValue + ".json", isDirectory: false)
    }

    static func make() -> WebPaths {
        let fileManager = FileManager.default
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        let root = caches.appendingPathComponent("MemeMe/Web", isDirectory: true)
        let files = root.appendingPathComponent("files", isDirectory: true)
        try? fileManager.createDirectory(at: files, withIntermediateDirectories: true, attributes: nil)
        return WebPaths(root: root, files: files)
    }
}

// MARK: - Racing a task against a timeout

/// Resumes a continuation with whichever value arrives first.
private final class RaceGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?
    private var settled = false
    private var settledValue: Value?

    func install(_ newContinuation: CheckedContinuation<Value?, Never>) {
        lock.lock()
        if settled {
            let value = settledValue
            settledValue = nil
            lock.unlock()
            newContinuation.resume(returning: value)
            return
        }
        continuation = newContinuation
        lock.unlock()
    }

    func offer(_ value: Value?) {
        lock.lock()
        if settled {
            lock.unlock()
            return
        }
        settled = true
        guard let waiting = continuation else {
            settledValue = value
            lock.unlock()
            return
        }
        continuation = nil
        lock.unlock()
        waiting.resume(returning: value)
    }
}

private enum WebRace {
    /// The task's value, or nil after `timeout` seconds (or when the caller is cancelled).
    /// The task itself keeps running, so its result still lands in the cache.
    static func value<T: Sendable>(of task: Task<T?, Never>, timeout: TimeInterval) async -> T? {
        let gate = RaceGate<T>()
        let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                gate.install(continuation)
                Task.detached {
                    let value = await task.value
                    gate.offer(value)
                }
                Task.detached {
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    gate.offer(nil)
                }
            }
        } onCancel: {
            gate.offer(nil)
        }
    }
}

// MARK: - Off-main work

private enum WebFetchError: Error {
    case badResponse
}

private enum WebFetcher {
    static let freshness: TimeInterval = 24 * 3600
    static let maximumCacheBytes: Int64 = 50 * 1024 * 1024
    static let resultLimit = 25
    static let parallelStills = 4
    static let stillTimeout: TimeInterval = 10

    /// Search, download stills (≤ 4 at once) and analyze them; writes the mood manifest.
    static func fetch(mood: Mood, provider: GiphyProvider, paths: WebPaths, session: URLSession) async throws -> MoodManifest {
        let gifs = try await provider.search(mood.searchQuery, limit: resultLimit)
        let fetchedAt = Date()

        let collected = await withTaskGroup(of: (Int, LibraryItem?).self, returning: [(Int, LibraryItem)].self) { group in
            var results: [(Int, LibraryItem)] = []
            var nextIndex = 0
            while nextIndex < gifs.count && nextIndex < WebFetcher.parallelStills {
                let index = nextIndex
                let gif = gifs[index]
                group.addTask {
                    let item = await WebFetcher.makeItem(gif: gif, mood: mood, paths: paths, session: session, fetchedAt: fetchedAt)
                    return (index, item)
                }
                nextIndex += 1
            }
            while let finished = await group.next() {
                if let item = finished.1 {
                    results.append((finished.0, item))
                }
                if nextIndex < gifs.count {
                    let index = nextIndex
                    let gif = gifs[index]
                    group.addTask {
                        let item = await WebFetcher.makeItem(gif: gif, mood: mood, paths: paths, session: session, fetchedAt: fetchedAt)
                        return (index, item)
                    }
                    nextIndex += 1
                }
            }
            return results
        }

        let items = collected.sorted { $0.0 < $1.0 }.map { $0.1 }
        let manifest = MoodManifest(fetchedAt: fetchedAt, items: items)
        saveManifest(manifest, to: paths.manifestURL(for: mood))
        return manifest
    }

    /// Downloads (or reuses) the still and analyzes it on-device; nil when either fails.
    static func makeItem(gif: WebGIF, mood: Mood, paths: WebPaths, session: URLSession, fetchedAt: Date) async -> LibraryItem? {
        let fileID = safeID(gif.id)
        guard !fileID.isEmpty else { return nil }
        let stillFile = paths.files.appendingPathComponent(fileID + "-still." + stillExtension(of: gif.stillURL), isDirectory: false)

        if FileManager.default.fileExists(atPath: stillFile.path) {
            touch(stillFile)
        } else {
            do {
                try await download(gif.stillURL, to: stillFile, session: session, timeout: stillTimeout)
            } catch {
                return nil
            }
        }

        let analysis: ImageAnalysis
        do {
            analysis = try ImageAnalyzer.analyze(url: stillFile, includeText: false)
        } catch {
            try? FileManager.default.removeItem(at: stillFile)
            return nil
        }

        let contentHash = "giphy:" + gif.id
        var labels = analysis.labels
        if !labels.contains(mood.label) {
            labels.append(mood.label)
        }
        let size = (try? stillFile.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0

        return LibraryItem(
            id: stableID(forHash: contentHash),
            fileURL: stillFile,
            displayName: gif.title,
            kind: .web,
            tier: .meme,
            source: "GIPHY",
            sourceDetail: nil,
            addedAt: fetchedAt,
            fileModifiedAt: nil,
            fileSize: Int64(size),
            contentHash: contentHash,
            isSticker: false,
            isAnimated: true,
            face: analysis.face,
            pose: analysis.pose,
            intensity: analysis.intensity,
            featurePrint: analysis.featurePrint,
            featurePrintRevision: analysis.featurePrintRevision,
            text: "",
            labels: labels,
            personID: nil,
            faceEmbedding: nil,
            remoteURL: gif.fullURL,
            previewURL: gif.previewURL,
            attribution: "via GIPHY"
        )
    }

    static func download(_ remote: URL, to destination: URL, session: URLSession, timeout: TimeInterval) async throws {
        var request = URLRequest(url: remote)
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw WebFetchError.badResponse
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try data.write(to: destination, options: .atomic)
    }

    /// First 16 bytes of SHA-256 of the content hash ("giphy:<id>") → UUID, stable across launches.
    static func stableID(forHash hash: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(hash.utf8)))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// File-name-safe GIPHY id of a web item ("giphy:<id>"), nil for other items.
    static func fileID(of item: LibraryItem) -> String? {
        let prefix = "giphy:"
        guard item.contentHash.hasPrefix(prefix) else { return nil }
        let fileID = safeID(String(item.contentHash.dropFirst(prefix.count)))
        return fileID.isEmpty ? nil : fileID
    }

    /// ASCII letters, digits, "-" and "_" only (at most 64).
    static func safeID(_ raw: String) -> String {
        var result = ""
        for scalar in raw.unicodeScalars where scalar.isASCII {
            let value = scalar.value
            let isDigit = value >= 48 && value <= 57
            let isUpper = value >= 65 && value <= 90
            let isLower = value >= 97 && value <= 122
            if isDigit || isUpper || isLower || value == 45 || value == 95 {
                result.unicodeScalars.append(scalar)
            }
        }
        return String(result.prefix(64))
    }

    static func stillExtension(of url: URL) -> String {
        let pathExtension = url.pathExtension.lowercased()
        return ["gif", "webp", "png", "jpg", "jpeg"].contains(pathExtension) ? pathExtension : "gif"
    }

    /// Marks a cached file as recently used (LRU is by modification date).
    static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    // MARK: Manifests

    static func loadManifest(for mood: Mood, paths: WebPaths) -> MoodManifest? {
        guard let data = try? Data(contentsOf: paths.manifestURL(for: mood)),
              var manifest = try? makeDecoder().decode(MoodManifest.self, from: data) else {
            return nil
        }
        manifest.items = manifest.items.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        return manifest
    }

    static func saveManifest(_ manifest: MoodManifest, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            let data = try makeEncoder().encode(manifest)
            try data.write(to: url, options: .atomic)
        } catch {
            webLog.error("Saving web cache failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func loadSearchTimes(from url: URL) -> [Date] {
        guard let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([Double].self, from: data) else {
            return []
        }
        return values.filter { $0.isFinite }.map { Date(timeIntervalSince1970: $0) }
    }

    static func saveSearchTimes(_ values: [Double], to url: URL) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Pruning

    /// Deletes manifests older than 24 h, files unused for 24 h, then the least recently used files until ≤ 50 MB.
    static func prune(paths: WebPaths, protecting protectedNames: Set<String>) -> PruneResult {
        let fileManager = FileManager.default
        let now = Date()
        var result = PruneResult()

        let decoder = makeDecoder()
        for mood in Mood.allCases {
            let url = paths.manifestURL(for: mood)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            var fetchedAt = Date.distantPast
            if let data = try? Data(contentsOf: url), let header = try? decoder.decode(ManifestHeader.self, from: data) {
                fetchedAt = header.fetchedAt
            }
            let age = now.timeIntervalSince(fetchedAt)
            if age > freshness || age < -60 {
                try? fileManager.removeItem(at: url)
                result.removedMoods.insert(mood.rawValue)
            }
        }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: paths.files,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return result
        }

        var remaining: [(url: URL, name: String, date: Date, size: Int64)] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let name = entry.lastPathComponent
            if protectedNames.contains(name) { continue }
            let date = values?.contentModificationDate ?? Date.distantPast
            let size = Int64(values?.fileSize ?? 0)
            if now.timeIntervalSince(date) > freshness {
                if (try? fileManager.removeItem(at: entry)) != nil {
                    result.removedFiles.insert(name)
                }
                continue
            }
            remaining.append((url: entry, name: name, date: date, size: size))
        }

        var total: Int64 = 0
        for file in remaining { total += file.size }
        if total > maximumCacheBytes {
            for file in remaining.sorted(by: { $0.date < $1.date }) {
                guard total > maximumCacheBytes else { break }
                if (try? fileManager.removeItem(at: file.url)) != nil {
                    total -= file.size
                    result.removedFiles.insert(file.name)
                }
            }
        }
        return result
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return decoder
    }
}
