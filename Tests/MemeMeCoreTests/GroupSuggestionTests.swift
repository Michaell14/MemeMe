import Foundation
import XCTest
@testable import MemeMeCore

final class GroupSuggestionTests: XCTestCase {
    private func sticker(_ name: String, source: String = "Camera", detail: String? = nil, person: UUID? = nil,
                         day: Double = 0, text: String = "", labels: [String] = []) -> LibraryItem {
        LibraryItem(fileURL: URL(fileURLWithPath: "/tmp/\(name).png"), displayName: name, kind: person == nil ? .mine : .friend,
                    source: source, sourceDetail: detail, addedAt: Date(timeIntervalSince1970: 1_000_000 + day * 86_400),
                    contentHash: "hash-\(name)-\(day)", isSticker: true, text: text, labels: labels, personID: person)
    }

    func testFacesMoodsAndAppsMakeSuggestionsBiggestFirst() {
        let sam = Person(name: "Sam")
        let items = [
            sticker("Sam 1", source: "Friend sticker", person: sam.id, day: 1),
            sticker("Sam 2", source: "Friend sticker", person: sam.id, day: 2),
            sticker("Sam 3", source: "Friend sticker", person: sam.id, day: 3),
            sticker("You — shocked", day: 4), sticker("You — Shocked", day: 5), sticker("You — shocked", day: 6),
            sticker("You — shocked", day: 7),
            sticker("LGTM", source: "Screen", detail: "Slack", day: 8), sticker("Nope", source: "Screen", detail: "Slack", day: 9),
            sticker("Same", source: "Screen", detail: "slack", day: 10),
            sticker("You — happy", day: 11), sticker("You — happy", day: 12)
        ]
        let found = GroupSuggestion.suggest(items: items, people: [sam], groups: [], dismissed: [:], limit: 5)
        XCTAssertEqual(found.map(\.name), ["Shocked", "From Slack", "Sam"], "two happy faces are too few")
        XCTAssertEqual(found.first?.reason, "4 read as “shocked”")
        XCTAssertEqual(found.first?.stickerIDs.first, items[6].id, "newest first")
        XCTAssertEqual(found.last?.reason, "3 stickers of Sam")
        XCTAssertEqual(GroupSuggestion.suggest(items: items, people: [sam], groups: [], dismissed: [:], limit: 1).count, 1)
    }

    func testAGroupWithTheNameOrTheStickersAlreadyThereHidesIt() {
        let items = (0..<3).map { sticker("You — shocked", day: Double($0)) }
        XCTAssertEqual(GroupSuggestion.suggest(items: items, people: [], groups: [], dismissed: [:]).count, 1)
        XCTAssertTrue(GroupSuggestion.suggest(items: items, people: [], groups: [("shocked", [])], dismissed: [:]).isEmpty)
        let all = Set(items.map(\.id))
        XCTAssertTrue(GroupSuggestion.suggest(items: items, people: [], groups: [("Faces", all)], dismissed: [:]).isEmpty)
        let some = Set(items.prefix(2).map(\.id))
        XCTAssertEqual(GroupSuggestion.suggest(items: items, people: [], groups: [("Faces", some)], dismissed: [:]).count, 1)
    }

    func testATurnedDownSuggestionComesBackOnlyWhenItGrows() {
        var items = (0..<3).map { sticker("You — shocked", day: Double($0)) }
        var recents = RecentStore()
        recents.dismissSuggestion("word:shocked", count: 3)
        XCTAssertTrue(GroupSuggestion.suggest(items: items, people: [], groups: [], dismissed: recents.dismissedSuggestions).isEmpty)
        items.append(sticker("You — shocked", day: 9))
        XCTAssertEqual(GroupSuggestion.suggest(items: items, people: [], groups: [], dismissed: recents.dismissedSuggestions)
            .first?.stickerIDs.count, 4)
    }

    func testLiveGroupsHoldWhatTheirWordsMatch() throws {
        let sam = Person(name: "Sam")
        let cat = sticker("Judging Cat", day: 1)
        let label = sticker("Loaf", day: 2, labels: ["cat"])
        let text = sticker("Words", day: 3, text: "CAT MODE")
        let dog = sticker("Dog", day: 4)
        let samSticker = sticker("Sam — lol", source: "Friend sticker", person: sam.id, day: 5)
        let meme = LibraryItem(fileURL: URL(fileURLWithPath: "/tmp/cat.png"), displayName: "cat meme", kind: .mine,
                               source: "Downloads", contentHash: "hash-meme")
        let items = [cat, label, text, dog, samSticker, meme]

        var recents = RecentStore()
        let cats = try XCTUnwrap(recents.addLiveGroup(named: "Cats", query: "  cat "))
        XCTAssertTrue(cats.isLive)
        XCTAssertEqual(cats.query, "cat")
        XCTAssertEqual(cats.members(in: items, people: [sam]), [text.id, label.id, cat.id],
                       "name, labels or text; stickers only, newest first")
        let friend = try XCTUnwrap(recents.addLiveGroup(named: "Sam", query: "sam"))
        XCTAssertEqual(friend.members(in: items, people: [sam]), [samSticker.id], "a friend's name filters by their face")
        XCTAssertNil(recents.addLiveGroup(named: "Empty", query: "  "))
        XCTAssertEqual(recents.addLiveGroup(named: "cats", query: "kitten")?.name, "cats 2", "a taken name is numbered")

        recents.setSticker(dog.id, inGroup: cats.id, true)
        XCTAssertEqual(recents.group(id: cats.id)?.stickerIDs, [], "nothing is filed in a live group")
        _ = recents.addGroup(named: "Work")
        XCTAssertEqual(recents.recentGroups(limit: 5).map(\.name), ["Work"], "only groups you file stickers in")
    }

    func testLiveGroupsAndDismissalsAreKeptInTheFile() throws {
        var recents = RecentStore()
        _ = recents.addLiveGroup(named: "Cats", query: "cat")
        _ = recents.addGroup(named: "Work")
        recents.dismissSuggestion("app:slack", count: 4)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode(RecentStore.self, from: encoder.encode(recents))
        XCTAssertEqual(loaded.groups.map(\.query), ["cat", nil])
        XCTAssertEqual(loaded.dismissedSuggestions, ["app:slack": 4])
    }

    func testMoodWordIsTheWordAfterTheDash() {
        XCTAssertEqual(GroupSuggestion.moodWord(in: "You — Shocked "), "shocked")
        XCTAssertEqual(GroupSuggestion.moodWord(in: "You — tongue out"), "tongue out")
        XCTAssertNil(GroupSuggestion.moodWord(in: "You"))
    }
}
