import AppKit
import AVFoundation
import Combine
import Foundation
import MemeMeCore
import os
import QuartzCore
import UniformTypeIdentifiers

private let modelLog = Logger(subsystem: "com.mememe.app", category: "app")

// MARK: - Panel state

enum PanelMode: Equatable { case prompt, warming, live, text, image, moreLike, cameraOff, cameraBusy }

enum HintAction: Equatable { case clearPins, backToFace, keepImage, turnOnCamera, useCamera }

struct PanelHint: Equatable {
    var title: String
    var subtitle: String?
    var actionTitle: String?
    var action: HintAction?
}

enum FooterState: Equatable { case legend, libraryOffer, indexing(count: Int), added(IndexBatch), update(UpdateManifest) }

struct NamingCandidate: Identifiable, Equatable {
    let personID: UUID
    let stickerCount: Int
    let sample: LibraryItem?
    var id: UUID { personID }
}

struct NamingPrompt: Equatable {
    var name: String
    var candidates: [NamingCandidate]
}

enum DropOutcome { case kept(IndexBatch), stickers(StickerBatch), nothing }

/// Hint copy (exact strings from DESIGN.md).
private enum HintCopy {
    static let promptTitle = "Make a face."
    static let promptSubtitle = "That’s the search. There’s no button to press."
    static let warmingTitle = "Starting camera…"
    static let warmingSubtitle = "Your recent picks are ready below."
    static let liveTitle = "Make a face. Results follow it."
    static let livePoseTitle = "Matching your face and pose"
    static let liveSubtitle = "Click your eyes or mouth to focus on them."
    static let holdingSubtitle = "New face? Keep holding…"
    static let noFaceTitle = "Can’t see your face"
    static let noFaceSubtitle = "Try more light, or just type."
    static let clearAction = "Clear"
    static let textTitle = "Searching by words"
    /// Also shown when a face token is kept (DESIGN.md): the camera then only feeds the dimmed mirror.
    static let textSubtitle = "The camera is off while you type."
    static let imageTitle = "Searching with your image"
    static let imageSubtitle = "It isn’t saved unless you keep it."
    static let keepAction = "Keep it"
    static let keptAction = "Kept · Undo"
    static let backToFaceAction = "Back to your face"
    static let cameraOffTitle = "No camera"
    static let cameraOffSubtitle = "Drop, paste or type instead."
    static let cameraOffAction = "Turn on camera"
    static let cameraBusyTitle = "Your camera is in use"
    static let cameraBusySubtitle = "Type or drop instead, or use it anyway."
    static let cameraBusyAction = "Use camera"
}

/// What the grid currently shows, so library changes can refresh it in place.
private enum ResultSource { case recent, expression, text, image, moreLike }

/// A dropped or pasted query image, reduced to what the ranker needs.
private struct ImageQueryValues: Sendable {
    let featurePrint: [Float]?
    let face: FaceFeatures?
    let intensity: Double
}

/// Analyzes a query image. Synchronous Vision work: call off the main actor.
private func analyzeQueryImage(at url: URL) -> ImageQueryValues? {
    guard let analysis = try? ImageAnalyzer.analyze(url: url, includeText: false) else { return nil }
    return ImageQueryValues(featurePrint: analysis.featurePrint, face: analysis.face, intensity: analysis.intensity)
}

/// Copies a file into a fresh temporary folder under a neutral name, for dragging into other apps.
private func makeDragCopy(of url: URL, named fileName: String) -> URL? {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent("MemeMeDrag", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let destination = directory.appendingPathComponent(fileName, isDirectory: false)
        try fileManager.copyItem(at: url, to: destination)
        return destination
    } catch {
        return nil
    }
}

// MARK: - AppModel

/// Orchestrates the panel: camera → peak-hold → mood → local + web ranking, typed and image queries,
/// committing to the clipboard, the self-filling library and menu-bar drops.
@MainActor final class AppModel: ObservableObject {
    @Published var queryText: String = "" {
        didSet {
            guard queryText != oldValue, !isSettingQueryTextInternally else { return }
            queryTextWasEdited(previous: oldValue)
        }
    }
    @Published private(set) var mode: PanelMode = .prompt
    @Published private(set) var results: [RankedResult] = []         // ≤ Theme.resultLimit
    @Published private(set) var newResultIDs: Set<UUID> = []          // amber ring for 600 ms
    @Published var focusedIndex: Int = 0
    @Published private(set) var pins: Set<FaceRegion> = []
    @Published private(set) var hint = PanelHint(title: HintCopy.promptTitle, subtitle: HintCopy.promptSubtitle, actionTitle: nil, action: nil)
    @Published private(set) var footer: FooterState = .legend
    @Published private(set) var showSetupCard: Bool = false
    @Published private(set) var queryImageURL: URL?                   // image / moreLike mirror content
    @Published private(set) var moreLikeItem: LibraryItem?
    @Published private(set) var imageKept: Bool = false
    @Published private(set) var showsFaceToken: Bool = false
    @Published private(set) var naming: NamingPrompt?
    @Published private(set) var holdProgress: Double = 0
    @Published private(set) var hotKeyAvailable: Bool = true
    @Published private(set) var isPanelVisible: Bool = false

    let store: LibraryStore
    let camera: CameraController
    let indexer: LibraryIndexer
    let web: WebDiscover
    let friends: FriendService
    /// Update checks and the one-click install; disabled when the bundle has no feed URL (local builds, tests).
    let updates: UpdateChecker

    var onRequestClose: (() -> Void)?

    /// Opening the panel with camera access undecided asks for it 0.6 s later (first run).
    /// Tests turn this off so opening the panel never schedules the system prompt.
    var requestsCameraAccessOnShow = true

    // MARK: Timing (DESIGN.md)

    /// ↵ is ignored this soon after the last edit of the search field.
    private static let enterGuard: TimeInterval = 0.3
    /// A number key is ignored this soon after a late merge put a different tile in its slot.
    private static let reshuffleGuard: TimeInterval = 0.8
    private static let textDebounceNanoseconds: UInt64 = 80_000_000
    private static let newRingNanoseconds: UInt64 = 600_000_000
    private static let saveDelayNanoseconds: UInt64 = 2_000_000_000
    private static let cameraPromptDelay: TimeInterval = 0.6
    private static let faceMissingDelay: TimeInterval = 1.5
    /// Typing that starts this soon after opening stops the camera instead of keeping the face token.
    private static let typingStopsCameraWindow: TimeInterval = 1.0
    /// A HUD says "Copying…" when fetching a web GIF takes longer than this.
    private static let slowCopyNanoseconds: UInt64 = 150_000_000
    /// Web results stop filling the grid this long after its search; later ones are cached for next time.
    private static let webFetchTimeout: TimeInterval = 8
    /// Streamed web results are merged at most this often, so the grid settles instead of jittering.
    private static let webBatchNanoseconds: UInt64 = 250_000_000
    private static let poseActiveThreshold = 0.3
    private static let keptSource = "Kept"

    // MARK: Private state

    private var tracker: PeakHoldTracker
    private var previousBundleID: String?
    private var shownAt: TimeInterval = 0
    private var liveSince: TimeInterval?
    private var faceMissing = false
    private var userInteracted = false
    private var useCameraDespiteOtherApp = false
    private var resultSource: ResultSource = .recent
    private var currentWeights: FeatureWeights = .uniform
    private var faceTokenSample: ExpressionSample?
    private var faceTokenWeights: FeatureWeights = .uniform
    private var imageQuery: ImageQueryValues?
    private var keptImageBatch: IndexBatch?
    private var isKeepingImage = false
    private var isSettingQueryTextInternally = false
    private var lastTextEditAt: TimeInterval = 0
    /// When a late merge last put a different tile in each position.
    private var slotChangedAt: [Int: TimeInterval] = [:]
    /// Starts an expression's web search while it is still being held.
    private var earlyMood = EarlyMoodTrigger()
    private var textBeganAt: TimeInterval?
    private var searchGeneration = 0
    private var imageGeneration = 0
    /// Bumped on every open, so a pick that finishes late never acts on a newer panel.
    private var sessionID = 0
    /// The newest pick; an older one that finishes later leaves the clipboard alone.
    private var commitToken = 0
    /// The open whose pick is still being copied (one pick at a time per open).
    private var committingSession: Int?
    private var setupCardShownThisSession = false
    private var libraryOfferHiddenThisSession = false
    private var shownSummaryID: UUID?

    private var textDebounceTask: Task<Void, Never>?
    private var webTask: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?
    private var cameraAccessTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var indexerObservation: AnyCancellable?
    private var updatesObservation: AnyCancellable?

    private var limit: Int { Theme.resultLimit }

    convenience init(store: LibraryStore) {
        self.init(store: store, webCacheRoot: nil)
    }

    /// `webCacheRoot`: where web discovery keeps its cache (nil = ~/Library/Caches/MemeMe/Web); tests pass a temp folder.
    init(store: LibraryStore, webCacheRoot: URL?) {
        self.store = store
        self.camera = CameraController()
        self.indexer = LibraryIndexer(store: store)
        self.web = WebDiscover(store: store, cacheRoot: webCacheRoot)
        self.friends = FriendService(store: store)
        self.updates = UpdateChecker(bundle: .main)
        self.tracker = PeakHoldTracker(baseline: store.settings.baseline)

        camera.onSample = { [weak self] sample in
            self?.handleSample(sample)
        }
        indexer.onLibraryChanged = { [weak self] in
            self?.libraryDidChange()
        }
        indexerObservation = indexer.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the new value is stored: read it on the next main-actor turn.
            let model = self
            Task { @MainActor in
                model?.refreshFooter()
            }
        }
        updatesObservation = updates.objectWillChange.sink { [weak self] _ in
            // Same as the indexer: the new update or phase is readable on the next main-actor turn.
            let model = self
            Task { @MainActor in
                model?.refreshFooter()
            }
        }
        // Every Update (footer, menu item, "is available" alert) closes the panel first.
        updates.willInstall = { [weak self] in
            guard let self, self.isPanelVisible else { return }
            self.onRequestClose?()
        }
    }

    /// After launch: start monitoring, watching folders, warming the web cache and checking for updates.
    func start() {
        SystemConditions.startMonitoring()
        syncLoginItem()
        indexer.startWatching()
        web.prefetch(Mood.prefetchOrder)
        web.pruneCache()
        updates.start()
        refreshFooter()
    }

    func setHotKeyAvailable(_ available: Bool) {
        if hotKeyAvailable != available {
            hotKeyAvailable = available
        }
    }

    // MARK: - Panel lifecycle

    func panelWillShow(previousApp: NSRunningApplication?) {
        sessionID += 1
        let ownBundleID = Bundle.main.bundleIdentifier
        if let bundleID = previousApp?.bundleIdentifier, bundleID != ownBundleID {
            previousBundleID = bundleID
        } else {
            previousBundleID = nil
        }
        isPanelVisible = true
        shownAt = CACurrentMediaTime()
        resetForNewSession()
        enterCameraMode()
        showRecentResults()
        if requestsCameraAccessOnShow && camera.authorization == .notDetermined {
            scheduleCameraAccessRequest(after: AppModel.cameraPromptDelay)
        }
        refreshFooter()
        refreshHint()
    }

    func panelDidHide() {
        isPanelVisible = false
        cancelSessionTasks()
        camera.stop()
        if holdProgress != 0 { holdProgress = 0 }
        if showSetupCard { showSetupCard = false }
        if let shownID = shownSummaryID, indexer.pendingSummary?.id == shownID {
            indexer.clearPendingSummary()
        }
        shownSummaryID = nil
        persistBaseline()
        saveSoon()
    }

    // MARK: - Input

    func commit(index: Int) {
        guard index >= 0, index < results.count, committingSession != sessionID else { return }
        let item = results[index].item
        commitToken += 1
        let token = commitToken
        let session = sessionID
        let appBundleID = previousBundleID
        committingSession = session
        Task { [weak self] in
            await self?.performCommit(item, token: token, session: session, appBundleID: appBundleID)
        }
    }

    func commitFocused() {
        // ↵ pressed to "run the search" right after typing must not copy something.
        guard CACurrentMediaTime() - lastTextEditAt >= AppModel.enterGuard else { return }
        commit(index: focusedIndex)
    }

    /// Number keys pick by position, so one pressed just as a late merge swapped that tile would copy
    /// something the user never saw.
    func commitNumbered(index: Int) {
        if let changedAt = slotChangedAt[index], CACurrentMediaTime() - changedAt < AppModel.reshuffleGuard {
            return
        }
        commit(index: index)
    }

    func moveFocus(dx: Int, dy: Int) {
        guard !results.isEmpty else { return }
        let columns = max(1, Theme.columns)
        let rows = max(1, Theme.rows)
        let current = min(max(focusedIndex, 0), results.count - 1)
        let column = min(max(current % columns + dx, 0), columns - 1)
        let row = min(max(current / columns + dy, 0), rows - 1)
        let target = min(row * columns + column, results.count - 1)
        userInteracted = true
        if target != focusedIndex {
            focusedIndex = target
            prefetchFocused()
        }
    }

    func hover(index: Int) {
        guard index >= 0, index < results.count else { return }
        userInteracted = true
        if focusedIndex != index {
            focusedIndex = index
            prefetchFocused()
        }
    }

    func togglePin(_ region: FaceRegion) {
        if pins.contains(region) {
            pins.remove(region)
        } else {
            pins.insert(region)
        }
        if mode == .live, tracker.query != nil {
            runExpressionSearch(animate: true)
        }
        refreshHint()
    }

    /// Esc: the first press clears refinements (text, pins, more-like-this, image query); returns false when there were none.
    func handleEscape() -> Bool {
        // The You're-set card closes with the panel.
        if showSetupCard { return false }
        let hadText = !queryText.isEmpty || mode == .text || naming != nil
        let hadQueryImage = mode == .image || mode == .moreLike
        let hadPins = !pins.isEmpty
        guard hadText || hadQueryImage || hadPins else { return false }

        if hadPins { pins = [] }
        if hadText || hadQueryImage {
            clearTextState()
            returnToFace()
        } else {
            if mode == .live, tracker.query != nil {
                runExpressionSearch(animate: false)
            }
            refreshHint()
        }
        return true
    }

    /// Space with an empty search field: the current face becomes the query, even a neutral one.
    func snap() {
        guard mode == .live, !showSetupCard, tracker.snap() else { return }
        if holdProgress != 0 { holdProgress = 0 }
        runExpressionSearch(animate: true)
        refreshHint()
    }

    func moreLikeFocused() {
        guard focusedIndex >= 0, focusedIndex < results.count else { return }
        let item = results[focusedIndex].item
        clearTextState()
        resetQueryImage()
        moreLikeItem = item
        queryImageURL = item.fileURL
        mode = .moreLike
        runMoreLikeSearch()
        refreshHint()
    }

    func backToFace() {
        guard mode == .moreLike || mode == .image || mode == .text else { return }
        clearTextState()
        returnToFace()
    }

    /// Searches with a dropped or pasted image. The image is never saved unless the user keeps it.
    func search(withImageAt url: URL) {
        clearTextState()
        resetQueryImage()
        queryImageURL = url
        mode = .image
        resultSource = .image
        searchGeneration += 1
        webTask?.cancel()
        let generation = imageGeneration
        refreshHint()

        imageTask = Task { [weak self] in
            let values = await Task.detached(priority: .userInitiated) {
                analyzeQueryImage(at: url)
            }.value
            guard let self, !Task.isCancelled, generation == self.imageGeneration, self.mode == .image else { return }
            guard let values else {
                HUDController.shared.show("Couldn’t read that image")
                self.returnToFace()
                return
            }
            self.imageQuery = values
            self.runImageSearch()
        }
    }

    /// ⌘V: true when the pasteboard held an image MemeMe didn't put there (it becomes the query).
    func pasteFromClipboard() -> Bool {
        guard let url = Clipboard.imageOnPasteboard() else { return false }
        search(withImageAt: url)
        return true
    }

    func performHintAction() {
        guard let action = hint.action else { return }
        switch action {
        case .clearPins:
            pins = []
            if mode == .live, tracker.query != nil {
                runExpressionSearch(animate: false)
            }
            refreshHint()
        case .backToFace:
            backToFace()
        case .keepImage:
            toggleKeepImage()
        case .turnOnCamera:
            turnOnCamera()
        case .useCamera:
            useCameraDespiteOtherApp = true
            enterCameraMode()
            if mode == .prompt {
                scheduleCameraAccessRequest(after: 0)
            }
            refreshHint()
        }
    }

    func removeFaceToken() {
        guard showsFaceToken else { return }
        showsFaceToken = false
        faceTokenSample = nil
        if mode == .text {
            camera.stop()
            runTextSearch()
        }
        refreshHint()
    }

    func dragItemProvider(index: Int) -> NSItemProvider? {
        guard index >= 0, index < results.count else { return nil }
        let item = results[index].item
        if item.kind == .web {
            return webDragProvider(for: item)
        }
        return Clipboard.dragItemProvider(for: item, fileURL: item.fileURL)
    }

    /// "Is one of these Sam?" → names the picked face.
    func nameUnknownFace(personID: UUID) {
        guard let prompt = naming else { return }
        friends.name(personID: personID, as: prompt.name)
        naming = nil
        if mode == .text {
            runTextSearch()
        }
    }

    // MARK: - Library

    func findMyMemes() {
        var settings = store.settings
        settings.libraryOfferAccepted = true
        store.settings = settings
        indexer.addWatchedFolders(indexer.defaultFolders())
        refreshFooter()
        saveSoon()
    }

    func dismissLibraryOffer() {
        var settings = store.settings
        settings.libraryOfferDismissals += 1
        store.settings = settings
        libraryOfferHiddenThisSession = true
        refreshFooter()
        saveSoon()
    }

    func undoAddedBatch() {
        guard case .added(let batch) = footer else { return }
        indexer.undo(batch)
        if indexer.pendingSummary?.id == batch.id {
            indexer.clearPendingSummary()
        }
        shownSummaryID = nil
        refreshFooter()
    }

    func toggleOpenAtLogin() {
        let wanted = !store.settings.openAtLogin
        let actual = LoginItem.setEnabled(wanted)
        var settings = store.settings
        settings.openAtLogin = actual
        store.settings = settings
        saveSoon()
    }

    func dismissSetupCard() {
        guard showSetupCard else { return }
        showSetupCard = false
        if isPanelVisible, mode == .live || mode == .warming {
            enterCameraMode()
        }
        refreshFooter()
        refreshHint()
    }

    // MARK: - Updates

    /// Footer "Update" and the menu item: closes the panel (updates.willInstall), then downloads, verifies and installs.
    func installUpdate() {
        updates.installAvailableUpdate()
    }

    /// Footer "Not now": hides the line for this build only; the menu-bar dot and menu item stay.
    func dismissUpdateOffer() {
        guard let manifest = updates.available else { return }
        var settings = store.settings
        settings.skippedUpdateBuild = manifest.build
        store.settings = settings
        refreshFooter()
        saveSoon()
    }

    // MARK: - Menu-bar drops

    /// Photos of people become friend stickers (per the sticker policy); everything else is kept as a meme.
    func handleMenuBarDrop(urls: [URL]) async -> DropOutcome {
        var unique: [URL] = []
        for url in urls where !unique.contains(url) {
            unique.append(url)
        }
        guard !unique.isEmpty else { return .nothing }

        // "Photos with People ▸ Ask Each Time": one question per drop, before any face is cut or embedded.
        var makeStickers = store.settings.stickerPolicy != .never
        if makeStickers && store.settings.stickerPolicy == .ask {
            let photos = await photosOfPeople(in: unique)
            makeStickers = !photos.isEmpty && askToMakeStickers(from: photos)
        }

        var stickerBatches: [StickerBatch] = []
        var keepURLs: [URL] = []
        for url in unique {
            if url.isFileURL, makeStickers {
                do {
                    if let batch = try await friends.process(photo: url) {
                        stickerBatches.append(batch)
                        continue
                    }
                } catch {
                    modelLog.error("Making stickers failed; keeping the file as a meme")
                }
            }
            keepURLs.append(url)
        }

        var keptBatch: IndexBatch?
        if !keepURLs.isEmpty {
            keptBatch = await indexer.keep(urls: keepURLs, source: AppModel.keptSource)
        }
        // A mixed drop reports its stickers; the other files are kept (and searchable) all the same.
        if let stickers = combinedStickerBatch(stickerBatches) {
            return .stickers(stickers)
        }
        if let keptBatch {
            return .kept(keptBatch)
        }
        return .nothing
    }

    /// File URLs among `urls` that are photos of people (StickerEligibility); detection runs off the main actor.
    private func photosOfPeople(in urls: [URL]) async -> [URL] {
        let fileURLs = urls.filter { $0.isFileURL }
        guard !fileURLs.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [URL] in
            fileURLs.filter { url in
                guard let found = try? StickerMaker.eligibleFaces(in: url) else { return false }
                return !found.faces.isEmpty
            }
        }.value
    }

    private func askToMakeStickers(from photos: [URL]) -> Bool {
        let alert = NSAlert()
        if photos.count == 1, let photo = photos.first {
            alert.messageText = "Make stickers from “\(photo.lastPathComponent)”?"
        } else {
            alert.messageText = "Make stickers from \(photos.count) photos?"
        }
        alert.informativeText = "MemeMe cuts out each person. Everything stays on this Mac."
        alert.addButton(withTitle: "Make Stickers")
        alert.addButton(withTitle: photos.count == 1 ? "Keep as Photo" : "Keep as Photos")
        NSApplication.shared.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - App-shell helpers (used by the status item and the app delegate)

    /// Persists the store about 2 s after the last change.
    func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: AppModel.saveDelayNanoseconds)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Persists the resting face and the store right away (quit).
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        persistBaseline()
        guard store.isDirty else { return }
        do {
            try store.save()
        } catch {
            modelLog.error("Saving the library failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Menu: "Forget My Resting Face". The baseline is relearned silently from calm frames.
    func forgetRestingFace() {
        tracker.baseline = RestingBaseline()
        var settings = store.settings
        settings.baseline = RestingBaseline()
        store.settings = settings
        saveSoon()
    }

    // MARK: - Camera

    private func handleSample(_ sample: ExpressionSample) {
        guard isPanelVisible, !showSetupCard else { return }
        if mode == .warming {
            mode = .live
            liveSince = sample.timestamp
            faceMissing = false
        }
        // In text, image and more-like modes the camera only feeds the (dimmed) mirror.
        guard mode == .live else {
            earlyMood.reset()
            return
        }

        let queryChanged = tracker.ingest(sample)
        // Search the web for the expression being held, so its results are in by the time the hold completes.
        let candidateMood = tracker.candidate.map { MoodClassifier.mood(for: $0.face, pose: $0.pose, baseline: tracker.baseline) }
        if let mood = earlyMood.observe(candidateMood, at: sample.timestamp) {
            web.warm(mood)
        }
        let progress = queryChanged ? 0 : tracker.holdProgress
        if holdProgress != progress { holdProgress = progress }

        let lastSeen = max(tracker.lastFaceTimestamp ?? 0, liveSince ?? sample.timestamp)
        let missing = sample.face == nil && sample.timestamp - lastSeen >= AppModel.faceMissingDelay
        if missing != faceMissing { faceMissing = missing }

        if queryChanged {
            runExpressionSearch(animate: true)
        }
        refreshHint()
    }

    /// Picks the camera-driven mode (in use elsewhere → busy, undecided → prompt, denied → off, else warming)
    /// and starts the camera when it may run.
    private func enterCameraMode() {
        camera.refreshAuthorization()
        if camera.authorization == .authorized && camera.isRunning {
            setLive()
            return
        }
        if !useCameraDespiteOtherApp && camera.isInUseByAnotherApplication {
            mode = .cameraBusy
            return
        }
        switch camera.authorization {
        case .authorized:
            if camera.hasUsableCamera {
                camera.start()
                mode = .warming
            } else {
                mode = .cameraOff   // "No camera · Drop, paste or type instead."
            }
        case .notDetermined:
            mode = .prompt
        case .denied, .restricted:
            mode = .cameraOff
        @unknown default:
            mode = .cameraOff
        }
    }

    private func setLive() {
        guard mode != .live else { return }
        mode = .live
        liveSince = CACurrentMediaTime()
        faceMissing = false
    }

    /// Asks for camera access (the app is activated just for the system alert), then switches to the camera.
    private func scheduleCameraAccessRequest(after delay: TimeInterval) {
        cameraAccessTask?.cancel()
        let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
        cameraAccessTask = Task { [weak self] in
            if nanoseconds > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            guard let self, !Task.isCancelled, self.isPanelVisible else { return }
            self.camera.refreshAuthorization()
            if self.camera.authorization == .notDetermined {
                NSApplication.shared.activate()
                _ = await self.camera.requestAccess()
            }
            guard self.isPanelVisible else { return }
            if self.mode == .prompt || self.mode == .cameraOff {
                self.enterCameraMode()
            }
            self.refreshHint()
        }
    }

    private func turnOnCamera() {
        camera.refreshAuthorization()
        if camera.authorization == .notDetermined {
            scheduleCameraAccessRequest(after: 0)
            return
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        // Close first: closing reactivates the chat app, and System Settings should end up in front.
        if isPanelVisible {
            onRequestClose?()
        }
        _ = NSWorkspace.shared.open(url)
    }

    // MARK: - Searches

    /// Recent in this app; else the newest own memes; else GIPHY "reaction" results so the grid is never empty.
    /// Library changes refresh it with `animateNew` (amber ring on arrivals) and without moving the focus.
    private func showRecentResults(animateNew: Bool = false, resetFocus: Bool = true) {
        resultSource = .recent
        searchGeneration += 1
        webTask?.cancel()
        let ranker = Ranker(baseline: tracker.baseline)
        let recentIDs = store.recents.recent(appBundleID: previousBundleID)
        var ranked = ranker.rank(
            searchPool(),
            query: .recent(appBundleID: previousBundleID),
            people: store.people,
            recents: recentIDs,
            limit: limit
        )
        if ranked.isEmpty {
            ranked = reactionResults(web.cachedItems(for: .reaction))
        }
        setResults(ranked, animateNew: animateNew, resetFocus: resetFocus)
        if ranked.isEmpty {
            fetchReactionResults()
        }
    }

    private func reactionResults(_ items: [LibraryItem]) -> [RankedResult] {
        items.prefix(limit).map { RankedResult(item: $0, score: 1) }
    }

    /// Nothing local yet (first run): GIPHY "reaction" results fill the grid as they arrive.
    private func fetchReactionResults() {
        let generation = searchGeneration
        let stream = web.results(for: .reaction)
        let started = CACurrentMediaTime()
        webTask = Task { [weak self] in
            for await snapshot in stream {
                guard let self, !Task.isCancelled, generation == self.searchGeneration, self.resultSource == .recent else { return }
                guard CACurrentMediaTime() - started < AppModel.webFetchTimeout else { break }
                if !snapshot.isEmpty {
                    await self.warmThumbnails(of: snapshot)
                    guard !Task.isCancelled, generation == self.searchGeneration, self.resultSource == .recent else { return }
                    let tiles = self.reactionResults(snapshot)
                    if self.results.isEmpty {
                        self.setResults(tiles, animateNew: false, resetFocus: true)
                    } else {
                        // These don't match a face, so the grid keeps still: tiles already shown stay, new ones fill the gaps.
                        self.applyLateResults(tiles, lockedCount: self.results.count)
                    }
                }
                try? await Task.sleep(nanoseconds: AppModel.webBatchNanoseconds)
            }
            guard let self, !Task.isCancelled, generation == self.searchGeneration else { return }
            self.prefetchTopWebItems()
        }
    }

    /// Face query: mood → weights → local rank (with cached web items for the mood) now, fresh web results merged later.
    private func runExpressionSearch(animate: Bool) {
        guard let sample = tracker.query else {
            showRecentResults()
            return
        }
        resultSource = .expression
        let mood = MoodClassifier.mood(for: sample.face, pose: sample.pose, baseline: tracker.baseline)
        let deviation = sample.face.map { tracker.baseline.deviation(of: $0) } ?? [:]
        let weights = FeatureWeights.automatic(deviation: deviation, poseActivity: sample.pose?.activity ?? 0).pinning(pins)
        currentWeights = weights
        searchGeneration += 1
        let generation = searchGeneration
        webTask?.cancel()

        let ranker = Ranker(baseline: tracker.baseline)
        let cached = web.cachedItems(for: mood)
        // A search that is still running (often started while the face was being held) already has some results.
        let webItems = cached.isEmpty ? web.partialItems(for: mood) : cached
        let ranked = ranker.rank(libraryPool(adding: webItems), query: .expression(sample, weights: weights), people: store.people, limit: limit)
        // Nothing local or cached matches this face yet: keep the recent / "reaction" tiles rather than blank the grid.
        if !ranked.isEmpty || results.isEmpty {
            setResults(ranked, animateNew: animate, resetFocus: true)
        }

        guard cached.isEmpty else { return }
        // Web results stream in as GIPHY's stills are analyzed and fill in behind what the user may be about to click.
        let stream = web.results(for: mood)
        let showsNoMatch = ranked.isEmpty
        let started = CACurrentMediaTime()
        webTask = Task { [weak self] in
            // Only the first batch may replace tiles that don't match this face.
            var replacingPlaceholders = showsNoMatch
            for await snapshot in stream {
                guard let self, !Task.isCancelled, generation == self.searchGeneration else { return }
                // Later results stay out of this grid; the search still caches them for next time.
                guard CACurrentMediaTime() - started < AppModel.webFetchTimeout else { break }
                if !snapshot.isEmpty {
                    await self.warmThumbnails(of: snapshot)
                    guard !Task.isCancelled, generation == self.searchGeneration else { return }
                    self.mergeWebResults(snapshot, ranker: ranker, sample: sample, weights: weights, replacingPlaceholders: replacingPlaceholders)
                    replacingPlaceholders = false
                }
                // The stream keeps only its newest batch while this waits.
                try? await Task.sleep(nanoseconds: AppModel.webBatchNanoseconds)
            }
            guard let self, !Task.isCancelled, generation == self.searchGeneration else { return }
            self.prefetchTopWebItems()
        }
    }

    /// Late web results fill in behind: the user's strong own matches and the focused tile never move.
    /// `replacingPlaceholders`: the grid still shows recent / "reaction" tiles that don't match this face, so only
    /// a tile the user pointed at stays put. `ranker` is the search's own, so batches score alike.
    private func mergeWebResults(_ webItems: [LibraryItem], ranker: Ranker, sample: ExpressionSample, weights: FeatureWeights, replacingPlaceholders: Bool) {
        guard isPanelVisible, resultSource == .expression else { return }
        let incoming = ranker.rank(libraryPool(adding: webItems), query: .expression(sample, weights: weights), people: store.people, limit: limit)
        // The focused tile is what ↵ copies (and what the focus line names) even before the user moved the
        // focus, so everything up to and including it stays put.
        let lockedCount = replacingPlaceholders
            ? (userInteracted ? focusedIndex + 1 : 0)
            : max(ResultMerger.strongOwnPrefix(results), focusedIndex + 1)
        applyLateResults(incoming, lockedCount: lockedCount)
    }

    /// Merges late results behind the first `lockedCount` tiles. A number key skips a slot for a moment after it changes.
    private func applyLateResults(_ incoming: [RankedResult], lockedCount: Int) {
        let merged = ResultMerger.merge(current: results, incoming: incoming, lockedCount: lockedCount, limit: limit)
        let changed = ResultMerger.changedSlots(from: results, to: merged)
        let now = CACurrentMediaTime()
        for slot in changed {
            slotChangedAt[slot] = now
        }
        setResults(merged, animateNew: true, resetFocus: false, prefetchingWeb: false)
        // The full GIFs ↵ and the top tiles copy start downloading as soon as those tiles change, not once per batch.
        if changed.contains(focusedIndex) || changed.contains(where: { $0 < 3 }) {
            prefetchTopWebItems()
        }
    }

    /// Decodes the grid thumbnails of web results before they are shown, so new tiles don't flash empty.
    private func warmThumbnails(of items: [LibraryItem]) async {
        let pending = items.filter { ThumbnailCache.shared.cached($0.fileURL) == nil }.map(\.fileURL)
        guard !pending.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for url in pending {
                group.addTask { @MainActor in
                    _ = await ThumbnailCache.shared.thumbnail(for: url, maxPixel: 256)   // the size ResultTile asks for
                }
            }
        }
    }

    private func runTextSearch() {
        let raw = queryText
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        resultSource = .text
        searchGeneration += 1
        webTask?.cancel()
        let ranker = Ranker(baseline: tracker.baseline)
        let face = showsFaceToken ? faceTokenSample : nil
        let weights = showsFaceToken ? faceTokenWeights : FeatureWeights.uniform
        let ranked = ranker.rank(searchPool(), query: .text(raw, face: face, weights: weights), people: store.people, limit: limit)
        setResults(ranked, animateNew: false, resetFocus: true)
        updateNamingPrompt(raw: raw, hasResults: !ranked.isEmpty)
    }

    private func runImageSearch() {
        guard let query = imageQuery else { return }
        resultSource = .image
        searchGeneration += 1
        webTask?.cancel()
        // The query image itself (once kept) is not a result.
        let excludedIDs = Set(keptImageBatch?.addedIDs ?? [])
        let queryURL = queryImageURL?.standardizedFileURL
        let pool = searchPool().filter { item in
            !excludedIDs.contains(item.id) && item.fileURL.standardizedFileURL != queryURL
        }
        let ranker = Ranker(baseline: tracker.baseline)
        let ranked = ranker.rank(
            pool,
            query: .image(featurePrint: query.featurePrint, face: query.face, intensity: query.intensity),
            people: store.people,
            limit: limit
        )
        setResults(ranked, animateNew: false, resetFocus: true)
    }

    private func runMoreLikeSearch() {
        guard let item = moreLikeItem else { return }
        resultSource = .moreLike
        searchGeneration += 1
        webTask?.cancel()
        let ranker = Ranker(baseline: tracker.baseline)
        let ranked = ranker.rank(searchPool(), query: .moreLike(item), people: store.people, limit: limit)
        setResults(ranked, animateNew: false, resetFocus: true)
    }

    private func refreshCurrentResults() {
        switch resultSource {
        case .recent:
            showRecentResults()
        case .expression:
            runExpressionSearch(animate: false)
        case .text:
            runTextSearch()
        case .image:
            runImageSearch()
        case .moreLike:
            runMoreLikeSearch()
        }
    }

    /// Library items plus every cached web item (so recently sent GIPHY picks and typed matches can show).
    private func searchPool() -> [LibraryItem] {
        var pool = store.items
        var seen = Set(pool.map { $0.id })
        for mood in Mood.allCases {
            for item in web.cachedItems(for: mood) where !seen.contains(item.id) {
                seen.insert(item.id)
                pool.append(item)
            }
        }
        return pool
    }

    /// Library items plus the web items the library doesn't already hold (sent GIPHY picks are kept in it).
    private func libraryPool(adding webItems: [LibraryItem]) -> [LibraryItem] {
        let known = Set(store.items.map { $0.id })
        return store.items + webItems.filter { !known.contains($0.id) }
    }

    /// `prefetchingWeb`: start downloading the full GIFs of the top web tiles (off while results are still streaming in).
    private func setResults(_ newResults: [RankedResult], animateNew: Bool, resetFocus: Bool, prefetchingWeb: Bool = true) {
        let limited = Array(newResults.prefix(limit))
        if animateNew && !results.isEmpty {
            let previous = Set(results.map { $0.id })
            let arrived = Set(limited.map { $0.id }).subtracting(previous)
            if !arrived.isEmpty {
                markArrived(arrived)
            }
        }
        if results != limited {
            results = limited
        }
        let visible = Set(limited.map { $0.id })
        if !newResultIDs.isSubset(of: visible) {
            newResultIDs = newResultIDs.intersection(visible)
        }
        if resetFocus {
            userInteracted = false
            slotChangedAt.removeAll()
            if focusedIndex != 0 { focusedIndex = 0 }
        } else if focusedIndex >= limited.count {
            focusedIndex = max(0, limited.count - 1)
        }
        if prefetchingWeb {
            prefetchTopWebItems()
        }
    }

    /// Amber ring on tiles that just arrived, for 600 ms.
    private func markArrived(_ ids: Set<UUID>) {
        newResultIDs.formUnion(ids)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: AppModel.newRingNanoseconds)
            guard let self else { return }
            let remaining = self.newResultIDs.subtracting(ids)
            if remaining != self.newResultIDs {
                self.newResultIDs = remaining
            }
        }
    }

    /// Full GIFs for the focused web result and the top ones, so copying is instant.
    /// `prefetchForCopy` takes the first three it is given, so the focused tile goes first.
    private func prefetchTopWebItems() {
        var items: [LibraryItem] = []
        if focusedIndex >= 0, focusedIndex < results.count, results[focusedIndex].item.kind == .web {
            items.append(results[focusedIndex].item)
        }
        for (index, result) in results.enumerated() where index < 3 && index != focusedIndex && result.item.kind == .web {
            items.append(result.item)
        }
        if !items.isEmpty {
            web.prefetchForCopy(items)
        }
    }

    private func prefetchFocused() {
        guard focusedIndex >= 0, focusedIndex < results.count else { return }
        let item = results[focusedIndex].item
        if item.kind == .web {
            web.prefetchForCopy([item])
        }
    }

    // MARK: - Text

    private func queryTextWasEdited(previous: String) {
        let now = CACurrentMediaTime()
        lastTextEditAt = now
        if previous.isEmpty && !queryText.isEmpty {
            textBeganAt = now
        }
        textDebounceTask?.cancel()
        textDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: AppModel.textDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.applyQueryText()
        }
    }

    private func applyQueryText() {
        guard isPanelVisible else { return }
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            textBeganAt = nil
            if mode == .text {
                clearTextState()
                returnToFace()
            }
            return
        }
        if mode != .text {
            enterTextMode()
        }
        runTextSearch()
        refreshHint()
    }

    /// Typing right after opening stops the camera; later, a held face stays as a removable token.
    private func enterTextMode() {
        let began = textBeganAt ?? CACurrentMediaTime()
        let typedRightAfterOpening = began - shownAt < AppModel.typingStopsCameraWindow
        resetQueryImage()
        if holdProgress != 0 { holdProgress = 0 }
        if !typedRightAfterOpening, let held = tracker.query, held.face != nil, camera.isRunning {
            faceTokenSample = held
            faceTokenWeights = currentWeights
            showsFaceToken = true
        } else {
            faceTokenSample = nil
            showsFaceToken = false
            camera.stop()
        }
        mode = .text
    }

    private func clearTextState() {
        textDebounceTask?.cancel()
        textDebounceTask = nil
        setQueryTextSilently("")
        textBeganAt = nil
        if naming != nil { naming = nil }
        if showsFaceToken { showsFaceToken = false }
        faceTokenSample = nil
    }

    private func setQueryTextSilently(_ text: String) {
        guard queryText != text else { return }
        isSettingQueryTextInternally = true
        queryText = text
        isSettingQueryTextInternally = false
    }

    /// "Is one of these Sam?" when a typed name matches nothing and unnamed faces exist.
    private func updateNamingPrompt(raw: String, hasResults: Bool) {
        guard !hasResults, let name = TextQuery.parse(raw, people: store.people).possibleName else {
            if naming != nil { naming = nil }
            return
        }
        let unnamed = friends.unnamedPeople(limit: 3)
        guard !unnamed.isEmpty else {
            if naming != nil { naming = nil }
            return
        }
        let candidates = unnamed.map { entry in
            NamingCandidate(personID: entry.person.id, stickerCount: entry.stickerCount, sample: entry.sample)
        }
        let prompt = NamingPrompt(name: AppModel.displayName(forTypedName: name, in: raw), candidates: candidates)
        if naming != prompt {
            naming = prompt
        }
    }

    /// The typed word as the user wrote it, capitalized when they typed it all lowercase ("sam" → "Sam").
    private static func displayName(forTypedName name: String, in raw: String) -> String {
        var typed = name
        for word in raw.split(whereSeparator: { $0.isWhitespace }) {
            let candidate = String(word).trimmingCharacters(in: .punctuationCharacters)
            if candidate.lowercased() == name {
                typed = candidate
                break
            }
        }
        guard typed == typed.lowercased(), let first = typed.first else { return typed }
        return String(first).uppercased() + String(typed.dropFirst())
    }

    // MARK: - Image and more-like refinements

    private func resetQueryImage() {
        imageGeneration += 1
        imageTask?.cancel()
        imageTask = nil
        imageQuery = nil
        keptImageBatch = nil
        if imageKept { imageKept = false }
        if queryImageURL != nil { queryImageURL = nil }
        if moreLikeItem != nil { moreLikeItem = nil }
    }

    /// Leaves text / image / more-like for the face: restarts the camera if needed and shows face or recent results.
    private func returnToFace() {
        resetQueryImage()
        enterCameraMode()
        if mode == .live || mode == .warming, tracker.query != nil {
            runExpressionSearch(animate: false)
        } else {
            showRecentResults()
        }
        refreshHint()
    }

    /// "Keep it" saves the query image into the library; "Kept · Undo" removes it again.
    private func toggleKeepImage() {
        guard let url = queryImageURL, mode == .image else { return }
        if imageKept {
            if let batch = keptImageBatch {
                indexer.undo(batch)
            }
            keptImageBatch = nil
            imageKept = false
            refreshHint()
            return
        }
        guard !isKeepingImage else { return }
        isKeepingImage = true
        Task { [weak self] in
            guard let self else { return }
            let batch = await self.indexer.keep(urls: [url], source: AppModel.keptSource)
            self.isKeepingImage = false
            let isKept = !batch.addedIDs.isEmpty || batch.duplicates > 0
            guard self.mode == .image, self.queryImageURL == url else {
                return   // The user moved on; the image stays kept, as asked.
            }
            if isKept {
                self.keptImageBatch = batch
                self.imageKept = true
            } else {
                HUDController.shared.show("Couldn’t keep that image")
            }
            self.refreshHint()
        }
    }

    // MARK: - Commit

    private func performCommit(_ item: LibraryItem, token: Int, session: Int, appBundleID: String?) async {
        defer {
            if committingSession == session { committingSession = nil }
        }
        let resolved = await resolveFileForCopy(item)
        // A newer pick (made after reopening the panel) owns the clipboard.
        guard token == commitToken else { return }
        // The panel this pick came from may have closed (and another opened) while a web GIF downloaded.
        let isSameOpen = session == sessionID && isPanelVisible
        guard let fileURL = resolved else {
            HUDController.shared.show("Couldn’t copy that one. Try another.")
            return
        }
        do {
            try Clipboard.copy(fileURL: fileURL, item: item)
        } catch {
            modelLog.error("Copying to the pasteboard failed")
            HUDController.shared.show("Couldn’t copy that one. Try another.")
            return
        }
        recordSent(item, appBundleID: appBundleID)

        if !store.settings.hasCompletedFirstRun, isSameOpen {
            // First pick: the panel stays open with the You're-set card (the camera has nothing to show meanwhile).
            var settings = store.settings
            settings.hasCompletedFirstRun = true
            store.settings = settings
            showSetupCard = true
            setupCardShownThisSession = true
            camera.stop()
            if holdProgress != 0 { holdProgress = 0 }
            refreshFooter()
            saveSoon()
            return
        }
        saveSoon()
        if isSameOpen {
            onRequestClose?()
        }
        HUDController.shared.show("Copied “\(item.displayName)” · ⌘V — not sent", thumbnail: item.fileURL)
    }

    /// The local file to put on the pasteboard; web GIFs are downloaded first ("Copying…" if that is slow).
    private func resolveFileForCopy(_ item: LibraryItem) async -> URL? {
        guard item.kind == .web else {
            return FileManager.default.fileExists(atPath: item.fileURL.path) ? item.fileURL : nil
        }
        let slowNotice = Task { @MainActor in
            try? await Task.sleep(nanoseconds: AppModel.slowCopyNanoseconds)
            guard !Task.isCancelled else { return }
            HUDController.shared.show("Copying…")
        }
        let url = await web.prepareForCopy(item)
        slowNotice.cancel()
        return url
    }

    private func recordSent(_ item: LibraryItem, appBundleID: String?) {
        if var stored = store.item(id: item.id) {
            stored.timesSent += 1
            stored.lastSentAt = Date()
            store.update(stored)
        } else if item.kind == .web {
            // A sent GIPHY pick outlives the 24 h web cache, so "⌃⌘M then ↵" can repeat it. Its still is
            // copied out of the cache; the full GIF is downloaded again from remoteURL when it is copied.
            var sent = item
            sent.timesSent = 1
            sent.lastSentAt = Date()
            let fileManager = FileManager.default
            let directory = store.rootURL.appendingPathComponent("Sent", isDirectory: true)
            let copy = directory.appendingPathComponent(item.fileURL.lastPathComponent, isDirectory: false)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            if fileManager.fileExists(atPath: copy.path) || (try? fileManager.copyItem(at: item.fileURL, to: copy)) != nil {
                sent.fileURL = copy
            }
            store.add(sent)   // keeps the stable id and contentHash "giphy:<id>"
        }
        var recents = store.recents
        recents.record(item.id, appBundleID: appBundleID)
        store.recents = recents
    }

    /// Web tiles drag the full GIF, fetched when the receiving app asks for it, under a neutral name.
    private func webDragProvider(for item: LibraryItem) -> NSItemProvider {
        let provider = NSItemProvider()
        let web = self.web
        let fileName = Clipboard.neutralFileName(for: item)
        provider.suggestedName = (fileName as NSString).deletingPathExtension
        // The load handler runs on a background queue when the receiving app asks for the file, so it is
        // explicitly @Sendable (not main-actor isolated) and hops to the main actor for the download.
        provider.registerFileRepresentation(forTypeIdentifier: UTType.gif.identifier, fileOptions: [], visibility: .all) { @Sendable completion in
            Task { @MainActor in
                let prepared = await web.prepareForCopy(item)
                let shared = prepared.flatMap { makeDragCopy(of: $0, named: fileName) }
                completion(shared, false, nil)
            }
            return nil
        }
        return provider
    }

    // MARK: - Library state

    private func libraryDidChange() {
        refreshFooter()
        guard isPanelVisible else { return }
        let showsRemovedItem = results.contains { $0.item.kind != .web && store.item(id: $0.item.id) == nil }
        if resultSource == .recent {
            // Fill the recent grid as memes arrive (amber ring, focus kept), but never reshuffle tiles
            // the user is pointing at.
            if showsRemovedItem || !userInteracted {
                showRecentResults(animateNew: true, resetFocus: false)
            }
        } else if showsRemovedItem {
            refreshCurrentResults()
        }
    }

    private func refreshFooter() {
        let state: FooterState
        if indexer.isIndexing {
            state = .indexing(count: indexer.progressCount)
        } else if isPanelVisible, let summary = indexer.pendingSummary {
            shownSummaryID = summary.id
            state = .added(summary)
        } else if let manifest = offeredUpdate {
            state = .update(manifest)
        } else if shouldOfferLibrary {
            state = .libraryOffer
        } else {
            state = .legend
        }
        if footer != state {
            footer = state
        }
    }

    /// The update the footer offers: one is available, no install is running and its build wasn't dismissed.
    /// A background check (`.checking`) keeps the line, so it doesn't blink while the panel is open.
    private var offeredUpdate: UpdateManifest? {
        guard let manifest = updates.available,
              updates.phase == .idle || updates.phase == .checking,
              UpdatePolicy.shouldOfferInPanel(manifest, skippedBuild: store.settings.skippedUpdateBuild) else {
            return nil
        }
        return manifest
    }

    /// "Search memes you already saved?" on later opens when the card was skipped, until two "Not now"s.
    private var shouldOfferLibrary: Bool {
        let settings = store.settings
        return settings.hasCompletedFirstRun
            && !setupCardShownThisSession
            && !libraryOfferHiddenThisSession
            && !settings.libraryOfferAccepted
            && settings.libraryOfferDismissals < 2
            && settings.watchedFolders.isEmpty
    }

    // MARK: - Hint

    private func refreshHint() {
        let newHint = computeHint()
        if hint != newHint {
            hint = newHint
        }
    }

    private func computeHint() -> PanelHint {
        switch mode {
        case .prompt:
            return PanelHint(title: HintCopy.promptTitle, subtitle: HintCopy.promptSubtitle, actionTitle: nil, action: nil)
        case .warming:
            return PanelHint(title: HintCopy.warmingTitle, subtitle: HintCopy.warmingSubtitle, actionTitle: nil, action: nil)
        case .live:
            if faceMissing {
                return PanelHint(title: HintCopy.noFaceTitle, subtitle: HintCopy.noFaceSubtitle, actionTitle: nil, action: nil)
            }
            if !pins.isEmpty {
                return PanelHint(title: "Focusing on " + pinDescription, subtitle: nil, actionTitle: HintCopy.clearAction, action: .clearPins)
            }
            let poseActive = (tracker.query?.pose?.activity ?? 0) >= AppModel.poseActiveThreshold
            let title = poseActive ? HintCopy.livePoseTitle : HintCopy.liveTitle
            if holdProgress > 0 && tracker.candidateIsNewExpression {
                return PanelHint(title: title, subtitle: HintCopy.holdingSubtitle, actionTitle: nil, action: nil)
            }
            return PanelHint(title: title, subtitle: HintCopy.liveSubtitle, actionTitle: nil, action: nil)
        case .text:
            return PanelHint(title: HintCopy.textTitle, subtitle: HintCopy.textSubtitle, actionTitle: nil, action: nil)
        case .image:
            let actionTitle = imageKept ? HintCopy.keptAction : HintCopy.keepAction
            return PanelHint(title: HintCopy.imageTitle, subtitle: HintCopy.imageSubtitle, actionTitle: actionTitle, action: .keepImage)
        case .moreLike:
            let name = moreLikeItem?.displayName ?? "this"
            return PanelHint(title: "More like “\(name)”", subtitle: nil, actionTitle: HintCopy.backToFaceAction, action: .backToFace)
        case .cameraOff:
            // Authorized but no usable camera: there is nothing to turn on in System Settings.
            let canTurnOn = camera.authorization != .authorized
            return PanelHint(title: HintCopy.cameraOffTitle, subtitle: HintCopy.cameraOffSubtitle,
                             actionTitle: canTurnOn ? HintCopy.cameraOffAction : nil,
                             action: canTurnOn ? .turnOnCamera : nil)
        case .cameraBusy:
            return PanelHint(title: HintCopy.cameraBusyTitle, subtitle: HintCopy.cameraBusySubtitle, actionTitle: HintCopy.cameraBusyAction, action: .useCamera)
        }
    }

    /// "your mouth", "your eyes", "your eyes and mouth"
    private var pinDescription: String {
        var parts: [String] = []
        if pins.contains(.brows) { parts.append("brows") }
        if pins.contains(.eyes) { parts.append("eyes") }
        if pins.contains(.mouth) { parts.append("mouth") }
        guard let last = parts.last else { return "your face" }
        if parts.count == 1 {
            return "your " + last
        }
        return "your " + parts.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: - Session and persistence

    private func resetForNewSession() {
        cancelSessionTasks()
        clearTextState()
        resetQueryImage()
        tracker = PeakHoldTracker(baseline: tracker.baseline)
        earlyMood.reset()
        if !pins.isEmpty { pins = [] }
        if holdProgress != 0 { holdProgress = 0 }
        if !newResultIDs.isEmpty { newResultIDs = [] }
        if showSetupCard { showSetupCard = false }
        lastTextEditAt = 0
        liveSince = nil
        faceMissing = false
        userInteracted = false
        useCameraDespiteOtherApp = false
        isKeepingImage = false
        currentWeights = .uniform
        setupCardShownThisSession = false
        libraryOfferHiddenThisSession = false
        shownSummaryID = nil
    }

    private func cancelSessionTasks() {
        textDebounceTask?.cancel()
        textDebounceTask = nil
        webTask?.cancel()
        webTask = nil
        imageTask?.cancel()
        imageTask = nil
        cameraAccessTask?.cancel()
        cameraAccessTask = nil
        searchGeneration += 1
        imageGeneration += 1
    }

    private func persistBaseline() {
        guard store.settings.baseline != tracker.baseline else { return }
        var settings = store.settings
        settings.baseline = tracker.baseline
        store.settings = settings
    }

    /// First run registers Open at Login (checked by default); later launches mirror the system's state.
    /// Only the launch that opens the first-run panel by itself counts as first run (AppDelegate sets the flag
    /// after this runs), so a login item the user removed in System Settings isn't registered again.
    private func syncLoginItem() {
        var settings = store.settings
        let firstRunPanelShown = UserDefaults.standard.bool(forKey: AppDelegate.firstRunPanelShownKey)
        if !settings.hasCompletedFirstRun && !firstRunPanelShown {
            if settings.openAtLogin && !LoginItem.isEnabled {
                settings.openAtLogin = LoginItem.setEnabled(true)
            }
        } else if LoginItem.isAvailable {
            settings.openAtLogin = LoginItem.isEnabled
        }
        if settings != store.settings {
            store.settings = settings
            saveSoon()
        }
    }

    /// One batch per drop: several photos' stickers are shown (and undone) together.
    private func combinedStickerBatch(_ batches: [StickerBatch]) -> StickerBatch? {
        guard let first = batches.first else { return nil }
        guard batches.count > 1 else { return first }
        var combined = StickerBatch(id: UUID(), sourceURL: first.sourceURL, stickers: [], skippedFaces: 0, undone: false)
        var seen = Set<UUID>()
        for batch in batches {
            for sticker in batch.stickers where !seen.contains(sticker.id) {
                seen.insert(sticker.id)
                combined.stickers.append(sticker)
            }
            combined.skippedFaces += batch.skippedFaces
        }
        StickerBatchSources.register(batches.map { $0.sourceURL }, for: combined.id)
        return combined
    }
}
