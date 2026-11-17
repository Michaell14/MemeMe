import Foundation
import XCTest
@testable import MemeMeCore

final class StickerGroupTests: XCTestCase {
    private let early = Date(timeIntervalSince1970: 1_000)
    private let late = Date(timeIntervalSince1970: 2_000)

    func testCreatingReusesANameAndIgnoresAnEmptyOne() throws {
        var store = RecentStore()
        let reactions = try XCTUnwrap(store.createGroup(named: "  Reactions ", at: early))
        XCTAssertEqual(store.group(id: reactions)?.name, "Reactions", "trimmed")
        XCTAssertEqual(store.createGroup(named: "reactions"), reactions, "the same name, any case, is the same group")
        XCTAssertNil(store.createGroup(named: "   "))
        XCTAssertEqual(store.groups.count, 1)
        let long = String(repeating: "a", count: 80)
        let capped = try XCTUnwrap(store.createGroup(named: long))
        XCTAssertEqual(store.group(id: capped)?.name.count, StickerGroup.maximumNameLength)
    }

    func testMembersComeAndGoAndAStickerCanBeInSeveralGroups() throws {
        var store = RecentStore()
        let reactions = try XCTUnwrap(store.createGroup(named: "Reactions", at: early))
        let work = try XCTUnwrap(store.createGroup(named: "Work", at: early))
        let first = UUID()
        let second = UUID()

        XCTAssertTrue(store.isUngrouped(first))
        XCTAssertTrue(store.toggleMember(first, in: reactions, at: late))
        store.setMember(second, in: reactions, true)
        store.setMember(first, in: work, true)
        XCTAssertEqual(store.group(id: reactions)?.members, [second, first], "newest first")
        XCTAssertEqual(store.groups(containing: first).map(\.id), [reactions, work])
        XCTAssertFalse(store.isUngrouped(first))

        XCTAssertFalse(store.toggleMember(first, in: reactions))
        XCTAssertEqual(store.group(id: reactions)?.members, [second])
        store.setMember(second, in: reactions, true)
        XCTAssertEqual(store.group(id: reactions)?.members, [second], "never twice")
    }

    func testFilters() throws {
        var store = RecentStore()
        let reactions = try XCTUnwrap(store.createGroup(named: "Reactions"))
        let inside = UUID()
        let outside = UUID()
        store.setMember(inside, in: reactions, true)
        XCTAssertTrue(store.passes(inside, filter: .all))
        XCTAssertTrue(store.passes(outside, filter: .all))
        XCTAssertTrue(store.passes(inside, filter: .group(reactions)))
        XCTAssertFalse(store.passes(outside, filter: .group(reactions)))
        XCTAssertFalse(store.passes(inside, filter: .ungrouped))
        XCTAssertTrue(store.passes(outside, filter: .ungrouped))
        XCTAssertFalse(store.passes(inside, filter: .group(UUID())), "a group that's gone shows nothing")
    }

    func testMostRecentlyUsedComesFirst() throws {
        var store = RecentStore()
        let reactions = try XCTUnwrap(store.createGroup(named: "Reactions", at: early))
        let work = try XCTUnwrap(store.createGroup(named: "Work", at: early))
        XCTAssertEqual(store.groupsByRecentUse.map(\.id), [reactions, work], "ties keep their order")
        store.setMember(UUID(), in: work, true, at: late)
        XCTAssertEqual(store.groupsByRecentUse.map(\.id), [work, reactions])
        XCTAssertEqual(store.groups.map(\.id), [reactions, work], "the chips keep the order they were made in")
    }

    func testRenameAndDelete() throws {
        var store = RecentStore()
        let reactions = try XCTUnwrap(store.createGroup(named: "Reactions"))
        let work = try XCTUnwrap(store.createGroup(named: "Work"))
        let item = UUID()
        store.setMember(item, in: work, true)
        XCTAssertTrue(store.renameGroup(reactions, to: "Feelings"))
        XCTAssertEqual(store.group(id: reactions)?.name, "Feelings")
        XCTAssertFalse(store.renameGroup(reactions, to: "work"), "another group has that name")
        XCTAssertFalse(store.renameGroup(reactions, to: " "))
        XCTAssertTrue(store.renameGroup(work, to: "WORK"), "a group may change its own name's case")

        let deleted = try XCTUnwrap(store.group(id: work))
        store.deleteGroup(work)
        XCTAssertNil(store.group(id: work))
        XCTAssertTrue(store.isUngrouped(item), "its stickers stay, in no group")

        store.restoreGroup(deleted, at: 1, keeping: [])
        XCTAssertEqual(store.groups.map(\.id), [reactions, work], "Undo puts it back where it was")
        XCTAssertEqual(store.group(id: work)?.members, [], "a sticker deleted since stays out")
    }

    func testRemovedItemsLeaveTheirGroups() throws {
        var store = RecentStore()
        let reactions = try XCTUnwrap(store.createGroup(named: "Reactions"))
        let gone = UUID()
        let kept = UUID()
        store.setMember(gone, in: reactions, true)
        store.setMember(kept, in: reactions, true)
        store.remove([gone])
        XCTAssertEqual(store.group(id: reactions)?.members, [kept])
    }

    func testCodableRoundTripAndOlderFiles() throws {
        var store = RecentStore()
        let reactions = try XCTUnwrap(store.createGroup(named: "Reactions", at: early))
        store.setMember(UUID(), in: reactions, true, at: late)
        let data = try JSONEncoder().encode(store)
        XCTAssertEqual(try JSONDecoder().decode(RecentStore.self, from: data), store)
        let older = Data("{\"byApp\": {}, \"saved\": []}".utf8)
        XCTAssertTrue(try JSONDecoder().decode(RecentStore.self, from: older).groups.isEmpty)
    }
}
