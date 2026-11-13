import Foundation

/// What was sent recently, per frontmost app and globally, newest first; and what you saved (the star on a tile),
/// newest first.
public struct RecentStore: Codable, Equatable, Sendable {
    public private(set) var byApp: [String: [UUID]]
    /// Your things you saved, newest first (the Saved tab). Only your own: GIPHY's GIFs and the classic memes aren't
    /// kept.
    public private(set) var saved: [UUID]

    /// Key of the list that records every send regardless of app.
    public static let globalKey = "*"

    /// Maximum ids kept per list.
    private static let capacity = 30

    public init() {
        byApp = [:]
        saved = []
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
        case byApp, saved
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
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(byApp, forKey: .byApp)
        try container.encode(saved, forKey: .saved)
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
