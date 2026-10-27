import CryptoKit
import Foundation
@testable import MemeMeApp
import MemeMeCore
import XCTest

/// Download checks go through `UpdateStubURLProtocol` (UpdateCheckerTests.swift). The relaunch script runs
/// synchronously against folders in the sandbox; the staging test builds, mounts and detaches a real DMG.
final class UpdateInstallerTests: XCTestCase {
    private static let dmgURL = URL(string: "https://github.com/Michaell14/MemeMe/releases/download/v1.0-58/MemeMe.dmg")!
    private static let testBundleIdentifier = "com.mememe.tests"

    // MARK: - Hashing

    func testSHA256MatchesStandardVectorsAndReadsLargeFilesInChunks() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }

        let abc = sandbox.file("abc.txt")
        try Data("abc".utf8).write(to: abc)
        XCTAssertEqual(try UpdateInstaller.sha256(ofFileAt: abc),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        let empty = sandbox.file("empty")
        try Data().write(to: empty)
        XCTAssertEqual(try UpdateInstaller.sha256(ofFileAt: empty),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        // 2.5 MB spans three 1 MB reads.
        let large = sandbox.file("large.bin")
        let bytes = Data((0..<2_621_440).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try bytes.write(to: large)
        XCTAssertEqual(try UpdateInstaller.sha256(ofFileAt: large), UpdateInstallerTests.hex(bytes))
    }

    func testSHA256OfAMissingFileThrows() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("MemeMe-missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try UpdateInstaller.sha256(ofFileAt: missing))
    }

    // MARK: - Bundles

    func testValidateBundleChecksIdentifierAndExactBuild() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let app = try sandbox.directory("MemeMe.app")
        try writeInfoPlist(["CFBundleIdentifier": "com.mememe.app", "CFBundleVersion": "58"], toApp: app)

        XCTAssertNoThrow(try UpdateInstaller.validateBundle(at: app, bundleIdentifier: "com.mememe.app", build: 58))
        assertWrongBundle(try UpdateInstaller.validateBundle(at: app, bundleIdentifier: "com.other.app", build: 58))
        assertWrongBundle(try UpdateInstaller.validateBundle(at: app, bundleIdentifier: "com.mememe.app", build: 57))
        assertWrongBundle(try UpdateInstaller.validateBundle(at: app, bundleIdentifier: "com.mememe.app", build: 59))

        let nonNumeric = try sandbox.directory("NonNumeric.app")
        try writeInfoPlist(["CFBundleIdentifier": "com.mememe.app", "CFBundleVersion": "58b"], toApp: nonNumeric)
        assertWrongBundle(try UpdateInstaller.validateBundle(at: nonNumeric, bundleIdentifier: "com.mememe.app", build: 58))

        let missingPlist = try sandbox.directory("Empty.app")
        assertWrongBundle(try UpdateInstaller.validateBundle(at: missingPlist, bundleIdentifier: "com.mememe.app", build: 58))
    }

    func testCanReplaceOnlyWritableAppFoldersOutsideTranslocation() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }

        let app = try sandbox.directory("X.app")
        XCTAssertTrue(UpdateInstaller.canReplace(appAt: app))
        let folder = try sandbox.directory("NotAnApp")
        XCTAssertFalse(UpdateInstaller.canReplace(appAt: folder), "Not a .app")
        let plainFile = sandbox.file("File.app")
        try Data("not a bundle".utf8).write(to: plainFile)
        XCTAssertFalse(UpdateInstaller.canReplace(appAt: plainFile), "A file named .app")
        XCTAssertFalse(UpdateInstaller.canReplace(appAt: sandbox.url.appendingPathComponent("Missing.app", isDirectory: true)))
        let translocated = try sandbox.directory("AppTranslocation/0F6A1B2C/d/MemeMe.app")
        XCTAssertFalse(UpdateInstaller.canReplace(appAt: translocated), "Translocated apps can't replace themselves")
    }

    func testStagedURLIsAHiddenSibling() {
        let current = URL(fileURLWithPath: "/Applications/MemeMe.app", isDirectory: true)
        XCTAssertEqual(UpdateInstaller.stagedURL(for: current, build: 58).path, "/Applications/.MemeMe-update-58.app")
    }

    func testDefaultUpdatesDirectoryIsInCaches() {
        XCTAssertTrue(UpdateInstaller.defaultUpdatesDirectory().path.hasSuffix("/Caches/MemeMe/Updates"))
    }

    func testVerificationFailuresAreTheOnesThatMustNotOpenTheDMG() {
        let table: [(UpdateInstaller.Failure, Bool)] = [
            (.untrustedURL, true),
            (.sizeMismatch, true),
            (.checksumMismatch, true),
            (.appNotFound, true),
            (.wrongBundle("build"), true),
            (.signatureInvalid, true),
            (.downloadFailed("offline"), false),
            (.mountFailed("busy"), false),
            (.notReplaceable, false),
            (.stagingFailed("disk full"), false),
            (.relaunchFailed("denied"), false),
        ]
        for (failure, expected) in table {
            XCTAssertEqual(failure.isVerificationFailure, expected, "\(failure)")
        }
    }

    // MARK: - Download

    func testDownloadVerifiesAndReplacesAnOlderFile() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let session = UpdateStubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let installer = makeInstaller(in: sandbox, session: session)
        let payload = UpdateInstallerTests.payload
        let expected = installer.updatesDirectory
            .appendingPathComponent("58", isDirectory: true)
            .appendingPathComponent("MemeMe.dmg", isDirectory: false)
        try FileManager.default.createDirectory(at: expected.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try Data("stale".utf8).write(to: expected)
        // GitHub redirects release assets to objects.githubusercontent.com.
        UpdateStubURLProtocol.respond(
            status: 200,
            body: payload,
            contentType: "application/octet-stream",
            responseURL: URL(string: "https://objects.githubusercontent.com/github-production-release-asset/MemeMe.dmg")
        )

        let dmg = try await installer.download(manifest(sha256: UpdateInstallerTests.hex(payload), size: payload.count))

        XCTAssertEqual(dmg.standardizedFileURL.path, expected.standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: dmg), payload)
        let requests = UpdateStubURLProtocol.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url, UpdateInstallerTests.dmgURL)
    }

    func testDownloadWithWrongChecksumIsDeleted() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let session = UpdateStubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let installer = makeInstaller(in: sandbox, session: session)
        UpdateStubURLProtocol.respond(status: 200, body: UpdateInstallerTests.payload, contentType: "application/octet-stream")

        let error = await downloadError(installer, manifest(sha256: String(repeating: "0", count: 64)))

        XCTAssertEqual(error as? UpdateInstaller.Failure, UpdateInstaller.Failure.checksumMismatch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dmgPath(installer)), "A rejected DMG is deleted")
    }

    func testDownloadWithWrongSizeIsDeleted() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let session = UpdateStubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let installer = makeInstaller(in: sandbox, session: session)
        let payload = UpdateInstallerTests.payload
        UpdateStubURLProtocol.respond(status: 200, body: payload, contentType: "application/octet-stream")

        let error = await downloadError(installer, manifest(sha256: UpdateInstallerTests.hex(payload), size: payload.count + 1))

        XCTAssertEqual(error as? UpdateInstaller.Failure, UpdateInstaller.Failure.sizeMismatch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dmgPath(installer)))
    }

    func testUntrustedDownloadURLIsNeverRequested() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let session = UpdateStubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let installer = makeInstaller(in: sandbox, session: session)
        let payload = UpdateInstallerTests.payload
        UpdateStubURLProtocol.respond(status: 200, body: payload, contentType: "application/octet-stream")
        var untrusted = manifest(sha256: UpdateInstallerTests.hex(payload))
        untrusted.downloadURL = try XCTUnwrap(URL(string: "https://example.com/MemeMe.dmg"))

        let error = await downloadError(installer, untrusted)

        XCTAssertEqual(error as? UpdateInstaller.Failure, UpdateInstaller.Failure.untrustedURL)
        XCTAssertTrue(UpdateStubURLProtocol.recordedRequests().isEmpty)
    }

    func testRedirectToAnUntrustedHostIsRejected() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let session = UpdateStubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let installer = makeInstaller(in: sandbox, session: session)
        let payload = UpdateInstallerTests.payload
        UpdateStubURLProtocol.respond(
            status: 200,
            body: payload,
            contentType: "application/octet-stream",
            responseURL: URL(string: "https://downloads.example.com/MemeMe.dmg")
        )

        let error = await downloadError(installer, manifest(sha256: UpdateInstallerTests.hex(payload)))

        XCTAssertEqual(error as? UpdateInstaller.Failure, UpdateInstaller.Failure.untrustedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dmgPath(installer)))
    }

    func testHTTPErrorIsADownloadFailure() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let session = UpdateStubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let installer = makeInstaller(in: sandbox, session: session)
        UpdateStubURLProtocol.respond(status: 404, text: "Not Found")

        let error = await downloadError(installer, manifest(sha256: UpdateInstallerTests.hex(UpdateInstallerTests.payload)))

        XCTAssertEqual(error as? UpdateInstaller.Failure, UpdateInstaller.Failure.downloadFailed("HTTP 404"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dmgPath(installer)))
    }

    // MARK: - Relaunch script and clean-up

    func testRelaunchScriptSwapsTheBundlesAndDeletesItself() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let apps = try sandbox.directory("Apps")
        let current = try sandbox.directory("Apps/MemeMe.app")
        try Data("old".utf8).write(to: current.appendingPathComponent("marker"))
        let staged = UpdateInstaller.stagedURL(for: current, build: 58)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true, attributes: nil)
        try Data("new".utf8).write(to: staged.appendingPathComponent("marker"))
        let script = sandbox.file("relaunch.sh")
        try UpdateInstaller.relaunchScript.write(to: script, atomically: true, encoding: .utf8)

        let status = try runRelaunchScript(script, current: current, staged: staged)

        XCTAssertEqual(status, 0)
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("marker"), encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "The staged bundle moved into place")
        let names = try FileManager.default.contentsOfDirectory(atPath: apps.path)
        XCTAssertEqual(names.filter { $0.hasPrefix(".MemeMe-old-") }, [], "The old copy is deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path), "The script deletes itself")
    }

    func testRelaunchScriptLeavesTheAppAloneWithoutAStagedBundle() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let apps = try sandbox.directory("Apps")
        let current = try sandbox.directory("Apps/MemeMe.app")
        try Data("old".utf8).write(to: current.appendingPathComponent("marker"))
        let staged = UpdateInstaller.stagedURL(for: current, build: 58)
        let script = sandbox.file("relaunch.sh")
        try UpdateInstaller.relaunchScript.write(to: script, atomically: true, encoding: .utf8)

        let status = try runRelaunchScript(script, current: current, staged: staged)

        XCTAssertEqual(status, 0)
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("marker"), encoding: .utf8), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["MemeMe.app"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path))
    }

    func testCleanUpRemovesTheUpdatesFolderAndHiddenBundles() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let installer = UpdateInstaller(session: .shared, updatesDirectory: sandbox.url.appendingPathComponent("Updates", isDirectory: true))
        let buildFolder = installer.updatesDirectory.appendingPathComponent("58", isDirectory: true)
        try FileManager.default.createDirectory(at: buildFolder, withIntermediateDirectories: true, attributes: nil)
        try Data("dmg".utf8).write(to: buildFolder.appendingPathComponent("MemeMe.dmg"))
        let apps = try sandbox.directory("Apps")
        let current = try sandbox.directory("Apps/MemeMe.app")
        _ = try sandbox.directory("Apps/.MemeMe-update-58.app")
        _ = try sandbox.directory("Apps/.MemeMe-old-4242.app")
        _ = try sandbox.directory("Apps/Other.app")
        try Data().write(to: apps.appendingPathComponent(".MemeMe-update-notes.txt"))

        installer.cleanUp(currentApp: current)

        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.updatesDirectory.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path).sorted(),
                       [".MemeMe-update-notes.txt", "MemeMe.app", "Other.app"])

        // Nothing left to clean: still no throw, nothing else touched.
        installer.cleanUp(currentApp: current)
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
    }

    // MARK: - Staging from a real DMG

    func testStageMountsVerifiesCopiesAndDetaches() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let source = try sandbox.directory("DMGSource")
        try makeSignedFakeApp(at: source.appendingPathComponent("MemeMe.app", isDirectory: true), build: 58)
        let dmg = sandbox.file("MemeMe.dmg")
        let create = try runTool("/usr/bin/hdiutil", [
            "create", "-volname", "MemeMeTest", "-srcfolder", source.path, "-format", "UDZO", "-ov", dmg.path,
        ])
        guard create.status == 0 else { throw XCTSkip("hdiutil create failed on this machine: \(create.output)") }

        let current = try sandbox.directory("Apps/MemeMe.app")
        let installer = UpdateInstaller(session: .shared, updatesDirectory: sandbox.url.appendingPathComponent("Updates", isDirectory: true))
        let release = manifest(sha256: String(repeating: "0", count: 64))

        let staged: URL
        do {
            staged = try await installer.stage(dmg: dmg, manifest: release, currentApp: current, bundleIdentifier: UpdateInstallerTests.testBundleIdentifier)
        } catch UpdateInstaller.Failure.mountFailed(let output) {
            throw XCTSkip("hdiutil attach failed on this machine: \(output)")
        }

        XCTAssertEqual(staged.standardizedFileURL.path, UpdateInstaller.stagedURL(for: current, build: 58).standardizedFileURL.path)
        XCTAssertNoThrow(try UpdateInstaller.validateBundle(at: staged, bundleIdentifier: UpdateInstallerTests.testBundleIdentifier, build: 58))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appendingPathComponent("Contents/MacOS/fake").path))
        XCTAssertEqual(mountFolders(installer, build: 58), [], "The DMG is detached and its mount point removed")

        // The same DMG for a different running app: rejected, nothing staged, still detached.
        try FileManager.default.removeItem(at: staged)
        do {
            _ = try await installer.stage(dmg: dmg, manifest: release, currentApp: current, bundleIdentifier: "com.other")
            XCTFail("A bundle with another identifier must be rejected")
        } catch UpdateInstaller.Failure.wrongBundle(_) {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(mountFolders(installer, build: 58), [])
    }

    func testStageRefusesAnAppItCannotReplace() async throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let installer = UpdateInstaller(session: .shared, updatesDirectory: sandbox.url.appendingPathComponent("Updates", isDirectory: true))
        let translocated = try sandbox.directory("AppTranslocation/0F6A1B2C/d/MemeMe.app")

        do {
            _ = try await installer.stage(
                dmg: sandbox.file("MemeMe.dmg"),
                manifest: manifest(sha256: String(repeating: "0", count: 64)),
                currentApp: translocated,
                bundleIdentifier: UpdateInstallerTests.testBundleIdentifier
            )
            XCTFail("A translocated app can't be replaced")
        } catch let failure as UpdateInstaller.Failure {
            XCTAssertEqual(failure, .notReplaceable)
        }
    }

    // MARK: - Helpers

    /// 5000 bytes that aren't all the same.
    private static let payload = Data((0..<5000).map { UInt8($0 % 251) })

    private static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func manifest(sha256: String, size: Int? = nil) -> UpdateManifest {
        UpdateManifest(version: "1.0", build: 58, downloadURL: UpdateInstallerTests.dmgURL, sha256: sha256, size: size)
    }

    private func makeInstaller(in sandbox: TestSandbox, session: URLSession) -> UpdateInstaller {
        UpdateInstaller(session: session, updatesDirectory: sandbox.url.appendingPathComponent("Updates", isDirectory: true))
    }

    private func dmgPath(_ installer: UpdateInstaller) -> String {
        installer.updatesDirectory.appendingPathComponent("58/MemeMe.dmg", isDirectory: false).path
    }

    private func downloadError(_ installer: UpdateInstaller, _ manifest: UpdateManifest) async -> Error? {
        do {
            let url = try await installer.download(manifest)
            XCTFail("Expected the download to fail, got \(url.lastPathComponent)")
            return nil
        } catch {
            return error
        }
    }

    private func assertWrongBundle(_ expression: @autoclosure () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        do {
            try expression()
            XCTFail("Expected .wrongBundle", file: file, line: line)
        } catch UpdateInstaller.Failure.wrongBundle(_) {
            // Expected.
        } catch {
            XCTFail("Expected .wrongBundle, got \(error)", file: file, line: line)
        }
    }

    private func writeInfoPlist(_ info: [String: Any], toApp app: URL) throws {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true, attributes: nil)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist", isDirectory: false))
    }

    /// A minimal app bundle, ad-hoc signed. The executable is a copy of /usr/bin/true: a Mach-O keeps its
    /// signature inside the file, so it survives the trip through the DMG.
    private func makeSignedFakeApp(at app: URL, build: Int) throws {
        try writeInfoPlist([
            "CFBundleIdentifier": UpdateInstallerTests.testBundleIdentifier,
            "CFBundleVersion": String(build),
            "CFBundleShortVersionString": "1.0",
            "CFBundleExecutable": "fake",
            "CFBundlePackageType": "APPL",
            "CFBundleName": "MemeMe",
        ], toApp: app)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true, attributes: nil)
        let executable = macOS.appendingPathComponent("fake", isDirectory: false)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let sign = try runTool("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        guard sign.status == 0 else { throw XCTSkip("Ad-hoc signing failed on this machine: \(sign.output)") }
    }

    /// `mount-*` folders left in the build's updates folder.
    private func mountFolders(_ installer: UpdateInstaller, build: Int) -> [String] {
        let folder = installer.updatesDirectory.appendingPathComponent(String(build), isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix("mount-") }
    }

    /// Runs the script the way the relauncher does, but waits for it. The pid is one that already exited.
    private func runRelaunchScript(_ script: URL, current: URL, staged: URL) throws -> Int32 {
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(finished.processIdentifier), current.path, staged.path, "/usr/bin/true"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func runTool(_ path: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return (status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
