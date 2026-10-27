import CryptoKit
import Foundation
import MemeMeCore
import os

private let installerLog = Logger(subsystem: "com.mememe.app", category: "update")

/// The mechanics of one update: download and verify, stage from the DMG, relaunch. No UI.
struct UpdateInstaller {
    enum Failure: Error, Equatable {
        case untrustedURL, downloadFailed(String), sizeMismatch, checksumMismatch
        case mountFailed(String), appNotFound, wrongBundle(String), signatureInvalid
        case notReplaceable, stagingFailed(String), relaunchFailed(String)

        /// size/checksum/host/bundle/signature problems: the DMG must not be opened.
        var isVerificationFailure: Bool {
            switch self {
            case .untrustedURL, .sizeMismatch, .checksumMismatch, .appNotFound, .wrongBundle, .signatureInvalid:
                return true
            case .downloadFailed, .mountFailed, .notReplaceable, .stagingFailed, .relaunchFailed:
                return false
            }
        }
    }

    var session: URLSession
    /// ~/Library/Caches/MemeMe/Updates; one folder per build.
    var updatesDirectory: URL

    private static let downloadTimeout: TimeInterval = 120
    private static let hashChunkSize = 1 << 20
    private static let dmgFileName = "MemeMe.dmg"
    private static let hdiutil = "/usr/bin/hdiutil"
    private static let codesign = "/usr/bin/codesign"
    private static let ditto = "/usr/bin/ditto"

    /// Exit status and combined stdout/stderr of one command-line tool.
    private typealias ToolResult = (status: Int32, output: String)
    /// Characters of a tool's output that are kept: enough for an error message.
    private static let toolOutputLimit = 1000
    /// `codesign -dv` prints the bundle's full path before TeamIdentifier, so it gets more room.
    private static let signingDetailsLimit = 16_384

    init(session: URLSession = .shared, updatesDirectory: URL = UpdateInstaller.defaultUpdatesDirectory()) {
        self.session = session
        self.updatesDirectory = updatesDirectory
    }

    static func defaultUpdatesDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches
            .appendingPathComponent("MemeMe", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
    }

    // MARK: - Download

    /// Downloads to updatesDirectory/<build>/MemeMe.dmg (replacing an older file) and checks the host before
    /// and after redirects, HTTP 200, the size (when given) and the SHA-256. Returns the DMG's URL.
    func download(_ manifest: UpdateManifest) async throws -> URL {
        guard UpdatePolicy.isTrustedDownloadURL(manifest.downloadURL) else { throw Failure.untrustedURL }

        let request = URLRequest(
            url: manifest.downloadURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: UpdateInstaller.downloadTimeout
        )
        let downloaded: (URL, URLResponse)
        do {
            downloaded = try await session.download(for: request)
        } catch {
            throw Failure.downloadFailed(error.localizedDescription)
        }
        let (temporaryURL, response) = downloaded

        // The session's temporary file is ours to move; do it before anything else can fail.
        let fileManager = FileManager.default
        let directory = updatesDirectory.appendingPathComponent(String(manifest.build), isDirectory: true)
        let destination = directory.appendingPathComponent(UpdateInstaller.dmgFileName, isDirectory: false)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw Failure.downloadFailed(error.localizedDescription)
        }

        do {
            try UpdateInstaller.verify(downloadedFile: destination, response: response, manifest: manifest)
        } catch {
            try? fileManager.removeItem(at: destination)
            installerLog.error("Downloaded update rejected: \(String(describing: error), privacy: .public)")
            throw error
        }
        return destination
    }

    private static func verify(downloadedFile file: URL, response: URLResponse, manifest: UpdateManifest) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure.downloadFailed("No HTTP response") }
        guard http.statusCode == 200 else { throw Failure.downloadFailed("HTTP \(http.statusCode)") }
        // Where the redirects ended up.
        guard let finalURL = http.url, UpdatePolicy.isTrustedDownloadURL(finalURL) else { throw Failure.untrustedURL }

        if let expectedSize = manifest.size {
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            let actualSize = (attributes?[.size] as? NSNumber)?.intValue ?? -1
            guard actualSize == expectedSize else { throw Failure.sizeMismatch }
        }

        let digest: String
        do {
            digest = try UpdateInstaller.sha256(ofFileAt: file)
        } catch {
            throw Failure.downloadFailed(error.localizedDescription)
        }
        guard digest == manifest.sha256.lowercased() else { throw Failure.checksumMismatch }
    }

    /// SHA-256 of a file as lowercase hex, read in 1 MB chunks (CryptoKit).
    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: hashChunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let hexDigits = Array("0123456789abcdef".utf8)
        var characters: [UInt8] = []
        characters.reserveCapacity(64)
        for byte in hasher.finalize() {
            characters.append(hexDigits[Int(byte >> 4)])
            characters.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: characters, as: UTF8.self)
    }

    // MARK: - Bundles

    /// Throws `.wrongBundle` unless the bundle's Info.plist has this CFBundleIdentifier and exactly this CFBundleVersion.
    static func validateBundle(at appURL: URL, bundleIdentifier: String, build: Int) throws {
        // Read the file itself: Bundle(url:) caches Info.plist per path.
        let plistURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: plistURL) else { throw Failure.wrongBundle("missing Info.plist") }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let info = plist as? [String: Any] else {
            throw Failure.wrongBundle("unreadable Info.plist")
        }
        guard let identifier = info["CFBundleIdentifier"] as? String, identifier == bundleIdentifier else {
            throw Failure.wrongBundle("bundle identifier")
        }
        guard let version = info["CFBundleVersion"] as? String, let bundleBuild = Int(version), bundleBuild == build else {
            throw Failure.wrongBundle("build")
        }
    }

    /// True for a ".app" directory that isn't under /AppTranslocation/, isn't on a read-only volume and whose
    /// parent folder is writable.
    static func canReplace(appAt url: URL) -> Bool {
        guard url.isFileURL, url.pathExtension.lowercased() == "app" else { return false }
        let path = url.path
        guard !path.contains("/AppTranslocation/") else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        if let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]), values.volumeIsReadOnly == true {
            return false
        }
        return FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }

    /// The staged bundle's location: a hidden sibling, `<parent>/.MemeMe-update-<build>.app`.
    static func stagedURL(for currentApp: URL, build: Int) -> URL {
        currentApp.deletingLastPathComponent().appendingPathComponent(".MemeMe-update-\(build).app", isDirectory: true)
    }

    // MARK: - Signing team

    /// The value of the "TeamIdentifier=" line (a line of its own) in `codesign -dv --verbose=2` output; nil when
    /// the line is missing, says "not set" (ad-hoc) or isn't a Team ID (10 characters A-Z, 0-9).
    static func parseTeamIdentifier(fromCodesignOutput output: String) -> String? {
        let key = "TeamIdentifier="
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix(key) {
            let value = String(line.dropFirst(key.count))
            return isTeamIdentifier(value) ? value : nil
        }
        return nil
    }

    /// The code requirement "signed with a Developer ID Application certificate of this team"; nil unless `team`
    /// is a Team ID (10 characters A-Z, 0-9), so nothing else ever reaches the requirement text.
    static func developerIDRequirement(team: String) -> String? {
        guard isTeamIdentifier(team) else { return nil }
        // Apple-anchored, issued by the Developer ID CA (…6.2.6), a Developer ID Application leaf (…6.1.13).
        let requirement: String = "=anchor apple generic"
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(team)\""
        return requirement
    }

    /// The Team ID the app at `url` is signed with: `codesign -dv --verbose=2` (run off the main actor), parsed
    /// with `parseTeamIdentifier(fromCodesignOutput:)`. nil on any failure, for ad-hoc and for unsigned code.
    static func teamIdentifier(ofAppAt url: URL) async -> String? {
        let details = await UpdateInstaller.run(
            UpdateInstaller.codesign,
            ["-dv", "--verbose=2", url.path],
            outputLimit: UpdateInstaller.signingDetailsLimit
        )
        guard details.status == 0 else { return nil }
        return parseTeamIdentifier(fromCodesignOutput: details.output)
    }

    /// Checks the downloaded DMG itself (CI signs MemeMe.dmg with the same Developer ID) before it is mounted or
    /// shown in Finder: `codesign --verify --strict -R developerIDRequirement(team:) <dmg>`, run off the main
    /// actor. Any exit status other than 0, or a `requiredTeam` that isn't a Team ID: `.signatureInvalid`.
    static func verifyDMGSignature(_ dmg: URL, requiredTeam: String) async throws {
        guard let requirement = developerIDRequirement(team: requiredTeam) else {
            installerLog.error("The required signing team isn't a Team ID")
            throw Failure.signatureInvalid
        }
        let check = await UpdateInstaller.run(
            UpdateInstaller.codesign,
            ["--verify", "--strict", "-R", requirement, dmg.path]
        )
        guard check.status == 0 else {
            installerLog.error("The update's disk image isn't signed with MemeMe's Developer ID (\(check.status, privacy: .public))")
            throw Failure.signatureInvalid
        }
    }

    /// Exactly 10 characters, each A-Z or 0-9 (^[A-Z0-9]{10}$).
    private static func isTeamIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 10 && bytes.allSatisfy { (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) }
    }

    // MARK: - Staging

    /// Mounts the DMG read-only (hdiutil attach -nobrowse -readonly -noautoopen -mountpoint), finds the .app
    /// (MemeMe.app first), validates it, checks `codesign --verify --deep --strict` and, when `requiredTeam` is
    /// set, also `-R developerIDRequirement(team:)` (unsatisfied, or not a Team ID: `.signatureInvalid`), copies
    /// it with `ditto` to `stagedURL(for:build:)`, and always detaches. Runs the tools off the main actor.
    func stage(dmg: URL, manifest: UpdateManifest, currentApp: URL, bundleIdentifier: String,
               requiredTeam: String? = nil) async throws -> URL {
        guard UpdateInstaller.canReplace(appAt: currentApp) else { throw Failure.notReplaceable }

        let fileManager = FileManager.default
        let mountPoint = updatesDirectory
            .appendingPathComponent(String(manifest.build), isDirectory: true)
            .appendingPathComponent("mount-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true, attributes: nil)
        } catch {
            throw Failure.mountFailed(error.localizedDescription)
        }

        let attach = await UpdateInstaller.run(UpdateInstaller.hdiutil, [
            "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path, dmg.path,
        ])
        guard attach.status == 0 else {
            _ = rmdir(mountPoint.path)
            installerLog.error("hdiutil attach failed (\(attach.status, privacy: .public))")
            throw Failure.mountFailed(attach.output)
        }

        let staged: Result<URL, Error>
        do {
            let app = try await copyApp(
                fromVolume: mountPoint,
                manifest: manifest,
                currentApp: currentApp,
                bundleIdentifier: bundleIdentifier,
                requiredTeam: requiredTeam
            )
            staged = .success(app)
        } catch {
            staged = .failure(error)
        }

        let detach = await UpdateInstaller.run(UpdateInstaller.hdiutil, ["detach", mountPoint.path, "-force"])
        if detach.status != 0 {
            installerLog.error("hdiutil detach failed (\(detach.status, privacy: .public))")
        }
        // rmdir only removes an empty folder, so a volume that is still mounted is never walked.
        _ = rmdir(mountPoint.path)

        return try staged.get()
    }

    /// Validates the app on the mounted volume and copies it next to the running app.
    private func copyApp(fromVolume volume: URL, manifest: UpdateManifest, currentApp: URL, bundleIdentifier: String,
                         requiredTeam: String?) async throws -> URL {
        guard let app = UpdateInstaller.findApp(in: volume) else { throw Failure.appNotFound }
        try UpdateInstaller.validateBundle(at: app, bundleIdentifier: bundleIdentifier, build: manifest.build)

        let signature = await UpdateInstaller.run(UpdateInstaller.codesign, ["--verify", "--deep", "--strict", app.path])
        guard signature.status == 0 else {
            installerLog.error("codesign rejected the update (\(signature.status, privacy: .public))")
            throw Failure.signatureInvalid
        }

        // A Developer ID build only takes updates signed by its own team (codesign exits 3 when -R isn't met).
        if let requiredTeam {
            guard let requirement = UpdateInstaller.developerIDRequirement(team: requiredTeam) else {
                installerLog.error("The required signing team isn't a Team ID")
                throw Failure.signatureInvalid
            }
            let team = await UpdateInstaller.run(
                UpdateInstaller.codesign,
                ["--verify", "--deep", "--strict", "-R", requirement, app.path]
            )
            guard team.status == 0 else {
                installerLog.error("The update isn't signed with MemeMe's Developer ID (\(team.status, privacy: .public))")
                throw Failure.signatureInvalid
            }
        }

        let fileManager = FileManager.default
        let staged = UpdateInstaller.stagedURL(for: currentApp, build: manifest.build)
        try? fileManager.removeItem(at: staged)
        let copy = await UpdateInstaller.run(UpdateInstaller.ditto, [app.path, staged.path])
        guard copy.status == 0 else {
            try? fileManager.removeItem(at: staged)
            throw Failure.stagingFailed(copy.output)
        }
        do {
            try UpdateInstaller.validateBundle(at: staged, bundleIdentifier: bundleIdentifier, build: manifest.build)
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }
        return staged
    }

    /// "MemeMe.app" on the volume, else the first .app by name.
    private static func findApp(in volume: URL) -> URL? {
        let fileManager = FileManager.default
        func isDirectory(_ url: URL) -> Bool {
            var directory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
        }
        let preferred = volume.appendingPathComponent("MemeMe.app", isDirectory: true)
        if isDirectory(preferred) { return preferred }
        let names = (try? fileManager.contentsOfDirectory(atPath: volume.path)) ?? []
        for name in names.sorted() where name.lowercased().hasSuffix(".app") {
            let candidate = volume.appendingPathComponent(name, isDirectory: true)
            if isDirectory(candidate) { return candidate }
        }
        return nil
    }

    /// Runs a tool on a global queue, so neither the main thread nor the cooperative pool blocks on it.
    /// Keeps the first `outputLimit` characters of its output.
    private static func run(_ executable: String, _ arguments: [String],
                            outputLimit: Int = UpdateInstaller.toolOutputLimit) async -> ToolResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<ToolResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: UpdateInstaller.runBlocking(executable, arguments, outputLimit: outputLimit))
            }
        }
    }

    private static func runBlocking(_ executable: String, _ arguments: [String], outputLimit: Int) -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (status: -1, output: error.localizedDescription)
        }
        // Read to EOF before waiting: a full pipe buffer would otherwise block the tool forever.
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (status: process.terminationStatus, output: String(output.prefix(outputLimit)))
    }

    // MARK: - Relaunch

    /// The relaunch script (POSIX sh). Arguments: $1 pid, $2 current app, $3 staged app, $4 open command.
    /// Waits up to 30 s for the pid to exit, moves current aside, moves staged into place (restoring current if
    /// that fails), deletes the old copy, then runs `$4 "$2"`. Paths are never interpolated into the text.
    static let relaunchScript: String = #"""
    #!/bin/sh
    # MemeMe updater: waits for the old process, swaps in the new bundle, opens it.
    pid="$1"; current="$2"; staged="$3"; opener="$4"
    # Up to 30 s (300 x 0.1 s) for MemeMe to quit.
    i=0
    while kill -0 "$pid" 2>/dev/null; do
      i=$((i + 1))
      if [ "$i" -gt 300 ]; then exit 1; fi
      sleep 0.1
    done
    backup="$(dirname "$current")/.MemeMe-old-$$.app"
    if [ -d "$staged" ] && mv "$current" "$backup"; then
      if mv "$staged" "$current"; then
        rm -rf "$backup"
      else
        mv "$backup" "$current"
      fi
    fi
    rm -rf "$staged"
    "$opener" "$current"
    rm -f "$0"
    """#

    /// Writes `relaunchScript` to a temporary file and starts `/bin/sh <file> pid current staged openCommand`
    /// detached (no waiting, output to /dev/null).
    func launchRelauncher(pid: Int32, current: URL, staged: URL, openCommand: String = "/usr/bin/open") throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemeMe-relaunch-\(UUID().uuidString).sh", isDirectory: false)
        do {
            try UpdateInstaller.relaunchScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            throw Failure.relaunchFailed(error.localizedDescription)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path, String(pid), current.path, staged.path, openCommand]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: scriptURL)
            throw Failure.relaunchFailed(error.localizedDescription)
        }
        installerLog.info("Relauncher started for build swap")
    }

    /// Deletes updatesDirectory and `.MemeMe-update-*.app` leftovers next to `currentApp`. Never throws.
    func cleanUp(currentApp: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: updatesDirectory)
        // `.MemeMe-old-*.app` is what the relaunch script leaves when it is interrupted mid-swap.
        let parent = currentApp.deletingLastPathComponent()
        let names = (try? fileManager.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in names where name.hasSuffix(".app") && (name.hasPrefix(".MemeMe-update-") || name.hasPrefix(".MemeMe-old-")) {
            try? fileManager.removeItem(at: parent.appendingPathComponent(name, isDirectory: true))
        }
    }
}
