import Foundation

/// A group of your stickers you named ("Reactions", "Work", "Sam & Jo"). A sticker can be in several. Kept in
/// recents.json with Favorites (`RecentStore.groups`).
public struct StickerGroup: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    /// Its stickers, the latest filed first.
    public private(set) var stickerIDs: [UUID]
    /// When a sticker was last filed in it (or it was made): the Clip me notice offers the latest used first.
    public var lastUsedAt: Date

    public init(id: UUID = UUID(), name: String, stickerIDs: [UUID] = [], lastUsedAt: Date = Date()) {
        self.id = id
        self.name = name
        var unique = Set<UUID>()
        self.stickerIDs = stickerIDs.filter { unique.insert($0).inserted }
        self.lastUsedAt = lastUsedAt
    }

    public func contains(_ stickerID: UUID) -> Bool {
        stickerIDs.contains(stickerID)
    }

    /// Files `stickerID` first; false when it already was in the group.
    @discardableResult
    mutating func insert(_ stickerID: UUID) -> Bool {
        guard !stickerIDs.contains(stickerID) else { return false }
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
        case id, name, stickerIDs, lastUsedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = StickerGroup.cleanName(container.decodeLenient(String.self, forKey: .name, default: "")) ?? "Group"
        var unique = Set<UUID>()
        stickerIDs = container.decodeLenient([UUID].self, forKey: .stickerIDs, default: []).filter { unique.insert($0).inserted }
        lastUsedAt = container.decodeLenient(Date.self, forKey: .lastUsedAt, default: .distantPast)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(stickerIDs, forKey: .stickerIDs)
        try container.encode(lastUsedAt, forKey: .lastUsedAt)
    }
}
