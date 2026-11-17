import Foundation

/// A bucket of stickers you named ("Reactions", "Work", "Sam & Jo"). A sticker can be in several groups, or none
/// (Ungrouped). Kept in recents.json with your favorites (`RecentStore.groups`).
public struct StickerGroup: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    /// Its stickers, newest first.
    public var members: [UUID]
    /// When a sticker was last put in it (or it was made): the Clip me notice offers the most recent first.
    public var usedAt: Date

    /// Group names are at most this long.
    public static let maximumNameLength = 40

    public init(id: UUID = UUID(), name: String, members: [UUID] = [], usedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.members = members
        self.usedAt = usedAt
    }

    public func contains(_ itemID: UUID) -> Bool {
        members.contains(itemID)
    }

    /// `name` trimmed and capped; nil when nothing is left.
    public static func cleanName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumNameLength))
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, members, usedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = container.decodeLenient(String.self, forKey: .name, default: "Group")
        var unique = Set<UUID>()
        members = container.decodeLenient([UUID].self, forKey: .members, default: []).filter { unique.insert($0).inserted }
        usedAt = container.decodeLenient(Date.self, forKey: .usedAt, default: Date(timeIntervalSince1970: 0))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(members, forKey: .members)
        try container.encode(usedAt, forKey: .usedAt)
    }
}

/// Which of your stickers My Stickers shows: all of them, one group's, or those in no group.
public enum StickerGroupFilter: Equatable, Hashable, Sendable {
    case all
    case group(UUID)
    case ungrouped
}

extension RecentStore {
    public func group(id: UUID) -> StickerGroup? {
        groups.first { $0.id == id }
    }

    /// The group named `name`, ignoring case and surrounding spaces.
    public func group(named name: String) -> StickerGroup? {
        guard let clean = StickerGroup.cleanName(name) else { return nil }
        return groups.first { $0.name.compare(clean, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    /// The groups `itemID` is in, in the groups' order.
    public func groups(containing itemID: UUID) -> [StickerGroup] {
        groups.filter { $0.contains(itemID) }
    }

    /// The groups, most recently used first (ties: their order).
    public var groupsByRecentUse: [StickerGroup] {
        groups.enumerated().sorted { lhs, rhs in
            if lhs.element.usedAt != rhs.element.usedAt { return lhs.element.usedAt > rhs.element.usedAt }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Whether `itemID` is in no group.
    public func isUngrouped(_ itemID: UUID) -> Bool {
        !groups.contains { $0.contains(itemID) }
    }

    /// Whether `filter` lets `itemID` through.
    public func passes(_ itemID: UUID, filter: StickerGroupFilter) -> Bool {
        switch filter {
        case .all: return true
        case let .group(id): return group(id: id)?.contains(itemID) ?? false
        case .ungrouped: return isUngrouped(itemID)
        }
    }

    /// Makes a group named `name` (one with that name already is reused); returns its id, nil for an empty name.
    @discardableResult
    public mutating func createGroup(named name: String, at date: Date = Date()) -> UUID? {
        guard let clean = StickerGroup.cleanName(name) else { return nil }
        if let existing = group(named: clean) { return existing.id }
        let group = StickerGroup(name: clean, usedAt: date)
        groups.append(group)
        return group.id
    }

    /// Renames the group; false for an empty name or a name another group has.
    @discardableResult
    public mutating func renameGroup(_ id: UUID, to name: String) -> Bool {
        guard let clean = StickerGroup.cleanName(name), let index = groups.firstIndex(where: { $0.id == id }) else {
            return false
        }
        if let other = group(named: clean), other.id != id { return false }
        groups[index].name = clean
        return true
    }

    /// Forgets the group; its stickers stay.
    public mutating func deleteGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
    }

    /// Puts a deleted group back where it was (Undo); its stickers that are gone since stay out.
    public mutating func restoreGroup(_ group: StickerGroup, at index: Int, keeping existing: Set<UUID>? = nil) {
        guard self.group(id: group.id) == nil else { return }
        var restored = group
        if let existing {
            restored.members = restored.members.filter { existing.contains($0) }
        }
        groups.insert(restored, at: max(0, min(index, groups.count)))
    }

    /// Puts `itemID` in the group (first) or takes it out.
    public mutating func setMember(_ itemID: UUID, in groupID: UUID, _ isMember: Bool, at date: Date = Date()) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let present = groups[index].members.contains(itemID)
        if isMember && !present {
            groups[index].members.insert(itemID, at: 0)
            groups[index].usedAt = date
        } else if !isMember && present {
            groups[index].members.removeAll { $0 == itemID }
        }
    }

    /// Puts `itemID` in the group, or takes it out when it is in; returns whether it is in now.
    @discardableResult
    public mutating func toggleMember(_ itemID: UUID, in groupID: UUID, at date: Date = Date()) -> Bool {
        guard let group = group(id: groupID) else { return false }
        let now = !group.contains(itemID)
        setMember(itemID, in: groupID, now, at: date)
        return now
    }
}
