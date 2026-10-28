import AppKit
import Combine
import Foundation
import MemeMeCore
import os

private let updateLog = Logger(subsystem: "com.mememe.app", category: "update")

/// Checks the feed, publishes what's available and runs the one-click update (DESIGN.md › Updates).
@MainActor final class UpdateChecker: ObservableObject {
    enum Phase: Equatable { case idle, checking, downloading, installing }

    /// A newer build this Mac can run; nil otherwise.
    @Published private(set) var available: UpdateManifest? = nil
    @Published private(set) var phase: Phase = .idle

    /// nil = updates off (no checks, no UI).
    let feedURL: URL?
    /// CFBundleShortVersionString, "0" when missing.
    let installedVersion: String
    /// CFBundleVersion, 0 when missing or not a number.
    let installedBuild: Int

    /// Runs when an install starts (footer, menu item or the "is available" alert); AppModel closes the panel here.
    var willInstall: (@MainActor () -> Void)?

    private let session: URLSession
    private let installer: UpdateInstaller
    private let defaults: UserDefaults

    /// When the feed last answered with a usable manifest.
    private var lastCheck: Date?
    private var scheduler: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var started = false
    /// The running app's Team ID, looked up once, when the first install starts; nil inside for ad-hoc and
    /// local builds.
    private var runningTeamLookup: Task<String?, Never>?

    /// The build that ran last time, for the one-time "Updated to MemeMe …" HUD.
    private static let lastLaunchedBuildKey = "lastLaunchedBuild"
    private static let feedURLInfoKey = "MemeMeUpdateFeedURL"
    private static let fallbackBundleIdentifier = "com.mememe.app"
    private static let alertNoteLimit = 5
    private static let updatedHUDDelay: TimeInterval = 1.5
    /// After wake, give Wi-Fi a moment to reconnect before checking.
    private static let wakeCheckDelay: TimeInterval = 10
    /// Lets the "Restarting…" HUD show before quitting.
    private static let quitDelay: TimeInterval = 0.8

    var isEnabled: Bool { feedURL != nil }

    /// "1.0 (57)"
    var installedDisplayVersion: String { "\(installedVersion) (\(installedBuild))" }

    /// Reads MemeMeUpdateFeedURL (empty or invalid = nil), CFBundleShortVersionString and CFBundleVersion.
    convenience init(bundle: Bundle) {
        let build = UpdateChecker.infoString(bundle, "CFBundleVersion").flatMap { Int($0) } ?? 0
        self.init(
            feedURL: UpdateChecker.feedURLFromInfo(of: bundle),
            installedVersion: UpdateChecker.infoString(bundle, "CFBundleShortVersionString") ?? "0",
            installedBuild: build
        )
    }

    init(feedURL: URL?, installedVersion: String, installedBuild: Int,
         session: URLSession = .shared, installer: UpdateInstaller = UpdateInstaller(), defaults: UserDefaults = .standard) {
        self.feedURL = feedURL
        self.installedVersion = installedVersion
        self.installedBuild = installedBuild
        self.session = session
        self.installer = installer
        self.defaults = defaults
    }

    /// A trimmed, non-empty Info.plist string.
    private static func infoString(_ bundle: Bundle, _ key: String) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Only an absolute https URL turns updates on.
    private static func feedURLFromInfo(of bundle: Bundle) -> URL? {
        guard let text = infoString(bundle, feedURLInfoKey),
              let url = URL(string: text),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    // MARK: - Schedule

    /// No-op when disabled. Cleans leftovers, shows "Updated to MemeMe …" once after an update (UserDefaults
    /// key "lastLaunchedBuild"), checks after 20 s, then every 6 h, and after wake when the last check is > 1 h old.
    func start() {
        guard isEnabled, !started else { return }
        started = true

        let installer = self.installer
        let currentApp = Bundle.main.bundleURL
        Task.detached(priority: .utility) {
            installer.cleanUp(currentApp: currentApp)
        }

        let lastLaunchedBuild = defaults.integer(forKey: UpdateChecker.lastLaunchedBuildKey)
        if lastLaunchedBuild > 0, installedBuild > lastLaunchedBuild {
            let message = "Updated to MemeMe \(installedDisplayVersion)"
            Task {
                try? await Task.sleep(nanoseconds: UpdateChecker.nanoseconds(UpdateChecker.updatedHUDDelay))
                HUDController.shared.show(message)
            }
        }
        defaults.set(installedBuild, forKey: UpdateChecker.lastLaunchedBuildKey)

        scheduler = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UpdateChecker.nanoseconds(UpdatePolicy.firstCheckDelay))
            while !Task.isCancelled {
                if let checker = self {
                    _ = await checker.check()
                } else {
                    return
                }
                try? await Task.sleep(nanoseconds: UpdateChecker.nanoseconds(UpdatePolicy.checkInterval))
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let checker = self else { return }
                checker.systemDidWake()
            }
        }
    }

    private func systemDidWake() {
        if let lastCheck, Date().timeIntervalSince(lastCheck) < UpdatePolicy.wakeCheckAge { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UpdateChecker.nanoseconds(UpdateChecker.wakeCheckDelay))
            _ = await self?.check()
        }
    }

    private static func nanoseconds(_ interval: TimeInterval) -> UInt64 {
        UInt64(max(0, interval) * 1_000_000_000)
    }

    // MARK: - Checking

    /// One request (no cache, 15 s timeout). Sets `available`; returns nil and changes nothing when the request,
    /// the HTTP status, the JSON or the download URL's host fails. Never shows UI.
    @discardableResult func check() async -> UpdateDecision? {
        guard let feedURL else { return nil }
        // A check never hides a download or install in progress.
        let marksPhase = phase == .idle
        if marksPhase { phase = .checking }
        defer {
            if marksPhase, phase == .checking { phase = .idle }
        }

        let manifest: UpdateManifest
        do {
            manifest = try await UpdateFeed.fetch(feedURL, session: session)
        } catch {
            updateLog.info("Update check failed: \(String(describing: error), privacy: .public)")
            return nil
        }

        let decision = UpdatePolicy.decide(
            installedBuild: installedBuild,
            manifest: manifest,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersion
        )
        var offered: UpdateManifest?
        if case .available(let newer) = decision {
            offered = newer
        }
        // Assign only on change, so observers don't refresh after every quiet check.
        if available != offered {
            available = offered
        }
        lastCheck = Date()
        updateLog.info("Update check: feed has build \(manifest.build, privacy: .public), installed \(self.installedBuild, privacy: .public)")
        return decision
    }

    /// "Check for Updates…": runs `check()` and answers in an alert (DESIGN.md strings).
    func checkFromMenu() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let decision = await self.check()
            self.presentCheckResult(decision)
        }
    }

    private func presentCheckResult(_ decision: UpdateDecision?) {
        guard let decision else {
            showAlert(title: "Couldn’t check for updates", text: "Check your internet connection and try again.")
            return
        }
        switch decision {
        case .upToDate:
            showAlert(title: "You’re up to date", text: "MemeMe \(installedDisplayVersion) is the newest version.")
        case .available(let manifest):
            let response = showAlert(
                title: "MemeMe \(manifest.displayVersion) is available",
                text: availableDetails(for: manifest),
                buttons: ["Update", "Later"]
            )
            if response == .alertFirstButtonReturn {
                installAvailableUpdate()
            }
        case .requiresNewerSystem(let manifest):
            let minimum = manifest.minimumSystemVersion ?? ""
            let title = minimum.isEmpty
                ? "MemeMe \(manifest.displayVersion) needs a newer macOS"
                : "MemeMe \(manifest.displayVersion) needs macOS \(minimum)"
            showAlert(title: title, text: "Your copy keeps working. Update macOS to get the new version.")
        }
    }

    /// Up to 5 notes as "• note" lines, a blank line, then "You have 1.0 (57)."
    private func availableDetails(for manifest: UpdateManifest) -> String {
        let installed = "You have \(installedDisplayVersion)."
        let notes = manifest.notes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(UpdateChecker.alertNoteLimit)
            .map { "• \($0)" }
        guard !notes.isEmpty else { return installed }
        return notes.joined(separator: "\n") + "\n\n" + installed
    }

    // MARK: - Installing

    /// Download, verify, stage, relaunch; the fallbacks and alerts from DESIGN.md. Ignored unless phase is .idle
    /// (or a background check, which the footer keeps offering through) and an update is available.
    func installAvailableUpdate() {
        guard phase == .idle || phase == .checking, let manifest = available else { return }
        willInstall?()
        phase = .downloading
        HUDController.shared.show("Downloading MemeMe \(manifest.displayVersion)…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.install(manifest)
        }
    }

    private func install(_ manifest: UpdateManifest) async {
        let currentApp = Bundle.main.bundleURL
        // Runs while the DMG downloads.
        let teamLookup = lookUpRunningTeam()
        let dmg: URL
        do {
            dmg = try await installer.download(manifest)
        } catch {
            phase = .idle
            updateLog.error("Update download failed: \(String(describing: error), privacy: .public)")
            if let failure = error as? UpdateInstaller.Failure, failure.isVerificationFailure {
                showVerificationFailure(manifest)
            } else {
                showDownloadFailure(manifest)
            }
            return
        }

        // A Developer ID build only takes its own team's Developer ID builds; ad-hoc builds get the integrity check.
        let requiredTeam = await teamLookup.value
        updateLog.info("Update signing team required: \(requiredTeam ?? "none", privacy: .public)")
        // The DMG's own signature is checked before it is mounted or opened in Finder (every fallback below).
        if let requiredTeam {
            do {
                try await UpdateInstaller.verifyDMGSignature(dmg, requiredTeam: requiredTeam)
            } catch {
                phase = .idle
                updateLog.error("Update disk image rejected: \(String(describing: error), privacy: .public)")
                try? FileManager.default.removeItem(at: dmg)
                showVerificationFailure(manifest)
                return
            }
        }

        // Translocated, read-only or unwritable location: the user finishes in Finder.
        guard UpdateInstaller.canReplace(appAt: currentApp) else {
            phase = .idle
            finishInFinder(dmg)
            return
        }

        phase = .installing
        var stagedApp: URL?
        do {
            let staged = try await installer.stage(
                dmg: dmg,
                manifest: manifest,
                currentApp: currentApp,
                bundleIdentifier: Bundle.main.bundleIdentifier ?? UpdateChecker.fallbackBundleIdentifier,
                requiredTeam: requiredTeam
            )
            stagedApp = staged
            try installer.launchRelauncher(
                pid: ProcessInfo.processInfo.processIdentifier,
                current: currentApp,
                staged: staged
            )
        } catch {
            phase = .idle
            updateLog.error("Update install failed: \(String(describing: error), privacy: .public)")
            if let stagedApp {
                try? FileManager.default.removeItem(at: stagedApp)
            }
            if let failure = error as? UpdateInstaller.Failure, failure.isVerificationFailure {
                // An unverified DMG is never opened.
                try? FileManager.default.removeItem(at: dmg)
                showVerificationFailure(manifest)
            } else if FileManager.default.fileExists(atPath: dmg.path) {
                finishInFinder(dmg)
            } else {
                showDownloadFailure(manifest)
            }
            return
        }

        HUDController.shared.show("Restarting to finish the update…")
        try? await Task.sleep(nanoseconds: UpdateChecker.nanoseconds(UpdateChecker.quitDelay))
        NSApplication.shared.terminate(nil)
    }

    /// Starts the running app's Team ID lookup (`codesign`, off the main actor) the first time; later calls
    /// return the same task.
    private func lookUpRunningTeam() -> Task<String?, Never> {
        if let lookup = runningTeamLookup { return lookup }
        let app = Bundle.main.bundleURL
        let lookup = Task.detached(priority: .userInitiated) {
            await UpdateInstaller.teamIdentifier(ofAppAt: app)
        }
        runningTeamLookup = lookup
        return lookup
    }

    // MARK: - Alerts

    /// [OK] quits MemeMe: Finder can't replace a running app, and a copy opened next to it would run twice.
    private func finishInFinder(_ dmg: URL) {
        _ = NSWorkspace.shared.open(dmg)
        showAlert(
            title: "Finish updating in Finder",
            text: "Drag MemeMe into your Applications folder and choose Replace, then open it again."
        )
        NSApplication.shared.terminate(nil)
    }

    private func showDownloadFailure(_ manifest: UpdateManifest) {
        offerDownloadPage(
            for: manifest,
            title: "Couldn’t download the update",
            text: "Check your internet connection, or download it from the website."
        )
    }

    private func showVerificationFailure(_ manifest: UpdateManifest) {
        offerDownloadPage(
            for: manifest,
            title: "The update didn’t check out",
            text: "MemeMe didn’t install it. Try again later, or download it from the website."
        )
    }

    /// [Open Download Page] opens the release page, or the DMG URL when the manifest has no page.
    private func offerDownloadPage(for manifest: UpdateManifest, title: String, text: String) {
        let response = showAlert(title: title, text: text, buttons: ["Open Download Page", "Cancel"])
        guard response == .alertFirstButtonReturn else { return }
        _ = NSWorkspace.shared.open(manifest.releasePageURL ?? manifest.downloadURL)
    }

    @discardableResult
    private func showAlert(title: String, text: String, buttons: [String] = ["OK"]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        for button in buttons {
            alert.addButton(withTitle: button)
        }
        NSApplication.shared.activate()
        return alert.runModal()
    }
}

/// The network half of a check; runs off the main actor.
private enum UpdateFeed {
    static let timeout: TimeInterval = 15

    enum Failure: Error {
        case notHTTP
        case httpStatus(Int)
        case untrustedDownloadURL
    }

    static func fetch(_ feedURL: URL, session: URLSession) async throws -> UpdateManifest {
        let request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.notHTTP }
        guard http.statusCode == 200 else { throw Failure.httpStatus(http.statusCode) }
        let manifest = try UpdateManifest.decode(from: data)
        guard UpdatePolicy.isTrustedDownloadURL(manifest.downloadURL) else { throw Failure.untrustedDownloadURL }
        return manifest
    }
}
