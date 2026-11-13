import Foundation
import XCTest
@testable import MemeMeCore

final class RecentStoreTests: XCTestCase {
    private let slack = "com.tinyspeck.slackmacgap"
    private let messages = "com.apple.MobileSMS"

    func testGlobalKey() {
        XCTAssertEqual(RecentStore.globalKey, "*")
        XCTAssertTrue(RecentStore().byApp.isEmpty)
    }

    func testRecordKeepsNewestFirstPerAppAndGlobally() {
        var store = RecentStore()
        let a = UUID(), b = UUID(), c = UUID()
        store.record(a, appBundleID: slack)
        store.record(b, appBundleID: messages)
        store.record(c, appBundleID: slack)

        XCTAssertEqual(store.byApp[slack] ?? [], [c, a])
        XCTAssertEqual(store.byApp[messages] ?? [], [b])
        XCTAssertEqual(store.byApp[RecentStore.globalKey] ?? [], [c, b, a])

        XCTAssertEqual(store.recent(appBundleID: slack), [c, a, b])
        XCTAssertEqual(store.recent(appBundleID: messages), [b, c, a])
        XCTAssertEqual(store.recent(appBundleID: nil), [c, b, a])
        XCTAssertEqual(store.recent(appBundleID: "com.example.unknown"), [c, b, a])
    }

    func testRecordingAgainMovesToTheFront() {
        var store = RecentStore()
        let a = UUID(), b = UUID()
        store.record(a, appBundleID: slack)
        store.record(b, appBundleID: slack)
        store.record(a, appBundleID: slack)
        XCTAssertEqual(store.byApp[slack] ?? [], [a, b])
        XCTAssertEqual(store.byApp[RecentStore.globalKey] ?? [], [a, b])
    }

    func testWithoutAnAppOnlyTheGlobalListIsUpdated() {
        var store = RecentStore()
        let a = UUID()
        store.record(a, appBundleID: nil)
        store.record(a, appBundleID: "")
        XCTAssertEqual(Array(store.byApp.keys), [RecentStore.globalKey])
        XCTAssertEqual(store.recent(appBundleID: nil), [a])
    }

    func testEachListIsCappedAtThirty() {
        var store = RecentStore()
        let ids = (0..<35).map { _ in UUID() }
        for id in ids {
            store.record(id, appBundleID: slack)
        }
        let appList = store.byApp[slack] ?? []
        let globalList = store.byApp[RecentStore.globalKey] ?? []
        XCTAssertEqual(appList.count, 30)
        XCTAssertEqual(globalList.count, 30)
        XCTAssertEqual(appList.first, ids[34])
        XCTAssertEqual(appList.last, ids[5])
        XCTAssertEqual(store.recent(appBundleID: slack), Array(ids.reversed().prefix(30)))
    }

    func testRemoveDropsIdsFromEveryList() {
        var store = RecentStore()
        let a = UUID(), b = UUID()
        store.record(a, appBundleID: slack)
        store.record(b, appBundleID: messages)
        store.remove([a])
        XCTAssertNil(store.byApp[slack])
        XCTAssertEqual(store.byApp[RecentStore.globalKey] ?? [], [b])
        XCTAssertEqual(store.recent(appBundleID: slack), [b])
        store.remove([])
        XCTAssertEqual(store.recent(appBundleID: messages), [b])
    }

    func testSavingTogglesAndKeepsTheNewestFirst() {
        var store = RecentStore()
        let a = UUID(), b = UUID()
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertTrue(store.toggleSaved(a))
        XCTAssertTrue(store.toggleSaved(b))
        XCTAssertEqual(store.saved, [b, a])
        XCTAssertTrue(store.isSaved(a))
        XCTAssertFalse(store.toggleSaved(a), "the star again takes it out")
        XCTAssertFalse(store.isSaved(a))
        XCTAssertEqual(store.saved, [b])
        store.remove([b])
        XCTAssertTrue(store.saved.isEmpty, "a deleted item is no longer saved")
    }

    func testFrequentIsWhatYouSentMostLeavingOutTheRowAbove() {
        func sent(_ name: String, _ times: Int, daysAgo: Double = 0, kind: ItemKind = .mine,
                  tier: ItemTier = .meme) -> LibraryItem {
            var item = makeItem(name: name, kind: kind, tier: tier)
            item.timesSent = times
            item.lastSentAt = Date(timeIntervalSince1970: 1_000_000 - daysAgo * 86_400)
            return item
        }
        let shocked = sent("shocked", 14)
        let jaw = sent("jaw", 9)
        let blown = sent("blown", 6, daysAgo: 3)
        let gasp = sent("gasp", 6, daysAgo: 1)
        let once = sent("once", 1)
        let giphy = sent("giphy", 30, kind: .web)
        let skipped = sent("skipped", 20, tier: .skipped)
        let items = [once, blown, gasp, giphy, jaw, shocked, skipped]

        XCTAssertEqual(FrequentPicks.pick(items, limit: 4).map(\.id), [shocked.id, jaw.id, gasp.id, blown.id],
                       "most sent first; a tie goes to the latest sent")
        XCTAssertEqual(FrequentPicks.pick(items, excluding: [jaw.id], limit: 2).map(\.id), [shocked.id, gasp.id])
        XCTAssertTrue(FrequentPicks.pick(items, limit: 0).isEmpty)
        XCTAssertTrue(FrequentPicks.pick([once], limit: 4).isEmpty, "sent once isn't frequent")
    }

    func testCodableRoundTrip() throws {
        var store = RecentStore()
        store.record(UUID(), appBundleID: slack)
        store.record(UUID(), appBundleID: messages)
        store.toggleSaved(UUID())
        let data = try JSONEncoder().encode(store)
        XCTAssertEqual(try JSONDecoder().decode(RecentStore.self, from: data), store)
        XCTAssertEqual(try JSONDecoder().decode(RecentStore.self, from: Data("{}".utf8)), RecentStore())
        let id = UUID()
        let older = Data("{\"byApp\": {}, \"saved\": [\"\(id.uuidString)\", \"\(id.uuidString)\"]}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(RecentStore.self, from: older).saved, [id], "a repeated id is kept once")
    }
}
