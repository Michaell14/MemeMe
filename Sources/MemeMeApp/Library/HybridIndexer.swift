import Foundation
import MemeMeCore
import os

private let hybridIndexLog = Logger(subsystem: "com.mememe.app", category: "hybrid-index")

/// Keeps the hybrid matcher's meme index (`HybridIndex`, `hybrid-index.json` beside library.json) up to date: every
/// meme, sticker and kept image of the library and every classic meme (Imgflip's list) gets an entry, computed on
/// the Mac in the background (one at a time, utility priority, waiting in Low Power Mode or when the Mac is hot).
/// A library change, a newly kept or saved meme, a new sticker or a new Imgflip list calls `sync`; entries for items
/// that are gone are dropped, and items whose file changed (another contentHash) are read again.
@MainActor final class HybridIndexer {
    private(set) var index = HybridIndex()
    private(set) var models: HybridModels?
    private let fileURL: URL
    private var queue: [Job] = []
    private var queuedKeys: Set<String> = []
    private var worker: Task<Void, Never>?
    private var lastSave = Date.distantPast
    private var dirty = false
    /// Templates whose image couldn't be downloaded, so a failing one isn't retried on every sync.
    private var failedTemplates: [String: Date] = [:]

    private static let saveInterval: TimeInterval = 10
    private static let templateRetry: TimeInterval = 3600

    enum Job: Sendable {
        case file(key: String, contentHash: String, url: URL)
        case template(key: String, url: URL, download: @Sendable () async -> Data?)

        var key: String {
            switch self {
            case let .file(key, _, _), let .template(key, _, _): return key
            }
        }
    }

    /// Inactive until `activate`: the classic matcher (or no models) never reads or writes the index.
    init(rootURL: URL) {
        fileURL = rootURL.appendingPathComponent(HybridIndex.fileName, isDirectory: false)
    }

    /// Starts indexing with the models, from the index loaded off the main actor (`HybridIndex.load`).
    func activate(models: HybridModels, index: HybridIndex) {
        self.models = models
        self.index = index
    }

    var isAvailable: Bool { models != nil }
    var isIndexing: Bool { worker != nil }

    /// The items the hybrid ranks: yours, friends' stickers and packs, except GIPHY's and skipped images.
    static func indexes(_ item: LibraryItem) -> Bool {
        item.kind != .web && item.tier != .skipped
    }

    func entry(for item: LibraryItem) -> HybridIndexEntry? {
        guard let entry = index[item.id.uuidString], entry.contentHash == item.contentHash else { return nil }
        return entry
    }

    func entry(for template: MemeTemplate) -> HybridIndexEntry? {
        guard let entry = index[HybridIndex.templateKey(template.id)], entry.contentHash == template.url.absoluteString else {
            return nil
        }
        return entry
    }

    /// Queues the library's new and changed items, and forgets the ones that are gone.
    func sync(items: [LibraryItem]) {
        guard models != nil else { return }
        let wanted = items.filter(HybridIndexer.indexes)
        let removed = index.retain(keys: Set(wanted.map { $0.id.uuidString }), where: { !HybridIndex.isTemplateKey($0) })
        if removed > 0 { markDirty() }
        // Newest first, like the library scan: what was just added is searchable first.
        let fresh = wanted
            .filter { index.needsIndexing(key: $0.id.uuidString, contentHash: $0.contentHash) }
            .sorted { ($0.fileModifiedAt ?? $0.addedAt) > ($1.fileModifiedAt ?? $1.addedAt) }
        for item in fresh {
            enqueue(.file(key: item.id.uuidString, contentHash: item.contentHash, url: item.fileURL), first: true)
        }
        startIfNeeded()
    }

    /// Queues Imgflip's templates that are new or whose image changed, and forgets the ones no longer listed.
    func sync(templates: [MemeTemplate], download: @escaping @Sendable (MemeTemplate) async -> Data?) {
        guard models != nil else { return }
        let keys = Set(templates.map { HybridIndex.templateKey($0.id) })
        if index.retain(keys: keys, where: HybridIndex.isTemplateKey) > 0 { markDirty() }
        let now = Date()
        for template in templates {
            let key = HybridIndex.templateKey(template.id)
            guard index.needsIndexing(key: key, contentHash: template.url.absoluteString) else { continue }
            if let failed = failedTemplates[key], now.timeIntervalSince(failed) < HybridIndexer.templateRetry { continue }
            enqueue(.template(key: key, url: template.url, download: { await download(template) }), first: false)
        }
        startIfNeeded()
    }

    /// Writes the index now if anything changed (the app quitting).
    func saveNow() {
        guard dirty else { return }
        do {
            try index.save(to: fileURL)
            dirty = false
            lastSave = Date()
        } catch {
            hybridIndexLog.error("Saving the hybrid index failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private

    private func enqueue(_ job: Job, first: Bool) {
        guard !queuedKeys.contains(job.key) else { return }
        queuedKeys.insert(job.key)
        if first { queue.insert(job, at: 0) } else { queue.append(job) }
    }

    private func markDirty() {
        dirty = true
        if Date().timeIntervalSince(lastSave) >= HybridIndexer.saveInterval { saveNow() }
    }

    private func startIfNeeded() {
        guard worker == nil, !queue.isEmpty, let models else { return }
        worker = Task { [weak self] in
            while let self, let job = self.nextJob() {
                while SystemConditions.shouldDeferBackgroundWork {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                }
                let entry = await HybridIndexer.compute(job, models: models)
                self.queuedKeys.remove(job.key)
                if let entry {
                    self.index.upsert(entry)
                    self.markDirty()
                } else if case .template = job {
                    self.failedTemplates[job.key] = Date()
                }
            }
            guard let self else { return }
            self.worker = nil
            self.saveNow()
            // Jobs queued while the last one finished.
            self.startIfNeeded()
        }
    }

    private func nextJob() -> Job? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    private nonisolated static func compute(_ job: Job, models: HybridModels) async -> HybridIndexEntry? {
        switch job {
        case let .file(key, contentHash, url):
            return await Task.detached(priority: .utility) {
                do {
                    return try HybridAnalyzer.entry(forFile: url, key: key, contentHash: contentHash, models: models)
                } catch {
                    hybridIndexLog.error("Indexing a meme for the hybrid matcher failed: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }.value
        case let .template(key, url, download):
            guard let data = await download() else { return nil }
            return await Task.detached(priority: .utility) {
                try? HybridAnalyzer.entry(forData: data, key: key, contentHash: url.absoluteString, models: models)
            }.value
        }
    }
}
