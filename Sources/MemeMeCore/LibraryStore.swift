import Foundation

/// The on-disk index: library.json, people.json, recents.json and settings.json under `rootURL`.
/// Not thread-safe: used from the main actor only.
public final class LibraryStore {
    public let rootURL: URL
    public private(set) var items: [LibraryItem] = []
    public private(set) var people: [Person] = []
    public private(set) var isDirty: Bool = false

    /// Setting marks the store dirty.
    public var recents: RecentStore {
        get { storedRecents }
        set {
            storedRecents = newValue
            isDirty = true
        }
    }

    /// Setting marks the store dirty.
    public var settings: AppSettings {
        get { storedSettings }
        set {
            storedSettings = newValue
            isDirty = true
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
            isDirty = true
        case .loaded(let entries):
            let decoded = entries.compactMap { $0.value }
            if decoded.count != entries.count {
                // Some entries could not be read: keep a copy of the original next to the rewritten file.
                backUp(fileName: LibraryStore.libraryFileName)
                isDirty = true
            }
            var unique: [LibraryItem] = []
            var seenIDs = Set<UUID>()
            var seenHashes = Set<String>()
            for item in decoded {
                if seenIDs.contains(item.id) || seenHashes.contains(item.contentHash) {
                    isDirty = true
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
            isDirty = true
        case .loaded(let entries):
            let decoded = entries.compactMap { $0.value }
            if decoded.count != entries.count {
                backUp(fileName: LibraryStore.peopleFileName)
                isDirty = true
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
            isDirty = true
        case .loaded(let value):
            storedRecents = value
        }

        switch load(AppSettings.self, fileName: LibraryStore.settingsFileName) {
        case .missing:
            break
        case .unreadable:
            isDirty = true
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
        isDirty = true
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
        isDirty = true
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
            isDirty = true
        }
        var updatedRecents = storedRecents
        updatedRecents.remove(ids)
        if updatedRecents != storedRecents {
            storedRecents = updatedRecents
            isDirty = true
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
        isDirty = true
    }

    /// Removes the person and clears personID on its items.
    public func removePerson(id: UUID) {
        people.removeAll { $0.id == id }
        for index in items.indices where items[index].personID == id {
            items[index].personID = nil
        }
        isDirty = true
    }

    /// Atomic JSON writes (sorted keys, ISO-8601 dates); clears isDirty.
    public func save() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: nil)
        let encoder = LibraryStore.makeEncoder()
        try write(encoder.encode(items), fileName: LibraryStore.libraryFileName)
        try write(encoder.encode(people), fileName: LibraryStore.peopleFileName)
        try write(encoder.encode(storedRecents), fileName: LibraryStore.recentsFileName)
        try write(encoder.encode(storedSettings), fileName: LibraryStore.settingsFileName)
        isDirty = false
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

    private func write(_ data: Data, fileName: String) throws {
        try data.write(to: fileURL(named: fileName), options: .atomic)
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
