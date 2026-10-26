import Foundation

/// What was sent recently, per frontmost app and globally, newest first.
public struct RecentStore: Codable, Equatable, Sendable {
    public private(set) var byApp: [String: [UUID]]

    /// Key of the list that records every send regardless of app.
    public static let globalKey = "*"

    /// Maximum ids kept per list.
    private static let capacity = 30

    public init() {
        byApp = [:]
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
        case byApp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = container.decodeLenient([String: [UUID]].self, forKey: .byApp, default: [:])
        var capped: [String: [UUID]] = [:]
        for (key, list) in decoded where !list.isEmpty {
            capped[key] = Array(list.prefix(RecentStore.capacity))
        }
        byApp = capped
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(byApp, forKey: .byApp)
    }
}
