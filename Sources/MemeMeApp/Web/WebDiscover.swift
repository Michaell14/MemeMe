import Combine
import CryptoKit
import Foundation
import MemeMeCore
import os

private let webLog = Logger(subsystem: "com.mememe.app", category: "web")

/// GIPHY results for one mood, analyzed on-device and cached for 24 h.
///
/// Only the mood word leaves the Mac. Searches are rate-limited (90 per rolling hour, persisted).
/// A search downloads all its stills at once and analyzes them a few at a time off the main actor;
/// `results(for:)` streams each result as soon as it is analyzed, so the grid fills in while the
/// rest are still arriving.
@MainActor final class WebDiscover: ObservableObject {
    /// What Web Discover can do right now, for the menu.
    enum Status: Equatable {
        case off
        case noKey
        /// GIPHY refused the key (401 or 403).
        case keyRejected
        /// MemeMe's own hourly limit, or GIPHY said too many requests (429).
        case limitReached
        case ready
    }

    @Published private(set) var isFetching: Bool = false

    private let store: LibraryStore
    private let paths: WebPaths
    private let session: URLSession
    private let ioQueue = DispatchQueue(label: "com.mememe.web.io", qos: .utility)

    private var manifests: [Mood: MoodManifest] = [:]
    /// Moods whose manifest file has been looked for on disk.
    private var checkedDisk: Set<Mood> = []
    private var fetches: [Mood: Task<MoodManifest?, Never>] = [:]
    /// How urgent each running search is; a live search joining a background one raises it.
    private var urgencies: [Mood: FetchUrgency] = [:]
    /// Results of each running search analyzed so far, by their position in GIPHY's results.
    private var partials: [Mood: [Int: LibraryItem]] = [:]
    /// Who is listening to each running search (`results(for:)`).
    private var listeners: [Mood: [UUID: AsyncStream<[LibraryItem]>.Continuation]] = [:]
    private var failedAt: [Mood: Date] = [:]
    /// After GIPHY says too many requests (429), no searches start until then.
    private var pausedUntil: Date?
    /// The key GIPHY last refused (401, 403) and when: searches with it wait `refusalPause`, and one that
    /// succeeds clears it. A different key searches at once.
    private var rejectedKey: String?
    private var rejectedAt = Date.distantPast
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
    /// How long searches pause after GIPHY refuses one, or a key.
    private static let refusalPause: TimeInterval = 10 * 60
    private static let copyTimeout: TimeInterval = 8
    private static let pruneInterval: TimeInterval = 600

    convenience init(store: LibraryStore) {
        self.init(store: store, cacheRoot: nil)
    }

    /// `cacheRoot`: the cache folder (nil = ~/Library/Caches/MemeMe/Web); tests pass a temp folder.
    /// `configuration`: the network session's configuration (nil = default); tests pass one that serves canned replies.
    init(store: LibraryStore, cacheRoot: URL?, configuration: URLSessionConfiguration? = nil) {
        self.store = store
        paths = WebPaths.make(root: cacheRoot)
        let configuration = configuration ?? .default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        // All of a search's stills download at once (GIPHY's CDN multiplexes them over HTTP/2; this covers HTTP/1.1).
        configuration.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: configuration)
        searchTimes = WebFetcher.loadSearchTimes(from: paths.rateURL)
        pruneSearchTimes()
    }

    /// A key was set from the menu or baked into this build.
    var hasAPIKey: Bool {
        apiKey != nil
    }

    var status: Status {
        guard store.settings.webDiscoverEnabled else { return .off }
        guard let key = apiKey else { return .noKey }
        if isRefused(key) { return .keyRejected }
        if isPaused || recentSearchCount >= WebDiscover.searchesPerHour { return .limitReached }
        return .ready
    }

    /// Instant: analyzed items for the mood if cached and fresh (24 h), else [].
    func cachedItems(for mood: Mood) -> [LibraryItem] {
        guard store.settings.webDiscoverEnabled, let manifest = freshManifest(for: mood) else { return [] }
        return manifest.items
    }

    /// Results of the running search for `mood` analyzed so far, in GIPHY's order; [] when none is running.
    func partialItems(for mood: Mood) -> [LibraryItem] {
        guard store.settings.webDiscoverEnabled, let found = partials[mood] else { return [] }
        return found.keys.sorted().compactMap { found[$0] }
    }

    /// GIPHY results for `mood` as they come in: each element is every result analyzed so far, in GIPHY's
    /// order (a slow reader gets only the newest). Cached results arrive at once. Starts the search if needed
    /// and joins it if it is running. The stream ends when the search does, at once when nothing can be
    /// searched, and stopping early never stops the search, so it still fills the cache.
    func results(for mood: Mood) -> AsyncStream<[LibraryItem]> {
        let (stream, continuation) = AsyncStream<[LibraryItem]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard store.settings.webDiscoverEnabled else {
            continuation.finish()
            return stream
        }
        if let manifest = freshManifest(for: mood) {
            continuation.yield(manifest.items)
            continuation.finish()
            return stream
        }
        guard startFetch(for: mood, priority: .userInitiated) != nil else {
            continuation.finish()
            return stream
        }
        urgencies[mood]?.raise()
        let soFar = partialItems(for: mood)
        if !soFar.isEmpty {
            continuation.yield(soFar)
        }
        let id = UUID()
        listeners[mood, default: [:]][id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.listeners[mood]?[id] = nil
            }
        }
        return stream
    }

    /// Starts the search for `mood` now unless it is cached or running, so its results are in (or arriving)
    /// by the time the face is held.
    func warm(_ mood: Mood) {
        guard store.settings.webDiscoverEnabled, freshManifest(for: mood) == nil else { return }
        if startFetch(for: mood, priority: .userInitiated) != nil {
            urgencies[mood]?.raise()
        }
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
        status == .ready
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
        // A manifest whose stills were all pruned (or that never got any) is stale: fetch it again.
        guard age >= -60, age < WebDiscover.freshness, !manifest.items.isEmpty else { return nil }
        return manifest
    }

    private var isPaused: Bool {
        guard let until = pausedUntil else { return false }
        if Date() < until { return true }
        pausedUntil = nil
        return false
    }

    /// GIPHY refused `key` less than `refusalPause` ago.
    private func isRefused(_ key: String) -> Bool {
        key == rejectedKey && Date().timeIntervalSince(rejectedAt) < WebDiscover.refusalPause
    }

    /// The running fetch for `mood`, or a new one; nil when disabled, keyless, rate-limited, paused or recently failed.
    private func startFetch(for mood: Mood, priority: TaskPriority) -> Task<MoodManifest?, Never>? {
        if let running = fetches[mood] { return running }
        if let failed = failedAt[mood], Date().timeIntervalSince(failed) < WebDiscover.retryDelay { return nil }
        guard store.settings.webDiscoverEnabled,
              let key = apiKey,
              !isPaused,
              !isRefused(key),
              recentSearchCount < WebDiscover.searchesPerHour else {
            return nil
        }
        recordSearch()

        let fetchPaths = paths
        let fetchSession = session
        let provider = GiphyProvider(apiKey: key, session: fetchSession)
        let urgency = FetchUrgency(urgent: priority.rawValue >= TaskPriority.userInitiated.rawValue)
        // One reader on the main actor applies the fetch's events in order: each result, then the outcome.
        let (events, sink) = AsyncStream<FetchEvent>.makeStream()
        let mayRetry: @Sendable () async -> Bool = { [weak self] in
            await self?.recordRetry() ?? false
        }
        let task = Task.detached(priority: priority) { () async -> MoodManifest? in
            let outcome = await WebFetcher.fetch(
                mood: mood,
                provider: provider,
                paths: fetchPaths,
                session: fetchSession,
                urgency: urgency,
                mayRetry: mayRetry
            ) { index, item in
                sink.yield(.analyzed(index, item))
            }
            sink.yield(.finished(outcome))
            sink.finish()
            return outcome.manifest
        }
        fetches[mood] = task
        urgencies[mood] = urgency
        partials[mood] = [:]
        isFetching = true
        Task { [weak self] in
            for await event in events {
                switch event {
                case let .analyzed(index, item):
                    self?.didAnalyze(item, at: index, for: mood)
                case let .finished(outcome):
                    self?.finishFetch(mood: mood, outcome: outcome, key: key)
                }
            }
        }
        return task
    }

    private func didAnalyze(_ item: LibraryItem, at index: Int, for mood: Mood) {
        guard partials[mood] != nil else { return }
        partials[mood]?[index] = item
        guard let waiting = listeners[mood], !waiting.isEmpty else { return }
        let snapshot = partialItems(for: mood)
        for listener in waiting.values {
            listener.yield(snapshot)
        }
    }

    private func finishFetch(mood: Mood, outcome: FetchOutcome, key: String) {
        fetches[mood] = nil
        urgencies[mood] = nil
        partials[mood] = nil
        if let manifest = outcome.manifest {
            manifests[mood] = manifest
            checkedDisk.insert(mood)
            failedAt[mood] = nil
            if rejectedKey == key {
                rejectedKey = nil
            }
        } else {
            failedAt[mood] = Date()
            switch outcome.failure {
            case .refused:
                pausedUntil = Date().addingTimeInterval(WebDiscover.refusalPause)
            case .keyRejected:
                rejectedKey = key
                rejectedAt = Date()
            case .failed, nil:
                break
            }
        }
        let final = store.settings.webDiscoverEnabled ? (outcome.manifest?.items ?? []) : []
        for listener in (listeners.removeValue(forKey: mood) ?? [:]).values {
            if !final.isEmpty {
                listener.yield(final)
            }
            listener.finish()
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
        for (mood, found) in partials where !result.removedFiles.isEmpty {
            partials[mood] = found.filter { !result.removedFiles.contains($0.value.fileURL.lastPathComponent) }
        }
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

    /// Counts a retried search like any other; false (no retry) when Web Discover was turned off, the hour's searches are spent or searching is paused.
    private func recordRetry() -> Bool {
        guard store.settings.webDiscoverEnabled, !isPaused, recentSearchCount < WebDiscover.searchesPerHour else { return false }
        recordSearch()
        return true
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

/// How a search ended. `manifest` is nil when it failed.
private struct FetchOutcome: Sendable {
    var manifest: MoodManifest?
    var failure: FetchFailure?
}

private enum FetchFailure: Sendable {
    /// GIPHY said too many requests (429).
    case refused
    /// GIPHY refused the key (401 or 403).
    case keyRejected
    /// Offline, a server error, or no still could be downloaded and analyzed.
    case failed
}

/// What a running search reports to the main actor, in order.
private enum FetchEvent: Sendable {
    case analyzed(Int, LibraryItem)
    case finished(FetchOutcome)
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

    static func make(root customRoot: URL? = nil) -> WebPaths {
        let fileManager = FileManager.default
        let root: URL
        if let customRoot = customRoot {
            root = customRoot
        } else {
            let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
            root = caches.appendingPathComponent("MemeMe/Web", isDirectory: true)
        }
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

/// Whether a search's stills are analyzed ahead of background ones. A live search that joins a background
/// one (prefetch) raises it, which also moves that search's stills that are still waiting.
private final class FetchUrgency: @unchecked Sendable {
    private let lock = NSLock()
    private var urgent: Bool

    init(urgent: Bool) {
        self.urgent = urgent
    }

    var isUrgent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return urgent
    }

    func raise() {
        lock.lock()
        urgent = true
        lock.unlock()
    }
}

/// Runs blocking work (Vision) on threads of its own, a few at a time, so a search's stills never tie up
/// Swift's shared task threads or take every core from the camera. Each free thread takes the oldest urgent
/// job, else the oldest one, so a live search never waits behind background prefetch.
private final class AnalysisQueue: @unchecked Sendable {
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var pending: [(urgency: FetchUrgency, job: () -> Void)] = []

    init(maxConcurrent: Int) {
        queue.name = "com.mememe.web.analysis"
        queue.maxConcurrentOperationCount = max(1, maxConcurrent)
    }

    func run<Value>(urgency: FetchUrgency, _ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            lock.lock()
            pending.append((urgency: urgency, job: { continuation.resume(returning: work()) }))
            lock.unlock()
            // One operation per job, so every job runs exactly once.
            let operation = BlockOperation { [self] in
                runNext()
            }
            let urgent = urgency.isUrgent
            operation.qualityOfService = urgent ? .userInitiated : .utility
            // Started ahead of queued background operations, so a live search's job runs at its own priority.
            operation.queuePriority = urgent ? .high : .normal
            queue.addOperation(operation)
        }
    }

    private func runNext() {
        lock.lock()
        guard !pending.isEmpty else {
            lock.unlock()
            return
        }
        let index = pending.firstIndex(where: { $0.urgency.isUrgent }) ?? 0
        let next = pending.remove(at: index)
        lock.unlock()
        next.job()
    }
}

private enum WebFetcher {
    static let freshness: TimeInterval = 24 * 3600
    static let maximumCacheBytes: Int64 = 50 * 1024 * 1024
    static let resultLimit = 25
    static let stillTimeout: TimeInterval = 10
    /// A failed search is tried once more after this, unless GIPHY refused it.
    static let searchRetryDelayNanoseconds: UInt64 = 500_000_000
    /// Vision runs a few stills at a time, next to the camera's own analysis.
    static let analysisQueue = AnalysisQueue(maxConcurrent: max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2)))

    /// Searches, downloads every still at once and analyzes them a few at a time, calling `onAnalyzed` with each
    /// result's position as soon as it is ready; then writes the mood manifest. Never throws: failures are in the outcome.
    static func fetch(
        mood: Mood,
        provider: GiphyProvider,
        paths: WebPaths,
        session: URLSession,
        urgency: FetchUrgency,
        mayRetry: @escaping @Sendable () async -> Bool,
        onAnalyzed: @escaping @Sendable (Int, LibraryItem) -> Void
    ) async -> FetchOutcome {
        let gifs: [WebGIF]
        do {
            gifs = try await search(mood, provider: provider, mayRetry: mayRetry)
        } catch {
            webLog.error("GIPHY search failed: \(error.localizedDescription, privacy: .public)")
            return FetchOutcome(manifest: nil, failure: failure(for: error))
        }
        let fetchedAt = Date()

        let collected = await withTaskGroup(of: (Int, LibraryItem?).self, returning: [(Int, LibraryItem)].self) { group in
            for (index, gif) in gifs.enumerated() {
                group.addTask {
                    let item = await WebFetcher.makeItem(gif: gif, mood: mood, paths: paths, session: session, fetchedAt: fetchedAt, urgency: urgency)
                    return (index, item)
                }
            }
            var results: [(Int, LibraryItem)] = []
            while let finished = await group.next() {
                guard let item = finished.1 else { continue }
                results.append((finished.0, item))
                onAnalyzed(finished.0, item)
            }
            return results
        }

        let items = collected.sorted { $0.0 < $1.0 }.map { $0.1 }
        // No still could be downloaded or analyzed: fail (60 s retry) instead of caching nothing for 24 h.
        guard !items.isEmpty else { return FetchOutcome(manifest: nil, failure: .failed) }
        let manifest = MoodManifest(fetchedAt: fetchedAt, items: items)
        saveManifest(manifest, to: paths.manifestURL(for: mood))
        return FetchOutcome(manifest: manifest, failure: nil)
    }

    /// The search, tried once more after a dropped connection, a timeout or a server error, if `mayRetry`
    /// (which counts the retry against the hourly limit) allows it.
    static func search(_ mood: Mood, provider: GiphyProvider, mayRetry: @Sendable () async -> Bool) async throws -> [WebGIF] {
        do {
            return try await provider.search(mood.searchQuery, limit: resultLimit)
        } catch let error where isWorthRetrying(error) {
            try? await Task.sleep(nanoseconds: searchRetryDelayNanoseconds)
            guard await mayRetry() else { throw error }
            return try await provider.search(mood.searchQuery, limit: resultLimit)
        }
    }

    static func isWorthRetrying(_ error: Error) -> Bool {
        if let status = GiphyError.status(of: error) {
            return status >= 500
        }
        guard let urlError = error as? URLError else { return false }
        let transient: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed]
        return transient.contains(urlError.code)
    }

    static func failure(for error: Error) -> FetchFailure {
        switch GiphyError.status(of: error) {
        case 429?: return .refused
        case 401?, 403?: return .keyRejected
        default: return .failed
        }
    }

    /// Downloads (or reuses) the still and analyzes it on-device; nil when either fails.
    static func makeItem(gif: WebGIF, mood: Mood, paths: WebPaths, session: URLSession, fetchedAt: Date, urgency: FetchUrgency) async -> LibraryItem? {
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

        return await analysisQueue.run(urgency: urgency) {
            WebFetcher.analyzedItem(gif: gif, mood: mood, stillFile: stillFile, fetchedAt: fetchedAt)
        }
    }

    /// Runs Vision on a downloaded still (blocking, so only on `analysisQueue`); nil when it can't be read.
    private static func analyzedItem(gif: WebGIF, mood: Mood, stillFile: URL, fetchedAt: Date) -> LibraryItem? {
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
            // Full and preview GIFs are downloaded again on demand; stills back fresh manifests, so they go last.
            let ordered = remaining.sorted { first, second in
                let firstIsStill = first.name.contains("-still.")
                let secondIsStill = second.name.contains("-still.")
                if firstIsStill != secondIsStill { return secondIsStill }
                return first.date < second.date
            }
            for file in ordered {
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
