import Foundation

/// A group MemeMe offers to make in My Stickers from what it already knows about your stickers, all on this Mac: the
/// same named friend's face, the word your face was read as at Clip me ("You — shocked"), or the app a screen cut came
/// from.
public struct GroupSuggestion: Equatable, Identifiable, Sendable {
    /// Stable across launches ("person:<id>", "word:shocked", "app:slack"), so a dismissed one stays dismissed.
    public let key: String
    /// The group's name: "Sam", "Shocked", "From Slack".
    public let name: String
    /// Why it is offered: "4 stickers of Sam", "5 read as “shocked”", "3 cut from Slack".
    public let reason: String
    /// Its stickers, newest first.
    public let stickerIDs: [UUID]

    public var id: String { key }

    public init(key: String, name: String, reason: String, stickerIDs: [UUID]) {
        self.key = key
        self.name = name
        self.reason = reason
        self.stickerIDs = stickerIDs
    }

    /// Fewer stickers than this make no suggestion.
    public static let minimumStickers = 3

    /// Up to `limit` suggestions for `items` (your stickers among them), the biggest first (ties: by key). None is
    /// offered when a group already has its name, or holds every one of its stickers; nor one turned down
    /// (`dismissed`) until it has more stickers than it had then.
    /// `groups`: your groups' names and members (live groups' members worked out from the library).
    public static func suggest(items: [LibraryItem], people: [Person], groups: [(name: String, members: Set<UUID>)],
                               dismissed: [String: Int], limit: Int = 3) -> [GroupSuggestion] {
        guard limit > 0 else { return [] }
        let stickers = items.filter { $0.isSticker && $0.kind != .web }
            .sorted { lhs, rhs in
                if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        var candidates: [GroupSuggestion] = []

        // The same named friend.
        var byPerson: [UUID: [UUID]] = [:]
        for sticker in stickers {
            if let personID = sticker.personID { byPerson[personID, default: []].append(sticker.id) }
        }
        for person in people {
            guard let name = person.name.flatMap(StickerGroup.cleanName), let ids = byPerson[person.id] else { continue }
            candidates.append(GroupSuggestion(key: "person:\(person.id.uuidString)", name: name,
                                              reason: "\(ids.count) stickers of \(name)", stickerIDs: ids))
        }

        // The word your face was read as: "You — shocked".
        var byWord: [String: [UUID]] = [:]
        for sticker in stickers where sticker.source == "Camera" {
            guard let word = moodWord(in: sticker.displayName) else { continue }
            byWord[word, default: []].append(sticker.id)
        }
        for (word, ids) in byWord {
            let name = word.prefix(1).uppercased() + word.dropFirst()
            candidates.append(GroupSuggestion(key: "word:\(word)", name: name,
                                              reason: "\(ids.count) read as “\(word)”", stickerIDs: ids))
        }

        // The app a screen cut came from.
        var byApp: [String: (spellings: [String: Int], ids: [UUID])] = [:]
        for sticker in stickers where sticker.source == "Screen" {
            guard let app = sticker.sourceDetail?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty else { continue }
            let key = app.lowercased()
            byApp[key, default: ([:], [])].ids.append(sticker.id)
            byApp[key, default: ([:], [])].spellings[app, default: 0] += 1
        }
        for (key, entry) in byApp {
            // The app's name as it was seen most ("Slack" over one "slack").
            let app = entry.spellings.max { lhs, rhs in
                lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
            }?.key ?? key
            guard let name = StickerGroup.cleanName("From \(app)") else { continue }
            candidates.append(GroupSuggestion(key: "app:\(key)", name: name,
                                              reason: "\(entry.ids.count) cut from \(app)", stickerIDs: entry.ids))
        }

        let takenNames = Set(groups.map { $0.name.lowercased() })
        let kept = candidates.filter { suggestion in
            let count = suggestion.stickerIDs.count
            guard count >= minimumStickers else { return false }
            if let before = dismissed[suggestion.key], count <= before { return false }
            if takenNames.contains(suggestion.name.lowercased()) { return false }
            let ids = Set(suggestion.stickerIDs)
            return !groups.contains { ids.isSubset(of: $0.members) }
        }
        let ordered = kept.sorted { lhs, rhs in
            if lhs.stickerIDs.count != rhs.stickerIDs.count { return lhs.stickerIDs.count > rhs.stickerIDs.count }
            return lhs.key < rhs.key
        }
        return Array(ordered.prefix(limit))
    }

    /// "shocked" from "You — shocked" (the word after an em dash, lowercased); nil without one.
    static func moodWord(in name: String) -> String? {
        guard let range = name.range(of: " — ", options: .backwards) else { return nil }
        let word = name[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return word.isEmpty ? nil : word
    }
}
