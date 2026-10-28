import Foundation
import XCTest
@testable import MemeMeCore

final class LibraryStoreTests: XCTestCase {
    private var sandbox = FileManager.default.temporaryDirectory

    private var root: URL {
        sandbox.appendingPathComponent("Root", isDirectory: true)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemeMeCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true, attributes: nil)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
        try super.tearDownWithError()
    }

    private func fileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    func testInitCreatesTheDirectoryAndStartsEmpty() throws {
        let store = try LibraryStore(rootURL: root)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(store.rootURL, root)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.people.isEmpty)
        XCTAssertEqual(store.recents, RecentStore())
        XCTAssertEqual(store.settings, AppSettings())
        XCTAssertFalse(store.isDirty)
    }

    func testAddLooksUpAndRejectsDuplicateHashes() throws {
        let store = try LibraryStore(rootURL: root)
        let item = makeItem(name: "cat", hash: "hash-1", fileURL: URL(fileURLWithPath: "/tmp/memes/cat.png"))
        XCTAssertTrue(store.add(item))
        XCTAssertTrue(store.isDirty)
        XCTAssertTrue(store.contains(hash: "hash-1"))
        XCTAssertFalse(store.contains(hash: "hash-2"))
        XCTAssertEqual(store.item(id: item.id), item)
        XCTAssertNil(store.item(id: UUID()))
        XCTAssertEqual(store.item(atPath: "/tmp/memes/cat.png"), item)
        XCTAssertEqual(store.item(atPath: "/tmp/memes/./cat.png"), item)
        XCTAssertNil(store.item(atPath: "/tmp/memes/dog.png"))

        let duplicate = makeItem(name: "cat copy", hash: "hash-1")
        XCTAssertFalse(store.add(duplicate))
        XCTAssertFalse(store.add(item))
        XCTAssertEqual(store.items.count, 1)
        XCTAssertNil(store.item(id: duplicate.id))
    }

    func testSaveAndReloadRoundTrip() throws {
        let store = try LibraryStore(rootURL: root)
        let maya = Person(name: "Maya", embeddings: [[0.5, 1], [0.25, -2]], createdAt: TestDates.march15)
        let sticker = makeItem(name: "Maya — happy", kind: .friend, source: "Friend sticker", sourceDetail: "IMG_2207.HEIC",
                               addedAt: TestDates.march20, isSticker: true, face: TestFaces.smile, intensity: 0.4,
                               featurePrint: [1, 2, 3], labels: ["person"], personID: maya.id, timesSent: 2,
                               lastSentAt: TestDates.september5)
        let meme = makeItem(name: "dancing cat", sourceDetail: "from reddit.com", modified: TestDates.february10, isAnimated: true)
        XCTAssertTrue(store.add(sticker))
        XCTAssertTrue(store.add(meme))
        store.upsert(maya)
        store.recents.record(sticker.id, appBundleID: "com.apple.MobileSMS")
        store.settings.groupFaces = true
        store.settings.watchedFolders = ["/Users/me/Downloads"]
        store.settings.collectingPausedUntil = TestDates.september5
        XCTAssertTrue(store.isDirty)

        try store.save()
        XCTAssertFalse(store.isDirty)
        for name in ["library.json", "people.json", "recents.json", "settings.json"] {
            XCTAssertTrue(fileExists(name), name)
        }

        let reloaded = try LibraryStore(rootURL: root)
        XCTAssertEqual(reloaded.items, [sticker, meme])
        XCTAssertEqual(reloaded.people, [maya])
        XCTAssertEqual(reloaded.recents, store.recents)
        XCTAssertEqual(reloaded.settings, store.settings)
        XCTAssertEqual(reloaded.settings.groupFaces, true)
        XCTAssertFalse(reloaded.isDirty)
        XCTAssertEqual(reloaded.item(id: meme.id), meme)
        XCTAssertTrue(reloaded.contains(hash: sticker.contentHash))
        XCTAssertEqual(reloaded.stickerCount(personID: maya.id), 1)
    }

    func testSavedJSONHasSortedKeysAndISODates() throws {
        let store = try LibraryStore(rootURL: root)
        store.add(makeItem(name: "x", addedAt: TestDates.march20))
        try store.save()
        let text = try String(contentsOf: root.appendingPathComponent("library.json"), encoding: .utf8)
        XCTAssertTrue(text.contains("\"addedAt\":\"2026-03-20T09:00:00Z\""), text)
        let addedAt = try XCTUnwrap(text.range(of: "\"addedAt\""))
        let contentHash = try XCTUnwrap(text.range(of: "\"contentHash\""))
        let displayName = try XCTUnwrap(text.range(of: "\"displayName\""))
        XCTAssertLessThan(addedAt.lowerBound, contentHash.lowerBound)
        XCTAssertLessThan(contentHash.lowerBound, displayName.lowerBound)
    }

    func testUpdateReplacesByID() throws {
        let store = try LibraryStore(rootURL: root)
        var item = makeItem(name: "old", hash: "h1", fileURL: URL(fileURLWithPath: "/tmp/memes/old.png"))
        store.add(item)
        try store.save()

        item.displayName = "new"
        item.contentHash = "h2"
        item.fileURL = URL(fileURLWithPath: "/tmp/memes/new.png")
        store.update(item)
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.item(id: item.id)?.displayName, "new")
        XCTAssertTrue(store.contains(hash: "h2"))
        XCTAssertFalse(store.contains(hash: "h1"))
        XCTAssertNil(store.item(atPath: "/tmp/memes/old.png"))
        XCTAssertEqual(store.item(atPath: "/tmp/memes/new.png")?.id, item.id)

        store.update(makeItem(name: "stranger"))     // unknown id: ignored
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.displayName, "new")
    }

    func testRemoveDeletesOnlyFilesInsideTheLibraryFolder() throws {
        let store = try LibraryStore(rootURL: root)
        let keptFile = store.keptDirectory.appendingPathComponent("kept.png")
        let downloads = sandbox.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true, attributes: nil)
        let downloadedFile = downloads.appendingPathComponent("download.png")
        try Data([1, 2, 3]).write(to: keptFile)
        try Data([4, 5, 6]).write(to: downloadedFile)

        let kept = makeItem(name: "kept", source: "Kept", fileURL: keptFile)
        let downloaded = makeItem(name: "download", fileURL: downloadedFile)
        let other = makeItem(name: "other")
        store.add(kept)
        store.add(downloaded)
        store.add(other)
        store.recents.record(kept.id, appBundleID: "app")
        store.recents.record(other.id, appBundleID: "app")
        try store.save()

        store.remove(ids: [kept.id, downloaded.id])
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(store.items.map { $0.id }, [other.id])
        XCTAssertNil(store.item(id: kept.id))
        XCTAssertNil(store.item(atPath: downloadedFile.path))
        XCTAssertEqual(store.item(id: other.id), other)
        XCTAssertFalse(store.contains(hash: kept.contentHash))
        XCTAssertFalse(FileManager.default.fileExists(atPath: keptFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadedFile.path))
        XCTAssertEqual(store.recents.recent(appBundleID: "app"), [other.id])
    }

    func testRemoveSavedWebItemsForgetsSentGIPHYPicksAndTheSentFolder() throws {
        let store = try LibraryStore(rootURL: root)
        let sent = store.legacySentDirectory
        try FileManager.default.createDirectory(at: sent, withIntermediateDirectories: true, attributes: nil)
        let sentStill = sent.appendingPathComponent("abc-still.gif")
        try Data([1, 2, 3]).write(to: sentStill)
        let pick = makeItem(name: "giphy pick", kind: .web, source: "GIPHY", hash: "giphy:abc", fileURL: sentStill)
        let mislabeled = makeItem(name: "old pick", hash: "giphy:def")
        let own = makeItem(name: "own")
        store.add(pick)
        store.add(mislabeled)
        store.add(own)
        store.recents.record(pick.id, appBundleID: "app")
        store.recents.record(own.id, appBundleID: "app")
        try store.save()

        XCTAssertEqual(store.removeSavedWebItems(), 2)
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(store.items.map { $0.id }, [own.id])
        XCTAssertFalse(store.contains(hash: "giphy:abc"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentStill.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sent.path))
        XCTAssertEqual(store.recents.recent(appBundleID: "app"), [own.id])

        try store.save()
        let reloaded = try LibraryStore(rootURL: root)
        XCTAssertEqual(reloaded.items.map { $0.id }, [own.id])
        XCTAssertEqual(reloaded.removeSavedWebItems(), 0, "nothing left to remove")
    }

    func testRemoveSavedWebItemsKeepsASentFolderStillInUse() throws {
        let store = try LibraryStore(rootURL: root)
        let sent = store.legacySentDirectory
        try FileManager.default.createDirectory(at: sent, withIntermediateDirectories: true, attributes: nil)
        let ownFile = sent.appendingPathComponent("mine.png")
        try Data([1]).write(to: ownFile)
        store.add(makeItem(name: "mine", fileURL: ownFile))
        store.add(makeItem(name: "pick", kind: .web, hash: "giphy:x"))

        XCTAssertEqual(store.removeSavedWebItems(), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sent.path), "a library file still lives there")
    }

    func testRemovingUnknownIDsChangesNothing() throws {
        let store = try LibraryStore(rootURL: root)
        store.add(makeItem(name: "a"))
        try store.save()
        store.remove(ids: [UUID()])
        store.remove(ids: [])
        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(store.items.count, 1)
    }

    func testUpsertReplacesAnExistingPerson() throws {
        let store = try LibraryStore(rootURL: root)
        var person = Person()
        store.upsert(person)
        person.name = "Maya"
        store.upsert(person)
        XCTAssertEqual(store.people.count, 1)
        XCTAssertEqual(store.people.first?.name, "Maya")
        store.upsert(Person(name: "Jordan"))
        XCTAssertEqual(store.people.count, 2)
    }

    func testRemovePersonClearsLinksAndStickerCounts() throws {
        let store = try LibraryStore(rootURL: root)
        let maya = Person(name: "Maya")
        let jordan = Person(name: "Jordan")
        store.upsert(maya)
        store.upsert(jordan)
        store.add(makeItem(name: "m1", kind: .friend, isSticker: true, personID: maya.id))
        store.add(makeItem(name: "m2", kind: .friend, isSticker: true, personID: maya.id))
        store.add(makeItem(name: "j1", kind: .friend, isSticker: true, personID: jordan.id))
        XCTAssertEqual(store.stickerCount(personID: maya.id), 2)
        XCTAssertEqual(store.stickerCount(personID: jordan.id), 1)
        try store.save()

        store.removePerson(id: maya.id)
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(store.people.map { $0.id }, [jordan.id])
        XCTAssertEqual(store.items.count, 3)
        XCTAssertEqual(store.stickerCount(personID: maya.id), 0)
        XCTAssertEqual(store.stickerCount(personID: jordan.id), 1)
        XCTAssertEqual(store.items.filter { $0.personID == nil }.map { $0.displayName }, ["m1", "m2"])
    }

    func testUnreadableFileIsMovedAsideAndReplacedByEmptyState() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        try Data("not json".utf8).write(to: root.appendingPathComponent("library.json"))
        try Data(#"{"openAtLogin": false}"#.utf8).write(to: root.appendingPathComponent("settings.json"))

        let store = try LibraryStore(rootURL: root)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(fileExists("library.json.bak"))
        XCTAssertFalse(fileExists("library.json"))
        XCTAssertFalse(store.settings.openAtLogin)      // the other files still load
        XCTAssertTrue(store.isDirty)

        try store.save()
        XCTAssertTrue(fileExists("library.json"))
        XCTAssertTrue(try LibraryStore(rootURL: root).items.isEmpty)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("library.json.bak"), encoding: .utf8), "not json")
    }

    func testOneBrokenEntryDoesNotLoseTheLibrary() throws {
        let good = makeItem(name: "good")
        let store = try LibraryStore(rootURL: root)
        store.add(good)
        try store.save()

        let url = root.appendingPathComponent("library.json")
        var entries = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [Any])
        let broken: [String: Any] = ["fileURL": 42]
        entries.append(broken)
        try JSONSerialization.data(withJSONObject: entries).write(to: url)

        let reloaded = try LibraryStore(rootURL: root)
        XCTAssertEqual(reloaded.items, [good])
        XCTAssertTrue(reloaded.isDirty)
        XCTAssertTrue(fileExists("library.json.bak"))
    }

    func testDuplicateEntriesOnDiskAreDroppedOnLoad() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        let first = makeItem(name: "first", hash: "same")
        let second = makeItem(name: "second", hash: "same")
        try makeEncoder().encode([first, second, first]).write(to: root.appendingPathComponent("library.json"))

        let store = try LibraryStore(rootURL: root)
        XCTAssertEqual(store.items, [first])
        XCTAssertTrue(store.isDirty)
        XCTAssertTrue(store.contains(hash: "same"))
    }

    func testSettersMarkTheStoreDirty() throws {
        let store = try LibraryStore(rootURL: root)
        XCTAssertFalse(store.isDirty)
        store.settings.libraryOfferDismissals += 1
        XCTAssertTrue(store.isDirty)
        try store.save()
        XCTAssertFalse(store.isDirty)
        store.recents.record(UUID(), appBundleID: nil)
        XCTAssertTrue(store.isDirty)
    }

    func testDirectoriesAreCreatedOnAccess() throws {
        let store = try LibraryStore(rootURL: root)
        let kept = store.keptDirectory
        let stickers = store.stickersDirectory
        XCTAssertEqual(kept.lastPathComponent, "Kept")
        XCTAssertEqual(stickers.lastPathComponent, "Stickers")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stickers.path))
    }

    func testDefaultRootURL() {
        XCTAssertEqual(LibraryStore.defaultRootURL().lastPathComponent, "MemeMe")
    }
}
