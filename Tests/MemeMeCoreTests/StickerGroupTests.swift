import Foundation
import XCTest
@testable import MemeMeCore

final class StickerGroupTests: XCTestCase {
    private func decode(_ json: String) throws -> RecentStore {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecentStore.self, from: Data(json.utf8))
    }

    private func roundTrip(_ store: RecentStore) throws -> RecentStore {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecentStore.self, from: encoder.encode(store))
    }

    func testAddingGroupsKeepsTheirOrderAndReusesANameAlreadyTaken() {
        var store = RecentStore()
        let reactions = store.addGroup(named: "  Reactions ")
        let work = store.addGroup(named: "Work")
        XCTAssertEqual(store.groups.map(\.name), ["Reactions", "Work"])
        XCTAssertEqual(store.addGroup(named: "reactions")?.id, reactions?.id, "same name, any case: the same group")
        XCTAssertEqual(store.groups.count, 2)
        XCTAssertNil(store.addGroup(named: "   "))
        XCTAssertEqual(store.addGroup(named: "Sam   &\tJo")?.name, "Sam & Jo")
        XCTAssertNotEqual(reactions?.id, work?.id)
    }

    func testAStickerCanBeInSeveralGroupsLatestFiledFirst() throws {
        var store = RecentStore()
        let reactions = try XCTUnwrap(store.addGroup(named: "Reactions"))
        let work = try XCTUnwrap(store.addGroup(named: "Work"))
        let a = UUID(), b = UUID()
        store.setSticker(a, inGroup: reactions.id, true)
        store.setSticker(b, inGroup: reactions.id, true)
        store.setSticker(a, inGroup: work.id, true)
        store.setSticker(a, inGroup: work.id, true)

        XCTAssertEqual(store.group(id: reactions.id)?.stickerIDs, [b, a])
        XCTAssertEqual(store.group(id: work.id)?.stickerIDs, [a], "filed once")
        XCTAssertEqual(store.groups(containing: a).map(\.id), [reactions.id, work.id])
        XCTAssertTrue(store.isGrouped(b))
        XCTAssertFalse(store.isGrouped(UUID()))

        XCTAssertFalse(store.toggleSticker(a, inGroup: work.id))
        XCTAssertEqual(store.groups(containing: a).map(\.id), [reactions.id])
        XCTAssertTrue(store.toggleSticker(a, inGroup: work.id))
    }

    func testRecentGroupsAreTheLatestUsedFirst() throws {
        var store = RecentStore()
        let start = Date(timeIntervalSince1970: 1_000)
        let reactions = try XCTUnwrap(store.addGroup(named: "Reactions", now: start))
        let work = try XCTUnwrap(store.addGroup(named: "Work", now: start))
        let friends = try XCTUnwrap(store.addGroup(named: "Sam & Jo", now: start))
        XCTAssertEqual(store.recentGroups(limit: 3).map(\.id), [reactions.id, work.id, friends.id], "ties: the order made")

        store.setSticker(UUID(), inGroup: friends.id, true, now: start.addingTimeInterval(10))
        store.setSticker(UUID(), inGroup: work.id, true, now: start.addingTimeInterval(20))
        XCTAssertEqual(store.recentGroups(limit: 2).map(\.id), [work.id, friends.id])
        XCTAssertEqual(store.recentGroups(limit: 0), [])

        store.setSticker(UUID(), inGroup: reactions.id, false, now: start.addingTimeInterval(30))
        XCTAssertEqual(store.recentGroups(limit: 1).map(\.id), [work.id], "taking one out isn't using it")
    }

    func testRenamingRefusesAnEmptyNameOrOneAnotherGroupHas() throws {
        var store = RecentStore()
        let reactions = try XCTUnwrap(store.addGroup(named: "Reactions"))
        _ = store.addGroup(named: "Work")
        XCTAssertFalse(store.renameGroup(reactions.id, to: " "))
        XCTAssertFalse(store.renameGroup(reactions.id, to: "work"))
        XCTAssertTrue(store.renameGroup(reactions.id, to: "REACTIONS"), "its own name in another case is fine")
        XCTAssertTrue(store.renameGroup(reactions.id, to: "Faces"))
        XCTAssertEqual(store.groups.map(\.name), ["Faces", "Work"])
        XCTAssertFalse(store.renameGroup(UUID(), to: "Other"))
    }

    func testDeletingAGroupKeepsItsStickersAndUndoPutsItBack() throws {
        var store = RecentStore()
        let reactions = try XCTUnwrap(store.addGroup(named: "Reactions"))
        let work = try XCTUnwrap(store.addGroup(named: "Work"))
        let a = UUID(), b = UUID()
        store.setSticker(a, inGroup: reactions.id, true)
        store.setSticker(b, inGroup: reactions.id, true)
        store.record(a, appBundleID: nil)

        let removed = try XCTUnwrap(store.removeGroup(reactions.id))
        XCTAssertEqual(removed.index, 0)
        XCTAssertEqual(store.groups.map(\.id), [work.id])
        XCTAssertEqual(store.recent(appBundleID: nil), [a], "the stickers stay")
        XCTAssertNil(store.removeGroup(reactions.id))

        store.restoreGroup(removed.group, at: removed.index, keeping: [a])
        XCTAssertEqual(store.groups.map(\.id), [reactions.id, work.id])
        XCTAssertEqual(store.group(id: reactions.id)?.stickerIDs, [a], "a sticker deleted since stays out")
        store.restoreGroup(removed.group, at: 0)
        XCTAssertEqual(store.groups.count, 2, "restoring twice adds nothing")
    }

    func testRemovingStickersTakesThemOutOfTheirGroups() throws {
        var store = RecentStore()
        let reactions = try XCTUnwrap(store.addGroup(named: "Reactions"))
        let a = UUID(), b = UUID()
        store.setSticker(a, inGroup: reactions.id, true)
        store.setSticker(b, inGroup: reactions.id, true)
        store.remove([a])
        XCTAssertEqual(store.group(id: reactions.id)?.stickerIDs, [b])
        XCTAssertEqual(store.groups.count, 1, "an emptied group stays")
    }

    func testGroupsAreKeptInTheFile() throws {
        var store = RecentStore()
        let reactions = try XCTUnwrap(store.addGroup(named: "Reactions"))
        let a = UUID()
        store.setSticker(a, inGroup: reactions.id, true)
        store.toggleSaved(a)
        let loaded = try roundTrip(store)
        XCTAssertEqual(loaded.groups.map(\.name), ["Reactions"])
        XCTAssertEqual(loaded.group(id: reactions.id)?.stickerIDs, [a])
        XCTAssertEqual(loaded.saved, [a])
    }

    func testOlderFilesWithoutGroupsStillLoad() throws {
        let a = UUID()
        let store = try decode(#"{"byApp":{"*":["\#(a.uuidString)"]},"saved":["\#(a.uuidString)"]}"#)
        XCTAssertEqual(store.groups, [])
        XCTAssertEqual(store.saved, [a])
        XCTAssertEqual(store.recent(appBundleID: nil), [a])
    }

    func testAnUnreadableGroupIsDroppedNotTheOthers() throws {
        let id = UUID(), a = UUID()
        let json = """
        {"byApp":{},"saved":[],"groups":[
          {"name":"No id"},
          {"id":"\(id.uuidString)","name":"  Work ","stickerIDs":["\(a.uuidString)","\(a.uuidString)"]},
          {"id":"\(id.uuidString)","name":"Duplicate"}
        ]}
        """
        let store = try decode(json)
        XCTAssertEqual(store.groups.map(\.name), ["Work"])
        XCTAssertEqual(store.groups.first?.stickerIDs, [a])
        XCTAssertEqual(store.groups.first?.lastUsedAt, .distantPast)
    }
}

final class SectionedSlotsTests: XCTestCase {
    func testEachSectionStartsOnItsOwnRow() {
        // 5 to a row: a full row, a row of 3, then 2 more.
        let slots = SectionedSlots(columns: 5, counts: [5, 3, 2])
        XCTAssertEqual(slots.rows.counts, [5, 3, 2])
        XCTAssertEqual(slots.firstRows, [0, 1, 2])
        XCTAssertEqual(slots.firstPicks, [0, 5, 8])
        XCTAssertEqual(slots.pick(at: 4), 4)
        XCTAssertEqual(slots.pick(at: 5), 5)
        XCTAssertEqual(slots.pick(at: 7), 7)
        XCTAssertNil(slots.pick(at: 8), "the second row ends early")
        XCTAssertNil(slots.pick(at: 9))
        XCTAssertEqual(slots.pick(at: 10), 8)
        XCTAssertEqual(slots.pick(at: 11), 9)
        XCTAssertNil(slots.pick(at: 12))
        XCTAssertNil(slots.pick(at: -1))
        XCTAssertEqual(slots.slot(ofPick: 8), 10)
        XCTAssertNil(slots.slot(ofPick: 10))
    }

    func testALongSectionTakesSeveralRowsAndAnEmptyOneNone() {
        let slots = SectionedSlots(columns: 4, counts: [6, 0, 1])
        XCTAssertEqual(slots.rows.counts, [4, 2, 1])
        XCTAssertEqual(slots.firstRows, [0, 2, 2])
        XCTAssertEqual(slots.section(ofRow: 0), 0)
        XCTAssertEqual(slots.section(ofRow: 1), 0)
        XCTAssertEqual(slots.section(ofRow: 2), 2, "the empty section has no row")
        XCTAssertNil(slots.section(ofRow: 3))
        XCTAssertEqual(slots.pick(at: 8), 6)
    }

    func testArrowKeysSkipTheGapsWhereRowsEndEarly() {
        let slots = SectionedSlots(columns: 5, counts: [5, 3, 2])
        // Down from the last tile of the full row lands on the last tile of the short row.
        XCTAssertEqual(slots.rows.move(from: 4, dx: 0, dy: 1), 7)
        XCTAssertEqual(slots.rows.move(from: 7, dx: 1, dy: 0), nil, "nothing right of the short row's end")
        XCTAssertEqual(slots.rows.move(from: 7, dx: 0, dy: 1), 11)
    }

    func testOneSectionMatchesAPlainGrid() {
        let slots = SectionedSlots(columns: 5, counts: [12])
        XCTAssertEqual(slots.rows.counts, [5, 5, 2])
        for index in 0..<12 {
            XCTAssertEqual(slots.pick(at: index), index)
            XCTAssertEqual(slots.slot(ofPick: index), index)
        }
        XCTAssertNil(slots.pick(at: 12))
    }
}
