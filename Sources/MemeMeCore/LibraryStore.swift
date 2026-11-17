import Foundation

/// The on-disk index: library.json, people.json, recents.json and settings.json under `rootURL`.
/// Not thread-safe: used from the main actor only. Each file is written only when it changed, so a send or a
/// setting doesn't re-encode the whole library; `saveInBackground()` encodes and writes off the caller's thread.
public final class LibraryStore {
    public let rootURL: URL
    public private(set) var items: [LibraryItem] = []
    public private(set) var people: [Person] = []
    /// Whether anything changed since the last save.
    public var isDirty: Bool { !changes.isEmpty }

    /// Which files changed since the last save.
    private struct Changes: OptionSet {
        let rawValue: UInt8
        static let library = Changes(rawValue: 1 << 0)
        static let people = Changes(rawValue: 1 << 1)
        static let recents = Changes(rawValue: 1 << 2)
        static let settings = Changes(rawValue: 1 << 3)
    }

    private var changes: Changes = []

    /// Setting marks the store dirty.
    public var recents: RecentStore {
        get { storedRecents }
        set {
            storedRecents = newValue
            changes.insert(.recents)
        }
    }

    /// Setting marks the store dirty.
    public var settings: AppSettings {
        get { storedSettings }
        set {
            storedSettings = newValue
            changes.insert(.settings)
        }
    }

    private var storedRecents = RecentStore()
    private var storedSettings = AppSettings()
    private var indexByID: [UUID: Int] = [:]
    private var idByHash: [String: UUID] = [:]
    private var idByPath: [String: UUID] = [:]

    private static let libraryFileName = "library.json"
    private static let peopleFileName = "people.json"
    private static let recentsFileName = "recents.json"
    private static let settingsFileName = "settings.json"

    /// Outcome of reading one JSON file.
    private enum LoadResult<Value> {
        case missing
        case unreadable
        case loaded(Value)
    }

    /// Creates the directory; loads library.json, people.json, recents.json, settings.json if present.
    /// An unreadable file is renamed to *.bak and replaced by empty state.
    public init(rootURL: URL) throws {
        self.rootURL = rootURL
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: nil)

        switch load([LossyDecodable<LibraryItem>].self, fileName: LibraryStore.libraryFileName) {
        case .missing:
            break
        case .unreadable:
            changes.insert(.library)
        case .loaded(let entries):
            let decoded = entries.compactMap { $0.value }
            if decoded.count != entries.count {
                // Some entries could not be read: keep a copy of the original next to the rewritten file.
                backUp(fileName: LibraryStore.libraryFileName)
                changes.insert(.library)
            }
            var unique: [LibraryItem] = []
            var seenIDs = Set<UUID>()
            var seenHashes = Set<String>()
            for item in decoded {
                if seenIDs.contains(item.id) || seenHashes.contains(item.contentHash) {
                    changes.insert(.library)
                    continue
                }
                seenIDs.insert(item.id)
                seenHashes.insert(item.contentHash)
                unique.append(item)
            }
            items = unique
        }

        switch load([LossyDecodable<Person>].self, fileName: LibraryStore.peopleFileName) {
        case .missing:
            break
        case .unreadable:
            changes.insert(.people)
        case .loaded(let entries):
            let decoded = entries.compactMap { $0.value }
            if decoded.count != entries.count {
                backUp(fileName: LibraryStore.peopleFileName)
                changes.insert(.people)
            }
            var unique: [Person] = []
            var seenIDs = Set<UUID>()
            for person in decoded where !seenIDs.contains(person.id) {
                seenIDs.insert(person.id)
                unique.append(person)
            }
            people = unique
        }

        switch load(RecentStore.self, fileName: LibraryStore.recentsFileName) {
        case .missing:
            break
        case .unreadable:
            changes.insert(.recents)
        case .loaded(let value):
            storedRecents = value
        }

        switch load(AppSettings.self, fileName: LibraryStore.settingsFileName) {
        case .missing:
            break
        case .unreadable:
            changes.insert(.settings)
        case .loaded(let value):
            storedSettings = value
        }

        rebuildIndexes()
    }

    /// ~/Library/Application Support/MemeMe
    public static func defaultRootURL() -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("MemeMe", isDirectory: true)
    }

    /// rootURL/Kept, created on access.
    public var keptDirectory: URL { subdirectory(named: "Kept") }

    /// rootURL/Stickers, created on access.
    public var stickersDirectory: URL { subdirectory(named: "Stickers") }

    // MARK: Lookup

    public func item(id: UUID) -> LibraryItem? {
        guard let index = indexByID[id], index < items.count else { return nil }
        return items[index]
    }

    public func item(atPath path: String) -> LibraryItem? {
        guard let id = idByPath[LibraryStore.pathKey(forPath: path)] else { return nil }
        return item(id: id)
    }

    public func contains(hash: String) -> Bool {
        idByHash[hash] != nil
    }

    public func stickerCount(personID: UUID) -> Int {
        var count = 0
        for item in items where item.personID == personID { count += 1 }
        return count
    }

    // MARK: Mutation

    /// false (no-op) when an item with the same contentHash (or id) exists.
    @discardableResult
    public func add(_ item: LibraryItem) -> Bool {
        guard idByHash[item.contentHash] == nil, indexByID[item.id] == nil else { return false }
        items.append(item)
        register(item, at: items.count - 1)
        changes.insert(.library)
        return true
    }

    /// Replaces the item with the same id; no-op when it is not in the library.
    public func update(_ item: LibraryItem) {
        guard let index = indexByID[item.id], index < items.count else { return }
        let previous = items[index]
        items[index] = item
        if previous.contentHash != item.contentHash || previous.fileURL != item.fileURL {
            rebuildIndexes()
        }
        changes.insert(.library)
    }

    /// Deletes files only when they are inside rootURL; also removes the ids from recents.
    public func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let rootPath = LibraryStore.pathKey(for: rootURL)
        var remaining: [LibraryItem] = []
        remaining.reserveCapacity(items.count)
        var removedAny = false
        for item in items {
            guard ids.contains(item.id) else {
                remaining.append(item)
                continue
            }
            removedAny = true
            if LibraryStore.isFile(item.fileURL, insideDirectoryAtPath: rootPath) {
                try? FileManager.default.removeItem(at: item.fileURL)
            }
        }
        if removedAny {
            items = remaining
            rebuildIndexes()
            changes.insert(.library)
        }
        var updatedRecents = storedRecents
        updatedRecents.remove(ids)
        if updatedRecents != storedRecents {
            storedRecents = updatedRecents
            changes.insert(.recents)
        }
    }

    /// Items whose file MemeMe keeps itself (kept images, stickers: under rootURL) is gone, deleted in Finder say.
    /// Files in watched folders are the indexer's to reconcile. Cheap enough for every panel open: a path prefix
    /// test per item, and a file check only for the files under rootURL.
    public func idsWithMissingFiles() -> Set<UUID> {
        let rootPath = LibraryStore.pathKey(for: rootURL)
        let prefixes = Set([rootURL.path, rootPath].map { $0.hasSuffix("/") ? $0 : $0 + "/" })
        var ids = Set<UUID>()
        for item in items where item.fileURL.isFileURL {
            let path = item.fileURL.path
            guard prefixes.contains(where: { path.hasPrefix($0) }) else { continue }
            if !FileManager.default.fileExists(atPath: path) {
                ids.insert(item.id)
            }
        }
        return ids
    }

    /// Forgets `idsWithMissingFiles()`, with their recents. Returns how many were removed.
    @discardableResult
    public func removeItemsWithMissingFiles() -> Int {
        let ids = idsWithMissingFiles()
        remove(ids: ids)
        return ids.count
    }

    /// rootURL/Sent, where earlier versions kept the stills of GIPHY picks that were sent. Never created.
    public var legacySentDirectory: URL {
        rootURL.appendingPathComponent("Sent", isDirectory: true)
    }

    /// Forgets the GIPHY picks earlier versions saved when they were sent (GIPHY's media is no longer kept),
    /// with their files and recents, then the Sent folder unless something else still uses it.
    /// Returns how many items were removed.
    @discardableResult
    public func removeSavedWebItems() -> Int {
        let ids = Set(items.filter { $0.kind == .web || $0.contentHash.hasPrefix("giphy:") }.map(\.id))
        remove(ids: ids)
        let sentPath = LibraryStore.pathKey(for: legacySentDirectory)
        let stillUsed = items.contains { LibraryStore.isFile($0.fileURL, insideDirectoryAtPath: sentPath) }
            || storedSettings.watchedFolders.contains { LibraryStore.pathKey(forPath: $0) == sentPath }
        if !stillUsed, FileManager.default.fileExists(atPath: sentPath) {
            try? FileManager.default.removeItem(at: legacySentDirectory)
        }
        return ids.count
    }

    /// Inserts or replaces the person with the same id.
    public func upsert(_ person: Person) {
        if let index = people.firstIndex(where: { $0.id == person.id }) {
            people[index] = person
        } else {
            people.append(person)
        }
        changes.insert(.people)
    }

    /// Removes the person and clears personID on its items.
    public func removePerson(id: UUID) {
        people.removeAll { $0.id == id }
        changes.insert(.people)
        for index in items.indices where items[index].personID == id {
            items[index].personID = nil
            changes.insert(.library)
        }
    }

    /// Atomic JSON writes (sorted keys, ISO-8601 dates) of the files that changed; clears isDirty. Waits for
    /// earlier background saves first, so the files are always written in order (and nothing is lost on quit).
    /// On failure the unwritten files stay marked as changed.
    public func save() throws {
        let snapshot = takeSnapshot()
        do {
            try LibraryStore.writes.sync { try snapshot.write() }
        } catch {
            changes.formUnion(snapshot.changes)
            throw error
        }
    }

    /// Like `save()`, but the encoding (several MB for a big library) and the writes happen on a background queue,
    /// so the caller's thread doesn't stall. The values are copied now; later changes go into a later save. If the
    /// write fails, the files are marked as changed again on the main queue and `onFailure` gets the error there.
    public func saveInBackground(onFailure: @escaping (Error) -> Void = { _ in }) {
        let snapshot = takeSnapshot()
        guard !snapshot.changes.isEmpty else { return }
        LibraryStore.writes.async { [weak self] in
            do {
                try snapshot.write()
            } catch {
                DispatchQueue.main.async {
                    self?.changes.formUnion(snapshot.changes)
                    onFailure(error)
                }
            }
        }
    }

    // MARK: Saving

    /// One serial queue for every store's writes, so they land in the order they were asked for.
    private static let writes = DispatchQueue(label: "app.mememe.library-store.writes", qos: .utility)

    /// The changed values, copied (cheaply: they are value types) so they can be encoded on another thread.
    private struct Snapshot {
        let rootURL: URL
        let changes: Changes
        let items: [LibraryItem]
        let people: [Person]
        let recents: RecentStore
        let settings: AppSettings

        func write() throws {
            guard !changes.isEmpty else { return }
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: nil)
            let encoder = LibraryStore.makeEncoder()
            if changes.contains(.library) { try write(encoder.encode(items), fileName: LibraryStore.libraryFileName) }
            if changes.contains(.people) { try write(encoder.encode(people), fileName: LibraryStore.peopleFileName) }
            if changes.contains(.recents) { try write(encoder.encode(recents), fileName: LibraryStore.recentsFileName) }
            if changes.contains(.settings) { try write(encoder.encode(settings), fileName: LibraryStore.settingsFileName) }
        }

        private func write(_ data: Data, fileName: String) throws {
            try data.write(to: rootURL.appendingPathComponent(fileName, isDirectory: false), options: .atomic)
        }
    }

    /// Copies what changed and clears the change marks.
    private func takeSnapshot() -> Snapshot {
        let snapshot = Snapshot(rootURL: rootURL, changes: changes, items: items, people: people,
                                recents: storedRecents, settings: storedSettings)
        changes = []
        return snapshot
    }

    // MARK: Private

    private func fileURL(named fileName: String) -> URL {
        rootURL.appendingPathComponent(fileName, isDirectory: false)
    }

    private func subdirectory(named name: String) -> URL {
        let url = rootURL.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return url
    }

    private func load<Value: Decodable>(_ type: Value.Type, fileName: String) -> LoadResult<Value> {
        let url = fileURL(named: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            let value = try LibraryStore.makeDecoder().decode(type, from: data)
            return .loaded(value)
        } catch {
            moveAside(fileName: fileName)
            return .unreadable
        }
    }

    /// Renames `fileName` to `fileName.bak` (replacing an older backup).
    private func moveAside(fileName: String) {
        let fileManager = FileManager.default
        let source = fileURL(named: fileName)
        let backup = fileURL(named: fileName + ".bak")
        try? fileManager.removeItem(at: backup)
        do {
            try fileManager.moveItem(at: source, to: backup)
        } catch {
            try? fileManager.removeItem(at: source)
        }
    }

    /// Copies `fileName` to `fileName.bak` (replacing an older backup).
    private func backUp(fileName: String) {
        let fileManager = FileManager.default
        let backup = fileURL(named: fileName + ".bak")
        try? fileManager.removeItem(at: backup)
        try? fileManager.copyItem(at: fileURL(named: fileName), to: backup)
    }

    private func register(_ item: LibraryItem, at index: Int) {
        indexByID[item.id] = index
        idByHash[item.contentHash] = item.id
        idByPath[LibraryStore.pathKey(for: item.fileURL)] = item.id
    }

    private func rebuildIndexes() {
        indexByID = [:]
        idByHash = [:]
        idByPath = [:]
        indexByID.reserveCapacity(items.count)
        idByHash.reserveCapacity(items.count)
        idByPath.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            register(item, at: index)
        }
    }

    private static func pathKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func pathKey(forPath path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func isFile(_ url: URL, insideDirectoryAtPath directoryPath: String) -> Bool {
        guard url.isFileURL else { return false }
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return pathKey(for: url).hasPrefix(prefix)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
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

/// Decodes an element without failing the surrounding array: `value` is nil when the element is unreadable.
private struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(Value.self)
    }
}
