import Foundation
import XCTest
@testable import MemeMeCore

final class AppSettingsTests: XCTestCase {
    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func testDefaults() {
        let settings = AppSettings()
        XCTAssertEqual(settings.hotKeyKeyCode, 46)
        XCTAssertEqual(settings.hotKeyModifiers, 2048)
        XCTAssertTrue(settings.openAtLogin)
        XCTAssertEqual(settings.stickerPolicy, .automatic)
        XCTAssertNil(settings.groupFaces)
        XCTAssertEqual(settings.watchedFolders, [])
        XCTAssertNil(settings.collectingPausedUntil)
        XCTAssertTrue(settings.webDiscoverEnabled)
        XCTAssertNil(settings.giphyAPIKey)
        XCTAssertFalse(settings.hasCompletedFirstRun)
        XCTAssertEqual(settings.libraryOfferDismissals, 0)
        XCTAssertFalse(settings.libraryOfferAccepted)
        XCTAssertEqual(settings.baseline, RestingBaseline())
        XCTAssertNil(settings.skippedUpdateBuild)
        XCTAssertFalse(settings.hotKeyChosen)
    }

    func testDecodingAnEmptyObjectGivesDefaults() throws {
        XCTAssertEqual(try makeDecoder().decode(AppSettings.self, from: Data("{}".utf8)), AppSettings())
    }

    func testDecodingPartialAndMalformedKeysKeepsDefaults() throws {
        let json = #"{"openAtLogin": false, "groupFaces": true, "stickerPolicy": "sometimes", "hotKeyKeyCode": "M", "watchedFolders": ["/Users/me/Downloads"], "baseline": 3}"#
        let settings = try makeDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertFalse(settings.openAtLogin)
        XCTAssertEqual(settings.groupFaces, true)
        XCTAssertEqual(settings.stickerPolicy, .automatic)
        XCTAssertEqual(settings.hotKeyKeyCode, 46)
        XCTAssertEqual(settings.hotKeyModifiers, 2048)
        XCTAssertEqual(settings.watchedFolders, ["/Users/me/Downloads"])
        XCTAssertTrue(settings.webDiscoverEnabled)
        XCTAssertEqual(settings.baseline, RestingBaseline())
    }

    func testSavedControlCommandMMovesToOptionM() throws {
        let json = #"{"hotKeyKeyCode": 46, "hotKeyModifiers": 4352}"#
        let settings = try makeDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.hotKeyKeyCode, 46)
        XCTAssertEqual(settings.hotKeyModifiers, 2048)
    }

    func testAPickedControlCommandMStays() throws {
        let json = #"{"hotKeyKeyCode": 46, "hotKeyModifiers": 4352, "hotKeyChosen": true}"#
        let settings = try makeDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.hotKey, HotKeyShortcut(keyCode: 46, modifiers: HotKeyShortcut.control | HotKeyShortcut.command))
        XCTAssertTrue(settings.hotKeyChosen)
    }

    func testHotKeyReadsAndWritesTheKeyCodeAndModifiers() {
        var settings = AppSettings()
        XCTAssertEqual(settings.hotKey, .standard)
        settings.hotKey = HotKeyShortcut(keyCode: 40, modifiers: HotKeyShortcut.control | HotKeyShortcut.option)
        XCTAssertEqual(settings.hotKeyKeyCode, 40)
        XCTAssertEqual(settings.hotKeyModifiers, 6144)
    }

    func testRoundTripWithEveryFieldChanged() throws {
        var settings = AppSettings()
        settings.hotKeyKeyCode = 12
        settings.hotKeyModifiers = 256
        settings.hotKeyChosen = true
        settings.openAtLogin = false
        settings.stickerPolicy = .ask
        settings.groupFaces = false
        settings.watchedFolders = ["/Users/me/Desktop", "/Users/me/Pictures/Memes"]
        settings.collectingPausedUntil = TestDates.march15
        settings.webDiscoverEnabled = false
        settings.giphyAPIKey = "test-key"
        settings.hasCompletedFirstRun = true
        settings.libraryOfferDismissals = 2
        settings.libraryOfferAccepted = true
        settings.baseline = RestingBaseline(neutral: makeFace(brow: 0.5, smile: 0.55), sampleCount: 40)
        settings.skippedUpdateBuild = 58
        XCTAssertNotEqual(settings, AppSettings())

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoded = try makeDecoder().decode(AppSettings.self, from: try encoder.encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    func testSkippedUpdateBuildRoundTrips() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var settings = AppSettings()
        let unset = try XCTUnwrap(try JSONSerialization.jsonObject(with: try encoder.encode(settings)) as? [String: Any])
        XCTAssertNil(unset["skippedUpdateBuild"])

        settings.skippedUpdateBuild = 58
        let data = try encoder.encode(settings)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["skippedUpdateBuild"] as? Int, 58)
        XCTAssertEqual(try makeDecoder().decode(AppSettings.self, from: data).skippedUpdateBuild, 58)
    }

    func testOlderSettingsWithoutSkippedUpdateBuildDecode() throws {
        let json = #"{"openAtLogin": false, "hasCompletedFirstRun": true, "libraryOfferDismissals": 1, "watchedFolders": ["/Users/me/Desktop"]}"#
        let settings = try makeDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertNil(settings.skippedUpdateBuild)
        XCTAssertFalse(settings.openAtLogin)
        XCTAssertTrue(settings.hasCompletedFirstRun)
        XCTAssertEqual(settings.libraryOfferDismissals, 1)
        XCTAssertEqual(settings.watchedFolders, ["/Users/me/Desktop"])
    }

    func testMalformedSkippedUpdateBuildFallsBackToNil() throws {
        for value in [#""58""#, "null", "[58]", #"{"build": 58}"#] {
            let json = #"{"skippedUpdateBuild": "# + value + #", "openAtLogin": false, "libraryOfferDismissals": 2}"#
            let settings = try makeDecoder().decode(AppSettings.self, from: Data(json.utf8))
            XCTAssertNil(settings.skippedUpdateBuild, value)
            XCTAssertFalse(settings.openAtLogin, value)
            XCTAssertEqual(settings.libraryOfferDismissals, 2, value)
        }
    }
}
