import Foundation
import XCTest
@testable import MemeMeCore

final class UpdateTests: XCTestCase {
    private let sha = String(repeating: "0123456789abcdef", count: 4)
    private let dmgURL = "https://github.com/Michaell14/MemeMe/releases/download/v1.0-58/MemeMe.dmg"
    private let pageURL = "https://github.com/Michaell14/MemeMe/releases/tag/v1.0-58"
    /// 2026-10-27T02:00:00Z
    private let october27 = Date(timeIntervalSince1970: 1_793_066_400)

    /// latest.json with every key set.
    private func fullObject() -> [String: Any] {
        [
            "version": "1.0",
            "build": 58,
            "downloadURL": dmgURL,
            "sha256": sha,
            "size": 4_242_424,
            "minimumSystemVersion": "14.0",
            "notes": ["Update notifications", "Faster search"],
            "releasePageURL": pageURL,
            "publishedAt": "2026-10-27T02:00:00Z",
        ]
    }

    /// latest.json with only the required keys.
    private func minimalObject() -> [String: Any] {
        ["version": "1.0", "build": 58, "downloadURL": dmgURL, "sha256": sha]
    }

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func decode(_ object: [String: Any]) throws -> UpdateManifest {
        try UpdateManifest.decode(from: try data(object))
    }

    private func makeManifest(build: Int = 58, minimumSystemVersion: String? = nil) throws -> UpdateManifest {
        UpdateManifest(version: "1.0", build: build, downloadURL: try XCTUnwrap(URL(string: dmgURL)), sha256: sha,
                       minimumSystemVersion: minimumSystemVersion)
    }

    private func macOS(_ major: Int, _ minor: Int, _ patch: Int = 0) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    private func assertMalformed(_ object: [String: Any], _ label: String,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let json = try data(object)
        XCTAssertThrowsError(try UpdateManifest.decode(from: json), label, file: file, line: line) { error in
            XCTAssertEqual(error as? UpdateManifestError, .malformed, label, file: file, line: line)
        }
    }

    private func assertInvalid(_ object: [String: Any], _ label: String,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let json = try data(object)
        XCTAssertThrowsError(try UpdateManifest.decode(from: json), label, file: file, line: line) { error in
            guard case .invalid(let reason)? = error as? UpdateManifestError else {
                return XCTFail("\(label): expected .invalid, got \(error)", file: file, line: line)
            }
            XCTAssertFalse(reason.isEmpty, label, file: file, line: line)
        }
    }

    // MARK: Decoding

    func testDecodesFullManifest() throws {
        let manifest = try decode(fullObject())
        XCTAssertEqual(manifest.version, "1.0")
        XCTAssertEqual(manifest.build, 58)
        XCTAssertEqual(manifest.downloadURL, URL(string: dmgURL))
        XCTAssertEqual(manifest.sha256, sha)
        XCTAssertEqual(manifest.size, 4_242_424)
        XCTAssertEqual(manifest.minimumSystemVersion, "14.0")
        XCTAssertEqual(manifest.notes, ["Update notifications", "Faster search"])
        XCTAssertEqual(manifest.releasePageURL, URL(string: pageURL))
        XCTAssertEqual(manifest.publishedAt, october27)
    }

    func testDecodesMinimalManifest() throws {
        let manifest = try decode(minimalObject())
        XCTAssertEqual(manifest, try makeManifest())
        XCTAssertNil(manifest.size)
        XCTAssertNil(manifest.minimumSystemVersion)
        XCTAssertEqual(manifest.notes, [])
        XCTAssertNil(manifest.releasePageURL)
        XCTAssertNil(manifest.publishedAt)
    }

    func testDecodesLiteralJSONAndIgnoresUnknownKeys() throws {
        let json = """
        {"version": "1.0", "build": 58, "downloadURL": "\(dmgURL)", "sha256": "\(sha)", "channel": "stable"}
        """
        XCTAssertEqual(try UpdateManifest.decode(from: Data(json.utf8)), try makeManifest())
    }

    func testUppercaseSHA256IsLowercased() throws {
        var object = minimalObject()
        object["sha256"] = sha.uppercased()
        XCTAssertEqual(try decode(object).sha256, sha)
    }

    func testVersionIsTrimmed() throws {
        var object = minimalObject()
        object["version"] = "  1.0\n"
        XCTAssertEqual(try decode(object).version, "1.0")
    }

    func testMissingRequiredKeysAreMalformed() throws {
        for key in ["version", "build", "downloadURL", "sha256"] {
            var object = minimalObject()
            object.removeValue(forKey: key)
            try assertMalformed(object, "missing \(key)")
        }
    }

    func testNullRequiredKeysAreMalformed() throws {
        for key in ["version", "build", "downloadURL", "sha256"] {
            var object = minimalObject()
            object[key] = NSNull()
            try assertMalformed(object, "null \(key)")
        }
    }

    func testWrongTypesForRequiredKeysAreMalformed() throws {
        let wrongValues: [(String, Any)] = [
            ("version", 1),
            ("build", "58"),
            ("downloadURL", 5),
            ("downloadURL", ["url": dmgURL]),
            ("sha256", 7),
        ]
        for (key, value) in wrongValues {
            var object = minimalObject()
            object[key] = value
            try assertMalformed(object, "\(key) = \(value)")
        }
    }

    func testBadJSONIsMalformed() {
        for text in ["", "not json", "[]", "{\"version\": \"1.0\""] {
            XCTAssertThrowsError(try UpdateManifest.decode(from: Data(text.utf8)), text) { error in
                XCTAssertEqual(error as? UpdateManifestError, .malformed, text)
            }
        }
    }

    func testOutOfRangeValuesAreInvalid() throws {
        let badValues: [(String, Any)] = [
            ("build", 0),
            ("build", -3),
            ("sha256", "abc"),
            ("sha256", String(repeating: "g", count: 64)),
            ("sha256", sha + "0"),
            ("version", ""),
            ("version", "   "),
            ("size", 0),
            ("size", -1),
        ]
        for (key, value) in badValues {
            var object = fullObject()
            object[key] = value
            try assertInvalid(object, "\(key) = \(value)")
        }
    }

    func testBuildOneAndSizeOneAreValid() throws {
        var object = minimalObject()
        object["build"] = 1
        object["size"] = 1
        let manifest = try decode(object)
        XCTAssertEqual(manifest.build, 1)
        XCTAssertEqual(manifest.size, 1)
    }

    func testOptionalKeysWithWrongTypesAreIgnored() throws {
        var object = minimalObject()
        object["size"] = "big"
        object["minimumSystemVersion"] = 14
        object["notes"] = "just one note"
        object["releasePageURL"] = 5
        object["publishedAt"] = 1_793_066_400
        let manifest = try decode(object)
        XCTAssertNil(manifest.size)
        XCTAssertNil(manifest.minimumSystemVersion)
        XCTAssertEqual(manifest.notes, [])
        XCTAssertNil(manifest.releasePageURL)
        XCTAssertNil(manifest.publishedAt)
    }

    func testNullOptionalKeysAreIgnored() throws {
        var object = minimalObject()
        for key in ["size", "minimumSystemVersion", "notes", "releasePageURL", "publishedAt"] {
            object[key] = NSNull()
        }
        XCTAssertEqual(try decode(object), try makeManifest())
    }

    func testUnparseableDateIsNil() throws {
        for text in ["yesterday", "", "2026-10-27", "27/10/2026 02:00"] {
            var object = minimalObject()
            object["publishedAt"] = text
            XCTAssertNil(try decode(object).publishedAt, text)
        }
    }

    func testFractionalSecondDate() throws {
        var object = minimalObject()
        object["publishedAt"] = "2026-10-27T02:00:00.250Z"
        let date = try XCTUnwrap(try decode(object).publishedAt)
        XCTAssertEqual(date.timeIntervalSince1970, october27.timeIntervalSince1970 + 0.25, accuracy: 0.001)
    }

    func testDateWithOffset() throws {
        var object = minimalObject()
        object["publishedAt"] = "2026-10-27T04:00:00+02:00"
        XCTAssertEqual(try decode(object).publishedAt, october27)
    }

    func testNotesKeepNonEmptyTrimmedLines() throws {
        var object = minimalObject()
        object["notes"] = ["  Faster search ", "", "   ", "Update notifications"]
        XCTAssertEqual(try decode(object).notes, ["Faster search", "Update notifications"])
    }

    func testEmptyMinimumSystemVersionIsNil() throws {
        var object = minimalObject()
        object["minimumSystemVersion"] = "  "
        XCTAssertNil(try decode(object).minimumSystemVersion)
    }

    func testJSONDecoderAppliesTheSameRules() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(UpdateManifest.self, from: try data(fullObject())), try decode(fullObject()))

        var object = minimalObject()
        object["build"] = 0
        XCTAssertThrowsError(try decoder.decode(UpdateManifest.self, from: try data(object)))
    }

    // MARK: Encoding

    func testRoundTripPreservesEveryField() throws {
        let original = UpdateManifest(version: "1.2",
                                      build: 104,
                                      downloadURL: try XCTUnwrap(URL(string: dmgURL)),
                                      sha256: sha,
                                      size: 5_000_000,
                                      minimumSystemVersion: "14.2",
                                      notes: ["Update notifications", "Faster search"],
                                      releasePageURL: URL(string: pageURL),
                                      publishedAt: TestDates.september5)
        let encoded = try JSONEncoder().encode(original)
        XCTAssertEqual(try UpdateManifest.decode(from: encoded), original)
    }

    func testRoundTripOfMinimalManifest() throws {
        let original = try makeManifest()
        XCTAssertEqual(try UpdateManifest.decode(from: try JSONEncoder().encode(original)), original)
    }

    func testEncodesURLsAndDateAsStrings() throws {
        let original = UpdateManifest(version: "1.0", build: 58, downloadURL: try XCTUnwrap(URL(string: dmgURL)), sha256: sha,
                                      releasePageURL: URL(string: pageURL), publishedAt: october27)
        let encoded = try JSONEncoder().encode(original)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["version"] as? String, "1.0")
        XCTAssertEqual(object["build"] as? Int, 58)
        XCTAssertEqual(object["downloadURL"] as? String, dmgURL)
        XCTAssertEqual(object["sha256"] as? String, sha)
        XCTAssertEqual(object["releasePageURL"] as? String, pageURL)
        XCTAssertEqual(object["publishedAt"] as? String, "2026-10-27T02:00:00Z")
        XCTAssertEqual(object["notes"] as? [String], [])
        XCTAssertNil(object["size"])
        XCTAssertNil(object["minimumSystemVersion"])
    }

    func testInitializerDefaults() throws {
        let plain = try makeManifest()
        XCTAssertNil(plain.size)
        XCTAssertNil(plain.minimumSystemVersion)
        XCTAssertEqual(plain.notes, [])
        XCTAssertNil(plain.releasePageURL)
        XCTAssertNil(plain.publishedAt)
    }

    func testDisplayVersion() throws {
        XCTAssertEqual(try makeManifest().displayVersion, "1.0 (58)")
        XCTAssertEqual(try makeManifest(build: 7).displayVersion, "1.0 (7)")
    }

    // MARK: Policy

    func testPolicyConstants() {
        XCTAssertEqual(UpdatePolicy.checkInterval, 21_600)
        XCTAssertEqual(UpdatePolicy.firstCheckDelay, 20)
        XCTAssertEqual(UpdatePolicy.wakeCheckAge, 3600)
    }

    func testCompareVersions() {
        XCTAssertEqual(UpdatePolicy.compareVersions("14.0", "14"), .orderedSame)
        XCTAssertEqual(UpdatePolicy.compareVersions("14", "14.0.0"), .orderedSame)
        XCTAssertEqual(UpdatePolicy.compareVersions("14.2.1", "14.2"), .orderedDescending)
        XCTAssertEqual(UpdatePolicy.compareVersions("14.2", "14.2.1"), .orderedAscending)
        XCTAssertEqual(UpdatePolicy.compareVersions("15", "14.9"), .orderedDescending)
        XCTAssertEqual(UpdatePolicy.compareVersions("14.10", "14.9"), .orderedDescending)
        XCTAssertEqual(UpdatePolicy.compareVersions("14.0", "14.2.1"), .orderedAscending)
        XCTAssertEqual(UpdatePolicy.compareVersions("1.a", "1.0"), .orderedSame)
        XCTAssertEqual(UpdatePolicy.compareVersions("1.a", "1.1"), .orderedAscending)
        XCTAssertEqual(UpdatePolicy.compareVersions("", "0"), .orderedSame)
    }

    func testIsSystemAtLeast() {
        XCTAssertTrue(UpdatePolicy.isSystem(macOS(14, 0), atLeast: "14.0"))
        XCTAssertTrue(UpdatePolicy.isSystem(macOS(14, 0), atLeast: "14"))
        XCTAssertTrue(UpdatePolicy.isSystem(macOS(15, 1), atLeast: "14.6"))
        XCTAssertTrue(UpdatePolicy.isSystem(macOS(14, 2, 1), atLeast: "14.2.1"))
        XCTAssertFalse(UpdatePolicy.isSystem(macOS(14, 2), atLeast: "14.2.1"))
        XCTAssertFalse(UpdatePolicy.isSystem(macOS(14, 6), atLeast: "15.0"))
        XCTAssertFalse(UpdatePolicy.isSystem(macOS(14, 9), atLeast: "14.10"))
    }

    func testDecideOlderOrEqualBuildIsUpToDate() throws {
        let older = try makeManifest(build: 57)
        let same = try makeManifest(build: 58)
        XCTAssertEqual(UpdatePolicy.decide(installedBuild: 58, manifest: older, systemVersion: macOS(14, 6)), .upToDate)
        XCTAssertEqual(UpdatePolicy.decide(installedBuild: 58, manifest: same, systemVersion: macOS(14, 6)), .upToDate)
        // An unrunnable build that isn't newer is still just up to date.
        let needsNewer = try makeManifest(build: 58, minimumSystemVersion: "99.0")
        XCTAssertEqual(UpdatePolicy.decide(installedBuild: 58, manifest: needsNewer, systemVersion: macOS(14, 6)), .upToDate)
    }

    func testDecideNewerBuildIsAvailable() throws {
        let newer = try makeManifest(build: 58)
        XCTAssertEqual(UpdatePolicy.decide(installedBuild: 57, manifest: newer, systemVersion: macOS(14, 0)), .available(newer))
        XCTAssertEqual(UpdatePolicy.decide(installedBuild: 0, manifest: newer, systemVersion: macOS(14, 0)), .available(newer))
    }

    func testDecideRespectsMinimumSystemVersion() throws {
        let needs15 = try makeManifest(build: 58, minimumSystemVersion: "15.0")
        XCTAssertEqual(UpdatePolicy.decide(installedBuild: 57, manifest: needs15, systemVersion: macOS(14, 6)), .requiresNewerSystem(needs15))
        XCTAssertEqual(UpdatePolicy.decide(installedBuild: 57, manifest: needs15, systemVersion: macOS(15, 0)), .available(needs15))
        XCTAssertEqual(UpdatePolicy.decide(installedBuild: 57, manifest: needs15, systemVersion: macOS(26, 0)), .available(needs15))

        let needs14 = try makeManifest(build: 58, minimumSystemVersion: "14.0")
        XCTAssertEqual(UpdatePolicy.decide(installedBuild: 57, manifest: needs14, systemVersion: macOS(14, 6)), .available(needs14))
    }

    func testTrustedDownloadURLs() throws {
        let trusted = [
            dmgURL,
            "https://objects.githubusercontent.com/github-production-release-asset-2e65be/123/abc?X-Amz-Algorithm=AWS4-HMAC-SHA256",
            "https://release-assets.githubusercontent.com/github-production-release-asset/123/abc?sp=r",
            "HTTPS://GitHub.com/Michaell14/MemeMe/releases/download/v1.0-58/MemeMe.dmg",
        ]
        for string in trusted {
            XCTAssertTrue(UpdatePolicy.isTrustedDownloadURL(try XCTUnwrap(URL(string: string))), string)
        }
    }

    func testUntrustedDownloadURLs() throws {
        let untrusted = [
            "http://github.com/Michaell14/MemeMe/releases/download/v1.0-58/MemeMe.dmg",
            "http://objects.githubusercontent.com/asset",
            "https://github.com.evil.com/MemeMe.dmg",
            "https://evilgithub.com/MemeMe.dmg",
            "https://githubusercontent.com/MemeMe.dmg",
            "https://githubusercontent.com.evil.com/MemeMe.dmg",
            "https://user:pw@github.com/MemeMe.dmg",
            "https://user@github.com/MemeMe.dmg",
            "https://evil.com/github.com",
            "https://evil.com/?next=https://github.com/MemeMe.dmg",
            "ftp://github.com/MemeMe.dmg",
            "file:///Users/me/Downloads/MemeMe.dmg",
            "MemeMe.dmg",
        ]
        for string in untrusted {
            XCTAssertFalse(UpdatePolicy.isTrustedDownloadURL(try XCTUnwrap(URL(string: string))), string)
        }
    }

    func testIsValidSHA256() {
        XCTAssertTrue(UpdatePolicy.isValidSHA256(sha))
        XCTAssertTrue(UpdatePolicy.isValidSHA256(String(repeating: "f", count: 64)))
        XCTAssertFalse(UpdatePolicy.isValidSHA256(sha.uppercased()))
        XCTAssertFalse(UpdatePolicy.isValidSHA256(String(sha.dropLast())))
        XCTAssertFalse(UpdatePolicy.isValidSHA256(sha + "a"))
        XCTAssertFalse(UpdatePolicy.isValidSHA256(String(repeating: "g", count: 64)))
        XCTAssertFalse(UpdatePolicy.isValidSHA256(String(sha.dropLast()) + " "))
        XCTAssertFalse(UpdatePolicy.isValidSHA256(String(sha.dropLast()) + "é"))
        XCTAssertFalse(UpdatePolicy.isValidSHA256(""))
    }

    func testShouldOfferInPanel() throws {
        let update = try makeManifest(build: 58)
        XCTAssertTrue(UpdatePolicy.shouldOfferInPanel(update, skippedBuild: nil))
        XCTAssertTrue(UpdatePolicy.shouldOfferInPanel(update, skippedBuild: 57))
        XCTAssertFalse(UpdatePolicy.shouldOfferInPanel(update, skippedBuild: 58))
    }
}
