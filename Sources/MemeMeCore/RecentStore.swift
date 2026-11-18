import Foundation

/// What was sent recently, per frontmost app and globally, newest first; what you saved (the star on a tile),
/// newest first; and the groups you put your stickers in.
public struct RecentStore: Codable, Equatable, Sendable {
    public private(set) var byApp: [String: [UUID]]
    /// Your things you saved, newest first (the Saved tab). Only your own: GIPHY's GIFs and the classic memes aren't
    /// kept.
    public private(set) var saved: [UUID]
    /// Your sticker groups, in the order they were made (the order of My Stickers' chips).
    public private(set) var groups: [StickerGroup]
    /// Suggested groups you turned down (`GroupSuggestion.key`), with how many stickers each had then: one comes back
    /// only once it has more.
    public private(set) var dismissedSuggestions: [String: Int]

    /// Key of the list that records every send regardless of app.
    public static let globalKey = "*"

    /// Maximum ids kept per list.
    private static let capacity = 30

    public init() {
        byApp = [:]
        saved = []
        groups = []
        dismissedSuggestions = [:]
    }

    public func isSaved(_ id: UUID) -> Bool {
        saved.contains(id)
    }

    /// Saves `id` (to the front) or, when it is saved, forgets it. Returns whether it is saved now.
    @discardableResult
    public mutating func toggleSaved(_ id: UUID) -> Bool {
        if let index = saved.firstIndex(of: id) {
            saved.remove(at: index)
            return false
        }
        saved.insert(id, at: 0)
        return true
    }

    /// Moves id to the front of the app's list and of the global list; each capped at 30.
    public mutating func record(_ id: UUID, appBundleID: String?) {
        if let app = appBundleID, !app.isEmpty, app != RecentStore.globalKey {
            moveToFront(id, key: app)
        }
        moveToFront(id, key: RecentStore.globalKey)
    }

    /// App list first, then global entries not already included.
    public func recent(appBundleID: String?) -> [UUID] {
        var ordered: [UUID] = []
        var seen = Set<UUID>()
        var keys: [String] = []
        if let app = appBundleID, !app.isEmpty, app != RecentStore.globalKey {
            keys.append(app)
        }
        keys.append(RecentStore.globalKey)
        for key in keys {
            for id in byApp[key] ?? [] {
                if seen.contains(id) { continue }
                seen.insert(id)
                ordered.append(id)
            }
        }
        return ordered
    }

    public mutating func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var updated: [String: [UUID]] = [:]
        for (key, list) in byApp {
            let remaining = list.filter { !ids.contains($0) }
            if !remaining.isEmpty { updated[key] = remaining }
        }
        byApp = updated
        saved.removeAll { ids.contains($0) }
        for index in groups.indices {
            groups[index].remove(ids)
        }
    }

    // MARK: Sticker groups

    public func group(id: UUID) -> StickerGroup? {
        groups.first { $0.id == id }
    }

    /// The group named `name`, ignoring case and surrounding white space.
    public func group(named name: String) -> StickerGroup? {
        guard let clean = StickerGroup.cleanName(name) else { return nil }
        return groups.first { $0.name.compare(clean, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    /// The groups `stickerID` is in, in the groups' order.
    public func groups(containing stickerID: UUID) -> [StickerGroup] {
        groups.filter { $0.contains(stickerID) }
    }

    /// Whether `stickerID` is in any group.
    public func isGrouped(_ stickerID: UUID) -> Bool {
        groups.contains { $0.contains(stickerID) }
    }

    /// Up to `limit` groups you file stickers in (not live ones), the latest used first (ties: the order they were
    /// made).
    public func recentGroups(limit: Int) -> [StickerGroup] {
        guard limit > 0 else { return [] }
        let ordered = groups.enumerated().filter { !$0.element.isLive }.sorted { lhs, rhs in
            if lhs.element.lastUsedAt != rhs.element.lastUsedAt { return lhs.element.lastUsedAt > rhs.element.lastUsedAt }
            return lhs.offset < rhs.offset
        }
        return Array(ordered.prefix(limit).map { $0.element })
    }

    /// Makes a group named `name` (after the others), or returns the one you file in already named so. A name a live
    /// group has makes a numbered one ("Cats 2"), since nothing can be filed in a live group. nil when the name is
    /// empty.
    @discardableResult
    public mutating func addGroup(named name: String, now: Date = Date()) -> StickerGroup? {
        if let existing = group(named: name), !existing.isLive { return existing }
        guard let clean = StickerGroup.cleanName(name) else { return nil }
        let made = StickerGroup(name: unusedName(like: clean), lastUsedAt: now)
        groups.append(made)
        return made
    }

    /// Saves a search as a live group named `name` (numbered when the name is taken: "Cats 2"). nil when the name or
    /// the words are empty.
    @discardableResult
    public mutating func addLiveGroup(named name: String, query: String, now: Date = Date()) -> StickerGroup? {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let clean = StickerGroup.cleanName(name), !words.isEmpty else { return nil }
        let made = StickerGroup(name: unusedName(like: clean), lastUsedAt: now, query: words)
        groups.append(made)
        return made
    }

    /// A suggested group turned down while it had `count` stickers.
    public mutating func dismissSuggestion(_ key: String, count: Int) {
        dismissedSuggestions[key] = max(count, dismissedSuggestions[key] ?? 0)
    }

    /// Renames the group; false when the name is empty or another group has it.
    @discardableResult
    public mutating func renameGroup(_ id: UUID, to name: String) -> Bool {
        guard let clean = StickerGroup.cleanName(name), let index = groups.firstIndex(where: { $0.id == id }) else {
            return false
        }
        if let other = group(named: clean), other.id != id { return false }
        groups[index].name = clean
        return true
    }

    /// Deletes the group (its stickers stay); returns it and where it was, for Undo (`restoreGroup`).
    @discardableResult
    public mutating func removeGroup(_ id: UUID) -> (group: StickerGroup, index: Int)? {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return nil }
        return (groups.remove(at: index), index)
    }

    /// Puts back a group `removeGroup` took out, where it was (stickers deleted since stay out of it).
    /// A group given the name since is left as it is: the restored one is numbered ("Work 2").
    public mutating func restoreGroup(_ group: StickerGroup, at index: Int, keeping existing: Set<UUID>? = nil) {
        guard self.group(id: group.id) == nil else { return }
        var restored = group
        if let existing {
            restored.remove(Set(group.stickerIDs).subtracting(existing))
        }
        restored.name = unusedName(like: group.name)
        groups.insert(restored, at: min(max(0, index), groups.count))
    }

    /// `name`, or the first of "name 2", "name 3"… no group has.
    private func unusedName(like name: String) -> String {
        guard group(named: name) != nil else { return name }
        var number = 2
        while true {
            let suffix = " \(number)"
            let candidate = String(name.prefix(StickerGroup.maxNameLength - suffix.count)) + suffix
            if group(named: candidate) == nil { return candidate }
            number += 1
        }
    }

    /// Files the sticker in the group (first), or takes it out. Filing it counts as using the group.
    public mutating func setSticker(_ stickerID: UUID, inGroup groupID: UUID, _ isIn: Bool, now: Date = Date()) {
        // Nothing is filed in a live group: its words pick its stickers.
        guard let index = groups.firstIndex(where: { $0.id == groupID }), !groups[index].isLive else { return }
        if isIn {
            groups[index].insert(stickerID)
            groups[index].lastUsedAt = now
        } else {
            groups[index].remove(stickerID)
        }
    }

    /// Files the sticker in the group, or takes it out when it is in it. Returns whether it is in it now.
    @discardableResult
    public mutating func toggleSticker(_ stickerID: UUID, inGroup groupID: UUID, now: Date = Date()) -> Bool {
        guard let group = group(id: groupID) else { return false }
        let isIn = !group.contains(stickerID)
        setSticker(stickerID, inGroup: groupID, isIn, now: now)
        return isIn
    }

    private mutating func moveToFront(_ id: UUID, key: String) {
        var list = byApp[key] ?? []
        list.removeAll { $0 == id }
        list.insert(id, at: 0)
        if list.count > RecentStore.capacity {
            list.removeLast(list.count - RecentStore.capacity)
        }
        byApp[key] = list
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case byApp, saved, groups, dismissedSuggestions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = container.decodeLenient([String: [UUID]].self, forKey: .byApp, default: [:])
        var capped: [String: [UUID]] = [:]
        for (key, list) in decoded where !list.isEmpty {
            capped[key] = Array(list.prefix(RecentStore.capacity))
        }
        byApp = capped
        var unique = Set<UUID>()
        saved = container.decodeLenient([UUID].self, forKey: .saved, default: []).filter { unique.insert($0).inserted }
        // Files from before groups have none.
        var groupIDs = Set<UUID>()
        // An unreadable group is dropped, not the others.
        groups = container.decodeLenient([LossyDecodable<StickerGroup>].self, forKey: .groups, default: [])
            .compactMap { $0.value }
            .filter { groupIDs.insert($0.id).inserted }
        dismissedSuggestions = container.decodeLenient([String: Int].self, forKey: .dismissedSuggestions, default: [:])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(byApp, forKey: .byApp)
        try container.encode(saved, forKey: .saved)
        try container.encode(groups, forKey: .groups)
        try container.encode(dismissedSuggestions, forKey: .dismissedSuggestions)
    }
}

/// The panel's "Frequent" row: your things sent most.
public enum FrequentPicks {
    /// Sent at least this often to count as frequent.
    public static let minimumSends = 2

    /// Up to `limit` of `items` sent at least `minimumSends` times, most sent first (ties: the latest sent first, then
    /// the name), leaving out `excluded` (what the row above already shows), GIPHY's and what isn't a meme.
    public static func pick(_ items: [LibraryItem], excluding excluded: Set<UUID> = [], limit: Int) -> [LibraryItem] {
        guard limit > 0 else { return [] }
        let candidates = items.filter { $0.kind != .web && $0.tier != .skipped && $0.timesSent >= minimumSends && !excluded.contains($0.id) }
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.timesSent != rhs.timesSent { return lhs.timesSent > rhs.timesSent }
            let left = lhs.lastSentAt ?? .distantPast
            let right = rhs.lastSentAt ?? .distantPast
            if left != right { return left > right }
            return lhs.displayName < rhs.displayName
        }
        return Array(ordered.prefix(limit))
    }
}
