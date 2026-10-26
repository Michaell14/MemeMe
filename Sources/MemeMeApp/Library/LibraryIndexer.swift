import Combine
import Foundation
import ImageIO
import MemeMeCore
import os
import UniformTypeIdentifiers

private let indexLog = Logger(subsystem: "com.mememe.app", category: "library")

struct IndexBatch: Identifiable, Equatable {
    let id: UUID
    var addedIDs: [UUID]
    var skipped: Int
    var duplicates: Int
    var sources: [String]
}

/// Keeps the index in sync with the watched folders and takes in hand-ins ("Keep it", menu-bar drops).
///
/// Folder scans are incremental (path + modification date + size), newest files first, top level only.
/// Analysis runs off the main actor at utility priority, at most 2 images at once, and waits while the
/// Mac is in Low Power Mode or hot. User files are only indexed, never copied (hand-ins are copied to Kept).
@MainActor final class LibraryIndexer: ObservableObject {
    @Published private(set) var isIndexing: Bool = false
    @Published private(set) var progressCount: Int = 0          // memes added in the running scan
    @Published private(set) var pendingSummary: IndexBatch? = nil   // set when a folder scan finishes; AppModel clears it after showing
    var onLibraryChanged: (() -> Void)?

    private let store: LibraryStore
    private var watchers: [String: FolderWatcher] = [:]
    private var scanQueue: [ScanRequest] = []
    private var scanTask: Task<Void, Never>?
    /// Bumped whenever the running scan loop is replaced or cancelled; a loop only touches state while current.
    private var scanGeneration = 0
    /// The summary being built for folders the user just added.
    private var activeBatch: IndexBatch?
    private var activeBatchFolders: Set<String> = []
    /// Folders behind each summary batch, so Undo can stop collecting from them.
    private var batchFolders: [UUID: [String]] = [:]
    /// Unreadable or duplicate files, by path, so unchanged ones are not re-read on every scan.
    private var ignoredFiles: [String: FileStamp] = [:]
    private var resumeTask: Task<Void, Never>?
    private var lastSave = Date.distantPast
    private var lastNotify = Date.distantPast
    private var hasUnsavedChanges = false
    private var hasUnnotifiedChanges = false

    private static let maximumFileSize: Int64 = 25 * 1024 * 1024
    private static let maximumConcurrentAnalyses = 2
    private static let saveInterval: TimeInterval = 5
    private static let notifyInterval: TimeInterval = 1
    private static let deferredRetryNanoseconds: UInt64 = 10_000_000_000
    /// Scans with at least this many new files report progress (isIndexing) even when the user didn't ask.
    private static let busyThreshold = 10

    init(store: LibraryStore) {
        self.store = store
    }

    // MARK: - Folders

    /// Downloads, Desktop, screenshot location (if different); standardized, deduped.
    func defaultFolders() -> [URL] {
        var paths: [String] = []
        for path in [LibraryPaths.downloads(), LibraryPaths.desktop(), LibraryPaths.screenshots()] where !paths.contains(path) {
            paths.append(path)
        }
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Watchers for store.settings.watchedFolders + incremental scan.
    func startWatching() {
        if let until = store.settings.collectingPausedUntil, until <= Date() {
            var settings = store.settings
            settings.collectingPausedUntil = nil
            store.settings = settings
        }
        for path in store.settings.watchedFolders {
            watch(path)
            enqueue(path, batchID: nil)
        }
        schedulePauseExpiry()
        startScanIfNeeded()
    }

    func stopWatching() {
        for watcher in watchers.values {
            watcher.cancel()
        }
        watchers.removeAll()
        resumeTask?.cancel()
        resumeTask = nil
        cancelScan()
        scanQueue.removeAll()
        activeBatch = nil
        activeBatchFolders.removeAll()
        flushChanges()
    }

    /// Persist, watch, scan newest first. The scan's summary lands in `pendingSummary`.
    func addWatchedFolders(_ urls: [URL]) {
        var paths: [String] = []
        for url in urls {
            let path = LibraryPaths.standardized(url)
            if !paths.contains(path) {
                paths.append(path)
            }
        }
        guard !paths.isEmpty else { return }

        var settings = store.settings
        for path in paths where !settings.watchedFolders.contains(path) {
            settings.watchedFolders.append(path)
        }
        // Adding folders is an explicit request to collect.
        settings.collectingPausedUntil = nil
        store.settings = settings
        resumeTask?.cancel()
        resumeTask = nil
        saveNow()

        var batch = activeBatch ?? IndexBatch(id: UUID(), addedIDs: [], skipped: 0, duplicates: 0, sources: [])
        var folders = batchFolders[batch.id] ?? []
        for path in paths {
            let name = sourceName(forFolder: path)
            if !batch.sources.contains(name) {
                batch.sources.append(name)
            }
            if !folders.contains(path) {
                folders.append(path)
            }
            activeBatchFolders.insert(path)
        }
        batchFolders[batch.id] = folders
        activeBatch = batch

        for path in paths.reversed() {
            watch(path)
            enqueue(path, batchID: batch.id, atFront: true)
        }
        startScanIfNeeded()
    }

    /// Stops collecting from the folder and drops its files from the index (the files themselves are untouched).
    func removeWatchedFolder(_ url: URL) {
        let path = LibraryPaths.standardized(url)
        var settings = store.settings
        settings.watchedFolders.removeAll { $0 == path }
        store.settings = settings
        unwatch(path)
        removeItems(inFolder: path)
        if activeBatchFolders.contains(path) {
            activeBatchFolders.remove(path)
            if activeBatchFolders.isEmpty {
                finishActiveBatch()
            }
        }
        hasUnsavedChanges = true
        flushChanges()
    }

    func isWatching(_ url: URL) -> Bool {
        store.settings.watchedFolders.contains(LibraryPaths.standardized(url))
    }

    // MARK: - Hand-ins

    /// Hand-ins (menu-bar drop / Keep it): copies files into store.keptDirectory (http(s) URLs are downloaded first),
    /// analyzes, adds as .mine with source "Kept".
    func keep(urls: [URL], source: String) async -> IndexBatch {
        var batch = IndexBatch(id: UUID(), addedIDs: [], skipped: 0, duplicates: 0, sources: [source])
        guard !urls.isEmpty else { return batch }

        let keptDirectory = store.keptDirectory
        let knownHashes = Set(store.items.map { $0.contentHash })
        let inputs = urls
        let limit = LibraryIndexer.maximumConcurrentAnalyses

        let outcomes = await withTaskGroup(of: KeepOutcome.self, returning: [KeepOutcome].self) { group in
            var results: [KeepOutcome] = []
            var nextIndex = 0
            var running = 0
            while nextIndex < inputs.count || running > 0 {
                while running < limit && nextIndex < inputs.count {
                    let url = inputs[nextIndex]
                    nextIndex += 1
                    running += 1
                    group.addTask(priority: .userInitiated) {
                        await KeepWork.prepare(url, keptDirectory: keptDirectory, source: source, knownHashes: knownHashes)
                    }
                }
                guard let outcome = await group.next() else { break }
                running -= 1
                results.append(outcome)
            }
            return results
        }

        for outcome in outcomes {
            switch outcome {
            case .item(let item):
                if store.add(item) {
                    batch.addedIDs.append(item.id)
                } else {
                    // Same bytes arrived twice in this drop (or meanwhile): drop the extra copy.
                    try? FileManager.default.removeItem(at: item.fileURL)
                    batch.duplicates += 1
                }
            case .duplicate:
                batch.duplicates += 1
            case .failed:
                batch.skipped += 1
            }
        }

        if !batch.addedIDs.isEmpty {
            markChanged()
            flushChanges()
        }
        return batch
    }

    /// Removes the batch's items. For a folder scan it also stops collecting from those folders,
    /// so the next scan doesn't bring the files back.
    func undo(_ batch: IndexBatch) {
        if let folders = batchFolders.removeValue(forKey: batch.id) {
            var settings = store.settings
            settings.watchedFolders.removeAll { folders.contains($0) }
            store.settings = settings
            for path in folders {
                unwatch(path)
                removeItems(inFolder: path)
            }
            if activeBatch?.id == batch.id {
                activeBatch = nil
                activeBatchFolders.removeAll()
            }
        }
        let ids = Set(batch.addedIDs)
        if !ids.isEmpty {
            store.remove(ids: ids)
        }
        if pendingSummary?.id == batch.id {
            pendingSummary = nil
        }
        markChanged()
        flushChanges()
    }

    // MARK: - Pausing

    func pauseCollecting(for interval: TimeInterval) {
        var settings = store.settings
        settings.collectingPausedUntil = Date().addingTimeInterval(max(0, interval))
        store.settings = settings
        saveNow()
        // A running scan notices the pause before its next file; its folder stays queued.
        schedulePauseExpiry()
    }

    func resumeCollecting() {
        resumeTask?.cancel()
        resumeTask = nil
        if store.settings.collectingPausedUntil != nil {
            var settings = store.settings
            settings.collectingPausedUntil = nil
            store.settings = settings
            saveNow()
        }
        for path in store.settings.watchedFolders {
            watch(path)
            enqueue(path, batchID: nil)
        }
        startScanIfNeeded()
    }

    func clearPendingSummary() {
        pendingSummary = nil
    }

    private var isCollectingPaused: Bool {
        guard let until = store.settings.collectingPausedUntil else { return false }
        return until > Date()
    }

    private func schedulePauseExpiry() {
        resumeTask?.cancel()
        resumeTask = nil
        guard let until = store.settings.collectingPausedUntil else { return }
        let delay = until.timeIntervalSinceNow
        guard delay > 0, delay.isFinite else {
            resumeCollecting()
            return
        }
        let nanoseconds = UInt64(min(delay, 7 * 24 * 3600) * 1_000_000_000) + 500_000_000
        resumeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.pauseMayHaveExpired()
        }
    }

    private func pauseMayHaveExpired() {
        resumeTask = nil
        guard let until = store.settings.collectingPausedUntil else { return }
        if until > Date() {
            schedulePauseExpiry()
        } else {
            resumeCollecting()
        }
    }

    // MARK: - Watching

    private func watch(_ path: String) {
        guard watchers[path] == nil else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        // FolderWatcher delivers on the main queue.
        let watcher = FolderWatcher(url: url) { [weak self] in
            MainActor.assumeIsolated {
                guard let indexer = self else { return }
                indexer.folderDidChange(path)
            }
        }
        if let watcher = watcher {
            watchers[path] = watcher
        } else {
            indexLog.info("A watched folder could not be opened")
        }
    }

    private func unwatch(_ path: String) {
        watchers[path]?.cancel()
        watchers[path] = nil
        scanQueue.removeAll { $0.folderPath == path }
    }

    private func folderDidChange(_ path: String) {
        guard store.settings.watchedFolders.contains(path) else { return }
        enqueue(path, batchID: nil)
        startScanIfNeeded()
    }

    // MARK: - Scan loop

    private func enqueue(_ path: String, batchID: UUID?, atFront: Bool = false) {
        if let index = scanQueue.firstIndex(where: { $0.folderPath == path }) {
            if let batchID = batchID {
                scanQueue[index].batchID = batchID
            }
            if atFront && index != 0 {
                let request = scanQueue.remove(at: index)
                scanQueue.insert(request, at: 0)
            }
            return
        }
        let request = ScanRequest(folderPath: path, batchID: batchID)
        if atFront {
            scanQueue.insert(request, at: 0)
        } else {
            scanQueue.append(request)
        }
    }

    private func startScanIfNeeded() {
        guard scanTask == nil, !scanQueue.isEmpty, !isCollectingPaused else { return }
        scanGeneration += 1
        let generation = scanGeneration
        progressCount = 0
        scanTask = Task(priority: .utility) { [weak self] in
            await self?.runScans(generation: generation)
        }
    }

    private func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanGeneration += 1
        isIndexing = false
    }

    private func runScans(generation: Int) async {
        while generation == scanGeneration, !Task.isCancelled, !isCollectingPaused, !scanQueue.isEmpty {
            let request = scanQueue.removeFirst()
            let finished = await scan(request, generation: generation)
            guard generation == scanGeneration else { return }
            if finished {
                folderFinished(request)
            } else {
                // Paused or cancelled: scan this folder again later.
                if !scanQueue.contains(where: { $0.folderPath == request.folderPath }) {
                    scanQueue.insert(request, at: 0)
                }
                break
            }
        }
        guard generation == scanGeneration else { return }
        scanTask = nil
        isIndexing = false
        flushChanges()
        if !Task.isCancelled {
            // Folders that changed while the last one was finishing.
            startScanIfNeeded()
        }
    }

    private func folderFinished(_ request: ScanRequest) {
        guard let batchID = request.batchID, activeBatch?.id == batchID else { return }
        activeBatchFolders.remove(request.folderPath)
        if activeBatchFolders.isEmpty {
            finishActiveBatch()
        }
    }

    private func finishActiveBatch() {
        if let batch = activeBatch {
            pendingSummary = batch
        }
        activeBatch = nil
        activeBatchFolders.removeAll()
    }

    /// Scans one folder. false when it stopped early (paused or cancelled).
    private func scan(_ request: ScanRequest, generation: Int) async -> Bool {
        let folderPath = request.folderPath
        guard store.settings.watchedFolders.contains(folderPath) else { return true }

        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        let listing = await Task.detached(priority: .utility) {
            IndexWork.listFolder(folderURL)
        }.value
        guard generation == scanGeneration, !Task.isCancelled else { return false }
        guard store.settings.watchedFolders.contains(folderPath) else { return true }
        guard let files = listing else { return true }   // missing or unreadable folder

        removeVanishedItems(inFolder: folderPath, present: Set(files.map { $0.path }))

        let countsForBatch = request.batchID != nil && request.batchID == activeBatch?.id
        var pending: [FileCandidate] = []
        var skipped = 0
        for file in files {
            guard file.isImage, file.size <= LibraryIndexer.maximumFileSize else {
                skipped += 1
                continue
            }
            if let existing = store.item(atPath: file.path), LibraryIndexer.hasSameStamp(existing, file) {
                continue
            }
            if let ignored = ignoredFiles[file.path], ignored == file.stamp {
                continue
            }
            pending.append(file)
        }
        if countsForBatch {
            activeBatch?.skipped += skipped
        }
        let candidates = pending.sorted { ($0.modified ?? Date.distantPast) > ($1.modified ?? Date.distantPast) }
        guard !candidates.isEmpty else { return true }
        if countsForBatch || candidates.count >= LibraryIndexer.busyThreshold {
            isIndexing = true
        }

        let source = sourceName(forFolder: folderPath)
        let knownHashes = Set(store.items.map { $0.contentHash })
        let limit = LibraryIndexer.maximumConcurrentAnalyses

        return await withTaskGroup(of: FileOutcome.self, returning: Bool.self) { group in
            var completed = true
            var nextIndex = 0
            var running = 0
            while true {
                while running < limit && nextIndex < candidates.count {
                    if Task.isCancelled || generation != scanGeneration || isCollectingPaused {
                        completed = false
                        break
                    }
                    if !store.settings.watchedFolders.contains(folderPath) {
                        nextIndex = candidates.count
                        break
                    }
                    if SystemConditions.shouldDeferBackgroundWork {
                        break
                    }
                    let candidate = candidates[nextIndex]
                    nextIndex += 1
                    running += 1
                    group.addTask(priority: .utility) {
                        IndexWork.analyze(candidate, source: source, knownHashes: knownHashes)
                    }
                }
                if running == 0 {
                    if !completed || nextIndex >= candidates.count {
                        break
                    }
                    // Low Power Mode or a hot Mac: wait, then look again.
                    try? await Task.sleep(nanoseconds: LibraryIndexer.deferredRetryNanoseconds)
                    continue
                }
                if let outcome = await group.next() {
                    running -= 1
                    if generation == scanGeneration {
                        apply(outcome, folderPath: folderPath, countsForBatch: countsForBatch)
                    }
                } else {
                    running = 0
                }
            }
            return completed
        }
    }

    private func apply(_ outcome: FileOutcome, folderPath: String, countsForBatch: Bool) {
        guard store.settings.watchedFolders.contains(folderPath) else { return }
        let batchCounts = countsForBatch && activeBatch != nil

        switch outcome {
        case .indexed(let item, let file):
            if let existing = store.item(atPath: file.path) {
                replace(existing, with: item)
                ignoredFiles[file.path] = nil
            } else if store.add(item) {
                ignoredFiles[file.path] = nil
                markChanged()
                if item.tier == .meme {
                    progressCount += 1
                }
                if batchCounts {
                    if item.tier == .skipped {
                        activeBatch?.skipped += 1
                    } else {
                        activeBatch?.addedIDs.append(item.id)
                    }
                }
            } else {
                ignoredFiles[file.path] = file.stamp
                if batchCounts {
                    activeBatch?.duplicates += 1
                }
            }

        case .duplicate(let file, let hash):
            if let existing = store.item(atPath: file.path) {
                if existing.contentHash == hash {
                    // Same bytes with a new timestamp: refresh the stamp only.
                    var refreshed = existing
                    refreshed.fileModifiedAt = file.modified
                    refreshed.fileSize = file.size
                    store.update(refreshed)
                    markChanged()
                    break
                }
                // The file at this path now duplicates another item.
                store.remove(ids: [existing.id])
                markChanged()
            }
            ignoredFiles[file.path] = file.stamp
            if batchCounts {
                activeBatch?.duplicates += 1
            }

        case .unreadable(let file):
            ignoredFiles[file.path] = file.stamp
            if batchCounts {
                activeBatch?.skipped += 1
            }
        }

        saveIfDue()
        notifyIfDue()
    }

    /// The file at an indexed path changed: keep the item's identity and history, take the new analysis.
    private func replace(_ existing: LibraryItem, with item: LibraryItem) {
        if item.contentHash != existing.contentHash && store.contains(hash: item.contentHash) {
            store.remove(ids: [existing.id])
        } else {
            var updated = item
            updated.id = existing.id
            updated.addedAt = existing.addedAt
            updated.timesSent = existing.timesSent
            updated.lastSentAt = existing.lastSentAt
            store.update(updated)
        }
        markChanged()
    }

    /// Drops index entries for files that are no longer in the folder.
    private func removeVanishedItems(inFolder folderPath: String, present: Set<String>) {
        var vanished = Set<UUID>()
        for item in store.items where item.kind == .mine {
            let itemPath = item.fileURL.standardizedFileURL.path
            guard (itemPath as NSString).deletingLastPathComponent == folderPath, !present.contains(itemPath) else { continue }
            vanished.insert(item.id)
        }
        guard !vanished.isEmpty else { return }
        store.remove(ids: vanished)
        markChanged()
    }

    private func removeItems(inFolder folderPath: String) {
        var ids = Set<UUID>()
        for item in store.items where item.kind == .mine {
            let itemPath = item.fileURL.standardizedFileURL.path
            if (itemPath as NSString).deletingLastPathComponent == folderPath {
                ids.insert(item.id)
            }
        }
        for path in Array(ignoredFiles.keys) where (path as NSString).deletingLastPathComponent == folderPath {
            ignoredFiles[path] = nil
        }
        guard !ids.isEmpty else { return }
        store.remove(ids: ids)
        markChanged()
    }

    /// "Downloads", "Desktop", "Screenshots" for the screenshot folder, else the folder name.
    private func sourceName(forFolder path: String) -> String {
        if path == LibraryPaths.downloads() { return "Downloads" }
        if path == LibraryPaths.desktop() { return "Desktop" }
        if path == LibraryPaths.screenshots() { return "Screenshots" }
        let name = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// Modification dates round-trip through ISO-8601 (whole seconds), so they match within a second.
    private static func hasSameStamp(_ item: LibraryItem, _ file: FileCandidate) -> Bool {
        guard item.fileSize == file.size else { return false }
        switch (item.fileModifiedAt, file.modified) {
        case (nil, nil):
            return true
        case (let stored?, let current?):
            return abs(stored.timeIntervalSince(current)) < 1
        default:
            return false
        }
    }

    // MARK: - Persistence

    private func markChanged() {
        hasUnsavedChanges = true
        hasUnnotifiedChanges = true
    }

    private func saveIfDue() {
        guard hasUnsavedChanges, Date().timeIntervalSince(lastSave) >= LibraryIndexer.saveInterval else { return }
        saveNow()
    }

    private func saveNow() {
        lastSave = Date()
        hasUnsavedChanges = false
        do {
            try store.save()
        } catch {
            indexLog.error("Saving library failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func notifyIfDue() {
        guard hasUnnotifiedChanges, Date().timeIntervalSince(lastNotify) >= LibraryIndexer.notifyInterval else { return }
        notifyNow()
    }

    private func notifyNow() {
        lastNotify = Date()
        hasUnnotifiedChanges = false
        onLibraryChanged?()
    }

    private func flushChanges() {
        if hasUnsavedChanges || store.isDirty {
            saveNow()
        }
        if hasUnnotifiedChanges {
            notifyNow()
        }
    }
}

// MARK: - Values passed to and from background work

private struct ScanRequest {
    let folderPath: String
    var batchID: UUID?
}

private struct FileStamp: Equatable, Sendable {
    let modified: Date?
    let size: Int64
}

private struct FileCandidate: Sendable {
    let url: URL
    let path: String          // standardized
    let modified: Date?
    let size: Int64
    let isImage: Bool

    var stamp: FileStamp {
        FileStamp(modified: modified, size: size)
    }
}

private enum FileOutcome: Sendable {
    case indexed(LibraryItem, FileCandidate)
    case duplicate(FileCandidate, String)   // content hash already in the library
    case unreadable(FileCandidate)
}

private enum KeepOutcome: Sendable {
    case item(LibraryItem)
    case duplicate
    case failed
}

// MARK: - Folder locations

private enum LibraryPaths {
    static func standardized(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    static func standardized(path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static func downloads() -> String {
        let fileManager = FileManager.default
        let url = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        return standardized(url)
    }

    static func desktop() -> String {
        let fileManager = FileManager.default
        let url = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        return standardized(url)
    }

    /// `com.apple.screencapture` → `location` (tilde expanded), default Desktop.
    static func screenshots() -> String {
        let defaults = UserDefaults(suiteName: "com.apple.screencapture")
        let stored = defaults?.string(forKey: "location") ?? ""
        let raw = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return desktop()
        }
        var path = raw
        if path.hasPrefix("file://"), let url = URL(string: path) {
            path = url.path
        }
        path = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return desktop()
        }
        return standardized(path: path)
    }
}

// MARK: - Folder scanning (off the main actor)

private enum IndexWork {
    /// Top-level regular, non-hidden files; nil when the folder can't be read.
    static func listFolder(_ folderURL: URL) -> [FileCandidate]? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey, .contentModificationDateKey, .fileSizeKey, .contentTypeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
        ) else {
            return nil
        }
        let keySet = Set(keys)
        var files: [FileCandidate] = []
        files.reserveCapacity(entries.count)
        for entry in entries {
            guard !entry.lastPathComponent.hasPrefix("."),
                  let values = try? entry.resourceValues(forKeys: keySet),
                  values.isRegularFile == true,
                  values.isHidden != true else {
                continue
            }
            let type = values.contentType ?? UTType(filenameExtension: entry.pathExtension)
            files.append(FileCandidate(
                url: entry,
                path: entry.standardizedFileURL.path,
                modified: values.contentModificationDate,
                size: Int64(values.fileSize ?? 0),
                isImage: type?.conforms(to: .image) ?? false
            ))
        }
        return files
    }

    /// Hashes, classifies and (unless skipped) fully analyzes one file. Synchronous and heavy.
    static func analyze(_ file: FileCandidate, source: String, knownHashes: Set<String>) -> FileOutcome {
        guard let loaded = ImageAnalyzer.load(url: file.url) else { return .unreadable(file) }
        let hash = ImageAnalyzer.sha256Hex(loaded.data)
        if knownHashes.contains(hash) {
            return .duplicate(file, hash)
        }

        // Tiny images and camera photos are skipped whatever Vision would find: skip the expensive part.
        let quickFacts = ImageFacts(
            pixelWidth: loaded.pixelWidth,
            pixelHeight: loaded.pixelHeight,
            isAnimated: loaded.isAnimated,
            isCameraPhoto: loaded.isCameraPhoto,
            isScreenshot: loaded.isScreenshot,
            textCharacterCount: 0,
            faceCount: 0,
            largestFaceHeightFraction: 0,
            labels: []
        )
        var tier = MemeTierClassifier.tier(for: quickFacts)
        var analysis: ImageAnalysis?
        if tier != .skipped {
            do {
                let full = try ImageAnalyzer.analyze(loaded, includeText: true)
                tier = MemeTierClassifier.tier(for: full.facts)
                analysis = full
            } catch {
                return .unreadable(file)
            }
        }

        // A scanned file is dated by the file itself, not by when the scan reached it: the first scan runs
        // newest first, so the analysis time would rank the oldest files as the newest (Recent fill order).
        let now = Date()
        var item = LibraryItem(
            fileURL: file.url,
            displayName: file.url.deletingPathExtension().lastPathComponent,
            kind: .mine,
            tier: tier,
            source: source,
            addedAt: min(now, file.modified ?? now),
            fileModifiedAt: file.modified,
            fileSize: file.size,
            contentHash: hash,
            isAnimated: loaded.isAnimated
        )
        // Skipped items keep only path, hash, dates and tier: no face data, fingerprint, text or labels.
        if tier != .skipped, let analysis = analysis {
            item.sourceDetail = ImageAnalyzer.downloadedFromHost(url: file.url).map { "from " + $0 }
            item.face = analysis.face
            item.pose = analysis.pose
            item.intensity = analysis.intensity
            item.featurePrint = analysis.featurePrint
            item.featurePrintRevision = analysis.featurePrintRevision
            item.text = analysis.text
            item.labels = analysis.labels
        }
        return .indexed(item, file)
    }
}

// MARK: - Hand-ins (off the main actor)

private enum KeepWork {
    static let maximumBytes = 25 * 1024 * 1024

    /// Downloads or reads the file, skips known content, copies it into Kept under a unique name and analyzes it.
    static func prepare(_ url: URL, keptDirectory: URL, source: String, knownHashes: Set<String>) async -> KeepOutcome {
        let data: Data
        let suggestedName: String
        let host: String?
        let originalModified: Date?

        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            guard let downloaded = await download(url) else { return .failed }
            data = downloaded.data
            suggestedName = downloaded.name
            host = normalizedHost(url.host)
            originalModified = nil
        } else if url.isFileURL {
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) <= maximumBytes,
                  let contents = try? Data(contentsOf: url) else {
                return .failed
            }
            data = contents
            suggestedName = url.lastPathComponent
            host = ImageAnalyzer.downloadedFromHost(url: url)
            originalModified = values.contentModificationDate
        } else {
            return .failed
        }
        guard !data.isEmpty, data.count <= maximumBytes else { return .failed }

        let hash = ImageAnalyzer.sha256Hex(data)
        if knownHashes.contains(hash) {
            return .duplicate
        }
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(imageSource) > 0 else {
            return .failed
        }
        let typeIdentifier = CGImageSourceGetType(imageSource).map { $0 as String }
        let naming = fileName(suggested: suggestedName, typeIdentifier: typeIdentifier)
        guard let destination = writeUnique(data, named: naming.fileName, in: keptDirectory) else { return .failed }

        do {
            let analysis = try ImageAnalyzer.analyze(url: destination, includeText: true)
            var tier = MemeTierClassifier.tier(for: analysis.facts)
            if tier == .skipped {
                // Handed in on purpose: always findable by words.
                tier = .maybe
            }
            let item = LibraryItem(
                fileURL: destination,
                displayName: naming.displayName,
                kind: .mine,
                tier: tier,
                source: source,
                sourceDetail: host.map { "from " + $0 },
                addedAt: Date(),
                fileModifiedAt: originalModified,
                fileSize: Int64(data.count),
                contentHash: hash,
                isSticker: false,
                isAnimated: analysis.facts.isAnimated,
                face: analysis.face,
                pose: analysis.pose,
                intensity: analysis.intensity,
                featurePrint: analysis.featurePrint,
                featurePrintRevision: analysis.featurePrintRevision,
                text: analysis.text,
                labels: analysis.labels
            )
            return .item(item)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return .failed
        }
    }

    private static func download(_ url: URL) async -> (data: Data, name: String)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request)
        } catch {
            indexLog.error("Downloading a dropped image failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let data = result.0
        let response = result.1
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }
        guard !data.isEmpty, data.count <= maximumBytes else { return nil }
        let name = response.suggestedFilename ?? url.lastPathComponent
        return (data: data, name: name)
    }

    private static func normalizedHost(_ host: String?) -> String? {
        guard var host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host.isEmpty ? nil : host
    }

    /// A safe file name whose extension matches the image type, plus the display name (no extension).
    private static func fileName(suggested: String, typeIdentifier: String?) -> (fileName: String, displayName: String) {
        let nsName = suggested as NSString
        var base = nsName.deletingPathExtension
        var pathExtension = nsName.pathExtension.lowercased()

        base = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") {
            base.removeFirst()
        }
        if base.count > 100 {
            base = String(base.prefix(100))
        }
        if base.isEmpty {
            base = "image"
        }

        if let identifier = typeIdentifier, let type = UTType(identifier), let preferred = type.preferredFilenameExtension {
            let current = pathExtension.isEmpty ? nil : UTType(filenameExtension: pathExtension)
            if current?.conforms(to: type) != true {
                pathExtension = preferred
            }
        }
        if pathExtension.isEmpty {
            pathExtension = "png"
        }
        return (fileName: base + "." + pathExtension, displayName: base)
    }

    /// Writes without overwriting: "name.ext", "name 2.ext", "name 3.ext", …
    private static func writeUnique(_ data: Data, named fileName: String, in directory: URL) -> URL? {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let nsName = fileName as NSString
        let base = nsName.deletingPathExtension
        let pathExtension = nsName.pathExtension

        for attempt in 1...200 {
            let candidateName: String
            if attempt == 1 {
                candidateName = fileName
            } else if pathExtension.isEmpty {
                candidateName = "\(base) \(attempt)"
            } else {
                candidateName = "\(base) \(attempt).\(pathExtension)"
            }
            let candidate = directory.appendingPathComponent(candidateName, isDirectory: false)
            if fileManager.fileExists(atPath: candidate.path) { continue }
            do {
                try data.write(to: candidate, options: .withoutOverwriting)
                return candidate
            } catch {
                if fileManager.fileExists(atPath: candidate.path) { continue }
                indexLog.error("Copying a kept image failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        let fallbackName = pathExtension.isEmpty ? UUID().uuidString : UUID().uuidString + "." + pathExtension
        let fallback = directory.appendingPathComponent(fallbackName, isDirectory: false)
        do {
            try data.write(to: fallback, options: .withoutOverwriting)
            return fallback
        } catch {
            return nil
        }
    }
}
