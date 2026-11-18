import Foundation

/// A group of your stickers you named ("Reactions", "Work", "Sam & Jo"). A sticker can be in several. Kept in
/// recents.json with Favorites (`RecentStore.groups`).
///
/// A live group (a search saved as a group, `query`) holds every sticker the words match, now and later: its
/// members are worked out from the library each time (`members(in:people:)`), and nothing is filed in it by hand.
public struct StickerGroup: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    /// Its stickers, the latest filed first (none for a live group).
    public private(set) var stickerIDs: [UUID]
    /// When a sticker was last filed in it (or it was made): the Clip me notice offers the latest used first.
    public var lastUsedAt: Date
    /// The saved search's words, for a live group; nil for one you file stickers in.
    public var query: String?

    public init(id: UUID = UUID(), name: String, stickerIDs: [UUID] = [], lastUsedAt: Date = Date(),
                query: String? = nil) {
        self.id = id
        self.name = name
        var unique = Set<UUID>()
        self.stickerIDs = query == nil ? stickerIDs.filter { unique.insert($0).inserted } : []
        self.lastUsedAt = lastUsedAt
        self.query = query
    }

    /// A saved search: its stickers are what the words match.
    public var isLive: Bool { query != nil }

    /// Whether the sticker was filed in it (always false for a live group: see `members(in:people:)`).
    public func contains(_ stickerID: UUID) -> Bool {
        stickerIDs.contains(stickerID)
    }

    /// Its stickers among `items` (your stickers; others are left out): those filed in it that still exist, the
    /// latest filed first; for a live group, every sticker the words match, newest first.
    public func members(in items: [LibraryItem], people: [Person]) -> [UUID] {
        let stickers = items.filter { $0.isSticker && $0.kind != .web }
        guard let query else {
            let existing = Set(stickers.map(\.id))
            return stickerIDs.filter { existing.contains($0) }
        }
        guard let matches = StickerGroup.matcher(for: query, people: people) else { return [] }
        return stickers
            .filter(matches)
            .sorted { lhs, rhs in
                if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .map(\.id)
    }

    /// Whether a typed search matches the item the way the search field does (`Ranker`'s text search): every word in
    /// its name, text, labels, source or person's name, and the filter words (`sticker`, `gif`, a friend's name).
    /// Words that are only filter words match on the filters alone; no words at all match nothing.
    public static func matches(_ raw: String, item: LibraryItem, people: [Person]) -> Bool {
        matcher(for: raw, people: people)?(item) ?? false
    }

    /// The words parsed once, and people's names looked up once, for testing many items; nil when the words hold
    /// nothing to match by.
    static func matcher(for raw: String, people: [Person]) -> ((LibraryItem) -> Bool)? {
        let query = TextQuery.parse(raw, people: people)
        guard !query.terms.isEmpty || !query.personIDs.isEmpty || query.onlyGIFs || query.onlyStickers || query.onlyMine
        else { return nil }
        var names: [UUID: String] = [:]
        for person in people {
            if let name = person.name { names[person.id] = name }
        }
        return { item in
            guard Ranker.passesFilters(item, query: query) else { return false }
            let personName = item.personID.flatMap { names[$0] } ?? ""
            let haystack = Ranker.searchableText(of: item, personName: personName)
            return query.terms.allSatisfy { haystack.contains($0) }
        }
    }

    /// Files `stickerID` first; false when it already was in the group (or it is live).
    @discardableResult
    mutating func insert(_ stickerID: UUID) -> Bool {
        guard query == nil, !stickerIDs.contains(stickerID) else { return false }
        stickerIDs.insert(stickerID, at: 0)
        return true
    }

    @discardableResult
    mutating func remove(_ stickerID: UUID) -> Bool {
        guard let index = stickerIDs.firstIndex(of: stickerID) else { return false }
        stickerIDs.remove(at: index)
        return true
    }

    mutating func remove(_ ids: Set<UUID>) {
        stickerIDs.removeAll { ids.contains($0) }
    }

    /// A name as typed, trimmed and with inner runs of white space made one space; nil when nothing is left.
    public static func cleanName(_ raw: String) -> String? {
        let words = raw.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return nil }
        return String(words.joined(separator: " ").prefix(maxNameLength))
    }

    /// Names are cut to this many characters.
    public static let maxNameLength = 40

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, stickerIDs, lastUsedAt, query
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = StickerGroup.cleanName(container.decodeLenient(String.self, forKey: .name, default: "")) ?? "Group"
        var unique = Set<UUID>()
        stickerIDs = container.decodeLenient([UUID].self, forKey: .stickerIDs, default: []).filter { unique.insert($0).inserted }
        lastUsedAt = container.decodeLenient(Date.self, forKey: .lastUsedAt, default: .distantPast)
        // Groups from before live groups have no query; an empty one is no search.
        let words = container.decodeLenientIfPresent(String.self, forKey: .query)?.trimmingCharacters(in: .whitespacesAndNewlines)
        query = words?.isEmpty == false ? words : nil
        if query != nil { stickerIDs = [] }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(stickerIDs, forKey: .stickerIDs)
        try container.encode(lastUsedAt, forKey: .lastUsedAt)
        try container.encodeIfPresent(query, forKey: .query)
    }
}
