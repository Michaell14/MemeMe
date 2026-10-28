import AppKit
import Combine
import Foundation
import MemeMeCore
import os

private let webLog = Logger(subsystem: "com.mememe.app", category: "web")

/// What the GIPHY row asks GIPHY for: the mood of your face, or the words you typed.
enum WebQuery: Hashable, Sendable {
    case mood(Mood)
    /// Lowercased, trimmed, single-spaced, at most `maximumLength` characters (`words(from:)`).
    case words(String)

    static let maximumLength = 50

    /// The typed search terms as GIPHY gets them; nil when they hold fewer than three letters or digits (each
    /// search counts against GIPHY's hourly limit, and two letters find nothing useful).
    static func words(from terms: [String]) -> WebQuery? {
        let joined = terms
            .flatMap { $0.lowercased().split(whereSeparator: { $0.isWhitespace }) }
            .joined(separator: " ")
        let text = String(joined.prefix(maximumLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.unicodeScalars.filter({ CharacterSet.alphanumerics.contains($0) }).count >= 3 else { return nil }
        return .words(text)
    }

    /// What is sent to GIPHY.
    var searchTerms: String {
        switch self {
        case let .mood(mood): return mood.searchQuery
        case let .words(text): return text
        }
    }

    /// The GIPHY row's label: the mood word, or the typed words.
    var label: String {
        switch self {
        case let .mood(mood): return mood.label
        case let .words(text): return text
        }
    }
}

/// GIPHY's results for the mood of the user's face, or for the words typed in the search field, for the GIPHY row.
///
/// Only the mood word, or the typed words (without filter words or the names of your people), leave the Mac.
/// Results are shown the way GIPHY returns them: never re-ranked, filtered or mixed with the user's memes, and
/// never stored on disk. A query's results are reused for 10 minutes in memory, images load from GIPHY's URLs
/// through ordinary HTTP caching, and full GIFs go to short-lived files only so they can be copied or dragged into
/// a chat. A search starts as soon as the mood is clear (`warm`). Searches are rate-limited (90 per rolling hour,
/// persisted).
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
    /// GIPHY's API, never cached.
    private let apiSession: URLSession
    /// GIPHY's media, with ordinary HTTP caching (as GIPHY's own apps do).
    private let mediaSession: URLSession
    private let ioQueue = DispatchQueue(label: "com.mememe.web.io", qos: .utility)

    /// Each query's latest results, in memory only.
    private var results: [WebQuery: SearchResult] = [:]
    private var fetches: [WebQuery: Task<[WebGIF]?, Never>] = [:]
    private var failedAt: [WebQuery: Date] = [:]
    /// After GIPHY says too many requests (429), no searches start until then.
    private var pausedUntil: Date?
    /// The key GIPHY last refused (401, 403) and when: searches with it wait `refusalPause`, and one that
    /// succeeds clears it. A different key searches at once.
    private var rejectedKey: String?
    private var rejectedAt = Date.distantPast
    /// Tile images, decoded, while the app runs.
    private let stills = NSCache<NSString, NSImage>()
    private var stillTasks: [URL: Task<Data?, Never>] = [:]
    /// Full GIFs being downloaded, keyed by URL, so a prefetch and a copy share one download.
    private var fullTasks: [URL: Task<Data?, Never>] = [:]
    /// Copy files being written, keyed by file name.
    private var fileTasks: [String: Task<URL?, Never>] = [:]
    /// Network searches in the last hour (persisted).
    private var searchTimes: [Date] = []
    private var isPruning = false
    private var lastPruneAt = Date.distantPast

    /// How long a query's results are reused before searching again.
    static let resultLifetime: TimeInterval = 10 * 60
    private static let searchesPerHour = 90
    private static let retryDelay: TimeInterval = 60
    /// How long searches pause after GIPHY refuses one, or a key.
    private static let refusalPause: TimeInterval = 10 * 60
    private static let copyTimeout: TimeInterval = 8
    private static let pruneInterval: TimeInterval = 600

    convenience init(store: LibraryStore) {
        self.init(store: store, cacheRoot: nil)
    }

    /// `cacheRoot`: the cache folder (nil = ~/Library/Caches/MemeMe/Web); tests pass a temp folder.
    /// `configuration`: the network sessions' base configuration (nil = default); tests pass one that serves canned replies.
    init(store: LibraryStore, cacheRoot: URL?, configuration: URLSessionConfiguration? = nil) {
        self.store = store
        paths = WebPaths.make(root: cacheRoot)
        let base = configuration ?? .default

        let api = (base.copy() as? URLSessionConfiguration) ?? .default
        api.urlCache = nil
        api.requestCachePolicy = .reloadIgnoringLocalCacheData
        api.timeoutIntervalForRequest = 15
        api.timeoutIntervalForResource = 60
        apiSession = URLSession(configuration: api)

        let media = (base.copy() as? URLSessionConfiguration) ?? .default
        media.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 64 * 1024 * 1024, directory: paths.httpCache)
        media.requestCachePolicy = .useProtocolCachePolicy
        media.timeoutIntervalForRequest = 15
        media.timeoutIntervalForResource = 60
        // A row's stills load at once (GIPHY's CDN multiplexes them over HTTP/2; this covers HTTP/1.1).
        media.httpMaximumConnectionsPerHost = 8
        mediaSession = URLSession(configuration: media)

        stills.countLimit = 200
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

    /// GIPHY's results for `query` from the last 10 minutes, in GIPHY's order; nil when there are none.
    func cachedGIFs(for query: WebQuery) -> [WebGIF]? {
        guard store.settings.webDiscoverEnabled, let result = results[query] else { return nil }
        let age = Date().timeIntervalSince(result.fetchedAt)
        guard age >= -60, age < WebDiscover.resultLifetime else {
            results[query] = nil
            return nil
        }
        return result.gifs
    }

    func cachedGIFs(for mood: Mood) -> [WebGIF]? {
        cachedGIFs(for: .mood(mood))
    }

    /// GIPHY's results for `query`, in GIPHY's order: from the last 10 minutes at once, else from the running
    /// search or a new one. nil when nothing can be searched or the search failed. The search keeps going
    /// if the caller stops waiting, so its results are there next time.
    func gifs(for query: WebQuery) async -> [WebGIF]? {
        if let cached = cachedGIFs(for: query) {
            return cached
        }
        guard store.settings.webDiscoverEnabled, let task = startFetch(for: query) else { return nil }
        let found = await task.value
        return store.settings.webDiscoverEnabled ? found : nil
    }

    func gifs(for mood: Mood) async -> [WebGIF]? {
        await gifs(for: .mood(mood))
    }

    /// Whether a search for `query` is running.
    func isSearching(_ query: WebQuery) -> Bool {
        fetches[query] != nil
    }

    func isSearching(_ mood: Mood) -> Bool {
        isSearching(.mood(mood))
    }

    /// Starts the search for `query` now unless its results are fresh or it is running, so they are in
    /// (or arriving) by the time the face is held.
    func warm(_ query: WebQuery) {
        guard store.settings.webDiscoverEnabled, cachedGIFs(for: query) == nil else { return }
        _ = startFetch(for: query)
    }

    func warm(_ mood: Mood) {
        warm(.mood(mood))
    }

    // MARK: - Media

    /// A tile's image if it is already loaded.
    func cachedStill(for gif: WebGIF) -> NSImage? {
        stills.object(forKey: gif.stillURL.absoluteString as NSString)
    }

    /// A tile's image: GIPHY's small still, through the HTTP cache.
    func still(for gif: WebGIF) async -> NSImage? {
        if let image = cachedStill(for: gif) {
            return image
        }
        let url = gif.stillURL
        let task: Task<Data?, Never>
        if let running = stillTasks[url] {
            task = running
        } else {
            let session = mediaSession
            task = Task.detached(priority: .userInitiated) {
                try? await WebFetcher.data(from: url, session: session, timeout: 10)
            }
            stillTasks[url] = task
        }
        let data = await task.value
        stillTasks[url] = nil
        if let image = cachedStill(for: gif) {
            return image
        }
        guard let data, let image = NSImage(data: data) else { return nil }
        stills.setObject(image, forKey: url.absoluteString as NSString)
        return image
    }

    /// The small animated GIF a focused tile plays, through the HTTP cache; nil when GIPHY has none.
    func preview(for gif: WebGIF) async -> NSImage? {
        guard let url = gif.previewURL else { return nil }
        let session = mediaSession
        let data = await Task.detached(priority: .userInitiated) {
            try? await WebFetcher.data(from: url, session: session, timeout: 20)
        }.value
        return data.flatMap { NSImage(data: $0) }
    }

    /// The full GIF as a local file to copy or drag (gone within the hour). nil after 8 s or on failure;
    /// the download keeps going, so trying again is quick.
    func prepareForCopy(_ gif: WebGIF) async -> URL? {
        let destination = copyFile(for: gif)
        if FileManager.default.fileExists(atPath: destination.path) {
            WebFetcher.touch(destination)
            return destination
        }
        let task = downloadTask(from: gif.fullURL, to: destination, requestTimeout: 30, priority: .userInitiated)
        return await WebRace.value(of: task, timeout: WebDiscover.copyTimeout)
    }

    /// Starts downloading the full GIFs of the first three so copying them is instant. Nothing is written to disk
    /// (beyond the HTTP cache) until one is actually copied or dragged.
    func prefetchForCopy(_ gifs: [WebGIF]) {
        for gif in gifs.prefix(3) where !FileManager.default.fileExists(atPath: copyFile(for: gif).path) {
            _ = fullData(from: gif.fullURL, requestTimeout: 30, priority: .utility)
        }
    }

    /// Deletes copy files older than an hour and anything left by versions that cached GIPHY results on disk.
    func pruneCache() {
        guard !isPruning else { return }
        isPruning = true
        lastPruneAt = Date()
        let prunePaths = paths
        let protectedNames = Set(fileTasks.keys)
        Task.detached(priority: .utility) { [weak self] in
            WebFetcher.prune(paths: prunePaths, protecting: protectedNames)
            await self?.didPrune()
        }
    }

    // MARK: - Searching

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

    /// The running search for `query`, or a new one; nil when disabled, keyless, rate-limited, paused or recently failed.
    private func startFetch(for query: WebQuery) -> Task<[WebGIF]?, Never>? {
        if let running = fetches[query] { return running }
        if let failed = failedAt[query], Date().timeIntervalSince(failed) < WebDiscover.retryDelay { return nil }
        guard store.settings.webDiscoverEnabled,
              let key = apiKey,
              !isPaused,
              !isRefused(key),
              recentSearchCount < WebDiscover.searchesPerHour else {
            return nil
        }
        recordSearch()

        let provider = GiphyProvider(apiKey: key, session: apiSession)
        let mayRetry: @Sendable () async -> Bool = { [weak self] in
            await self?.recordRetry() ?? false
        }
        let terms = query.searchTerms
        let task = Task { [weak self] () async -> [WebGIF]? in
            let outcome = await Task.detached(priority: .userInitiated) {
                await WebFetcher.search(terms, provider: provider, mayRetry: mayRetry)
            }.value
            self?.finishFetch(query: query, outcome: outcome, key: key)
            return outcome.gifs
        }
        fetches[query] = task
        isFetching = true
        return task
    }

    private func finishFetch(query: WebQuery, outcome: SearchOutcome, key: String) {
        fetches[query] = nil
        if let gifs = outcome.gifs {
            results[query] = SearchResult(fetchedAt: Date(), gifs: gifs)
            failedAt[query] = nil
            if rejectedKey == key {
                rejectedKey = nil
            }
        } else {
            failedAt[query] = Date()
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
        isFetching = !fetches.isEmpty
        if Date().timeIntervalSince(lastPruneAt) > WebDiscover.pruneInterval {
            pruneCache()
        }
    }

    private func copyFile(for gif: WebGIF) -> URL {
        let name = WebFetcher.safeID(gif.id)
        return paths.files.appendingPathComponent((name.isEmpty ? "gif" : name) + "-full.gif", isDirectory: false)
    }

    /// One shared download of a full GIF per URL, through the media session (so its HTTP cache keeps it).
    private func fullData(from remote: URL, requestTimeout: TimeInterval, priority: TaskPriority) -> Task<Data?, Never> {
        if let running = fullTasks[remote] { return running }
        let session = mediaSession
        let task = Task.detached(priority: priority) { () async -> Data? in
            do {
                return try await WebFetcher.data(from: remote, session: session, timeout: requestTimeout)
            } catch {
                webLog.error("GIPHY download failed: \(error.localizedDescription, privacy: .public)")
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

    /// One shared copy file per destination, written from the full GIF's download.
    private func downloadTask(from remote: URL, to destination: URL, requestTimeout: TimeInterval, priority: TaskPriority) -> Task<URL?, Never> {
        let key = destination.lastPathComponent
        if let running = fileTasks[key] { return running }
        let download = fullData(from: remote, requestTimeout: requestTimeout, priority: priority)
        let task = Task.detached(priority: priority) { () async -> URL? in
            guard let data = await download.value else { return nil }
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                try data.write(to: destination, options: .atomic)
                return destination
            } catch {
                webLog.error("Saving a GIPHY GIF to copy failed: \(error.localizedDescription, privacy: .public)")
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

    private func didPrune() {
        isPruning = false
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

    /// Counts a retried search like any other; false (no retry) when Web Discover was turned off, the hour's
    /// searches are spent or searching is paused.
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

// MARK: - Model

/// One query's results and when GIPHY gave them.
private struct SearchResult {
    let fetchedAt: Date
    let gifs: [WebGIF]
}

/// How a search ended. `gifs` is nil when it failed.
private struct SearchOutcome: Sendable {
    var gifs: [WebGIF]?
    var failure: FetchFailure?
}

private enum FetchFailure: Sendable {
    /// GIPHY said too many requests (429).
    case refused
    /// GIPHY refused the key (401 or 403).
    case keyRejected
    /// Offline, a server error, or an unreadable answer.
    case failed
}

private struct WebPaths: Sendable {
    let root: URL       // ~/Library/Caches/MemeMe/Web
    let files: URL      // …/Web/files: full GIFs being copied or dragged, deleted within the hour
    let httpCache: URL  // …/Web/HTTP: the media session's URLCache

    var rateURL: URL {
        root.appendingPathComponent("rate.json", isDirectory: false)
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
        return WebPaths(root: root, files: files, httpCache: root.appendingPathComponent("HTTP", isDirectory: true))
    }
}

// MARK: - Racing a task against a timeout

/// Resumes a continuation with whichever value arrives first.
final class RaceGate<Value>: @unchecked Sendable {
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

enum WebRace {
    /// The task's value, or nil after `timeout` seconds (or when the caller is cancelled).
    /// The task itself keeps running.
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
    /// Results asked of GIPHY; the row shows the first of them.
    static let resultLimit = 10
    /// A failed search is tried once more after this, unless GIPHY refused it.
    static let searchRetryDelayNanoseconds: UInt64 = 500_000_000
    /// Files for copying and dragging are deleted after this.
    static let fileLifetime: TimeInterval = 3600

    static func search(_ terms: String, provider: GiphyProvider, mayRetry: @Sendable () async -> Bool) async -> SearchOutcome {
        do {
            let gifs = try await attempt(terms, provider: provider, mayRetry: mayRetry)
            return SearchOutcome(gifs: Array(gifs.prefix(resultLimit)), failure: nil)
        } catch {
            webLog.error("GIPHY search failed: \(error.localizedDescription, privacy: .public)")
            return SearchOutcome(gifs: nil, failure: failure(for: error))
        }
    }

    /// The search, tried once more after a dropped connection, a timeout or a server error, if `mayRetry`
    /// (which counts the retry against the hourly limit) allows it.
    static func attempt(_ terms: String, provider: GiphyProvider, mayRetry: @Sendable () async -> Bool) async throws -> [WebGIF] {
        do {
            return try await provider.search(terms, limit: resultLimit)
        } catch let error where isWorthRetrying(error) {
            try? await Task.sleep(nanoseconds: searchRetryDelayNanoseconds)
            guard await mayRetry() else { throw error }
            return try await provider.search(terms, limit: resultLimit)
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

    static func data(from remote: URL, session: URLSession, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: remote)
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw WebFetchError.badResponse
        }
        return data
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

    /// Marks a file as recently used (pruning is by modification date).
    static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
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

    /// Deletes copy files unused for an hour (except `protectedNames`, still downloading) and the per-mood
    /// result files earlier versions kept.
    static func prune(paths: WebPaths, protecting protectedNames: Set<String>) {
        let fileManager = FileManager.default
        let now = Date()
        if let entries = try? fileManager.contentsOfDirectory(at: paths.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for entry in entries where entry.pathExtension == "json" && entry.lastPathComponent != paths.rateURL.lastPathComponent {
                try? fileManager.removeItem(at: entry)
            }
        }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let entries = try? fileManager.contentsOfDirectory(at: paths.files, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return
        }
        for entry in entries where !protectedNames.contains(entry.lastPathComponent) {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let date = values?.contentModificationDate ?? Date.distantPast
            if now.timeIntervalSince(date) > fileLifetime {
                try? fileManager.removeItem(at: entry)
            }
        }
    }
}
