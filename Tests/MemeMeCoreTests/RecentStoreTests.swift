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

    func testCodableRoundTrip() throws {
        var store = RecentStore()
        store.record(UUID(), appBundleID: slack)
        store.record(UUID(), appBundleID: messages)
        let data = try JSONEncoder().encode(store)
        XCTAssertEqual(try JSONDecoder().decode(RecentStore.self, from: data), store)
        XCTAssertEqual(try JSONDecoder().decode(RecentStore.self, from: Data("{}".utf8)), RecentStore())
    }
}
