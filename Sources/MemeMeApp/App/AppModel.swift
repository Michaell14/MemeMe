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

/// The footer only appears for something to act on: collecting memes, what was just added, an update.
enum FooterState: Equatable { case hidden, indexing(count: Int), added(IndexBatch), update(UpdateManifest) }

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
    static let liveTitle = "Make a face or a pose. Results follow it."
    static let standingBackTitle = "Reading your pose"
    static let standingBackSubtitle = "Hold each pose for a second. Come closer for faces."
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

/// Copies a file into a fresh temporary folder under a neutral name, for dragging into other apps. It sits with
/// the clipboard's copies, so it is deleted within the hour like them.
private func makeDragCopy(of url: URL, named fileName: String) -> URL? {
    let fileManager = FileManager.default
    let directory = Clipboard.clipboardDirectory()
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

/// What a tile holds: one of your memes, a GIF in the GIPHY row, or a classic meme template.
enum Pick: Equatable {
    case meme(LibraryItem)
    case gif(WebGIF)
    case template(MemeTemplate)

    var title: String {
        switch self {
        case let .meme(item): return item.displayName
        case let .gif(gif): return gif.title
        case let .template(template): return template.name
        }
    }
}

/// The word under the mirror: what the camera read and searched for, and what it read it from.
struct MoodReadout: Equatable {
    enum Source: Equatable {
        case face, pose, faceAndPose
    }

    let word: String
    let source: Source
    /// The on-device model named the pose (`PoseNaming`); the mirror shows sparkles. False for a mood's word and for
    /// the rule's phrase for a pose (`PoseDescription.phrase`).
    var named: Bool = false
}

/// The words a pose with no word of its own was searched by, kept for the query they were found for so re-showing it
/// (pins, Esc, a library change, back from typing) searches the same words and never asks the model again.
private struct DescribedPhrase {
    /// The held query's `ExpressionSample.timestamp`.
    let timestamp: TimeInterval
    let phrase: String
    /// The on-device model named it; else it is the rule's phrase.
    let named: Bool
}

/// Orchestrates the panel: camera → peak-hold → mood → your memes ranked and the GIPHY row, typed and image queries,
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
    /// Rows of the grid of your memes: 1, or 0 (nothing drawn) when you have none.
    @Published private(set) var ownRows: Int = Theme.rows
    @Published private(set) var newResultIDs: Set<UUID> = []          // amber ring for 600 ms
    /// A slot of the tile grid (`TileGrid`): your memes (`ownRows` × 6), then the classic memes row, then the GIPHY
    /// row.
    @Published var focusedIndex: Int = 0
    /// The GIPHY row: GIPHY's results for `giphyQuery` (the face's mood, or typed words) in GIPHY's order, never
    /// ranked or mixed with your memes.
    @Published private(set) var giphyResults: [WebGIF] = []          // ≤ Theme.columns
    @Published private(set) var giphyQuery: WebQuery?
    @Published private(set) var isGiphyLoading: Bool = false
    /// The row's search failed or GIPHY refused it.
    @Published private(set) var giphyUnavailable: Bool = false
    /// Web Discover is on and has a key (checked each time the panel opens).
    @Published private(set) var showsGiphyRow: Bool = false
    /// The classic memes row: Imgflip templates picked on the Mac for `templateQuery` (popular ones before a face).
    @Published private(set) var templateResults: [MemeTemplate] = []  // ≤ Theme.columns
    @Published private(set) var templateQuery: WebQuery?
    @Published private(set) var isTemplatesLoading: Bool = false
    /// There is no list of templates: Imgflip didn't answer and none was kept.
    @Published private(set) var templatesUnavailable: Bool = false
    /// Web Discover is on (checked each time the panel opens); no key needed.
    @Published private(set) var showsTemplateRow: Bool = false
    /// The word the camera's search went by, under the mirror instead of the hint while live; nil when the hint
    /// should show (nothing read yet, pins set, or the face a word came from lost).
    @Published private(set) var readout: MoodReadout?
    @Published private(set) var pins: Set<FaceRegion> = []
    @Published private(set) var hint = PanelHint(title: HintCopy.promptTitle, subtitle: HintCopy.promptSubtitle, actionTitle: nil, action: nil)
    @Published private(set) var footer: FooterState = .hidden
    @Published private(set) var showSetupCard: Bool = false
    @Published private(set) var queryImageURL: URL?                   // image / moreLike mirror content
    @Published private(set) var moreLikeItem: LibraryItem?
    @Published private(set) var imageKept: Bool = false
    @Published private(set) var showsFaceToken: Bool = false
    @Published private(set) var naming: NamingPrompt?
    @Published private(set) var holdProgress: Double = 0
    /// The pose behind the face search: its word, or "your pose"; nil when the face alone made it. It picks the
    /// readout's source and sets off the mirror's green flash (`poseCatches`).
    @Published private(set) var heldPose: PoseBadge?
    /// Counts each pose caught (a new pose word, or a pose after the face alone, behind the search): the mirror
    /// flashes green when it changes.
    @Published private(set) var poseCatches = 0
    @Published private(set) var hotKeyAvailable: Bool = true
    @Published private(set) var isPanelVisible: Bool = false
    /// A tile of the panel is being dragged out: the panel takes no drop of its own tile (set and cleared by the
    /// panel controller, which watches the drag).
    @Published var isDraggingTile: Bool = false
    /// The capture view replaces the panel's contents: a big filtered mirror and a shutter.
    @Published private(set) var isCaptureOpen: Bool = false

    let store: LibraryStore
    let camera: CameraController
    let capture: CaptureModel
    let indexer: LibraryIndexer
    let web: WebDiscover
    let templates: MemeTemplates
    let friends: FriendService
    /// Update checks and the one-click install; disabled when the bundle has no feed URL (local builds, tests).
    let updates: UpdateChecker
    /// Names a clear gesture with no word of its own (`PoseDescription`) with the on-device model, where the Mac has
    /// one; the rule's phrase stands where it doesn't.
    private let poseNamer: any PoseNaming

    var onRequestClose: (() -> Void)?

    /// Opening the panel with camera access undecided asks for it 0.6 s later (first run).
    /// Tests turn this off so opening the panel never schedules the system prompt.
    var requestsCameraAccessOnShow = true

    // MARK: Timing (DESIGN.md)

    /// ↵ is ignored this soon after the last edit of the search field.
    private static let enterGuard: TimeInterval = 0.3
    private static let textDebounceNanoseconds: UInt64 = 80_000_000
    /// Typed words go to GIPHY once typing pauses this long (each search counts against GIPHY's hourly limit).
    private static let giphyTypingPauseNanoseconds: UInt64 = 600_000_000
    private static let newRingNanoseconds: UInt64 = 600_000_000
    private static let saveDelayNanoseconds: UInt64 = 2_000_000_000
    private static let cameraPromptDelay: TimeInterval = 0.6
    private static let faceMissingDelay: TimeInterval = 1.5
    /// "Can't see your face" stays until the face has been back this long, so a flickering detection can't flicker it.
    private static let faceBackDelay: TimeInterval = 1.0
    /// Shorter gaps in face detection are dropped frames, not the face leaving.
    private static let faceGap: TimeInterval = 0.3
    /// Typing that starts this soon after opening stops the camera instead of keeping the face token.
    private static let typingStopsCameraWindow: TimeInterval = 1.0
    /// A HUD says "Copying…" when fetching a web GIF takes longer than this.
    private static let slowCopyNanoseconds: UInt64 = 150_000_000
    private static let keptSource = "Kept"

    // MARK: Private state

    private var tracker: PeakHoldTracker
    private var previousBundleID: String?
    private var shownAt: TimeInterval = 0
    private var liveSince: TimeInterval?
    private var faceMissing = false
    /// When the face came back while "Can't see your face" shows.
    private var faceBackSince: TimeInterval?
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
    /// Starts an expression's web search while it is still being held.
    private var earlyMood = EarlyMoodTrigger()
    /// Standing back to show the whole body: the hint talks about poses.
    private var standingBack = StandingBackDetector()
    /// The readout for the face search on show; `readout` is it when the hint has nothing more pressing to say.
    private var searchReadout: MoodReadout?
    private var textBeganAt: TimeInterval?
    private var searchGeneration = 0
    private var imageGeneration = 0
    /// Bumped on every open, so a pick that finishes late never acts on a newer panel.
    private var sessionID = 0
    /// The newest pick; an older one that finishes later leaves the clipboard alone.
    private var commitToken = 0
    /// The open whose pick is still being copied (one pick at a time per open).
    private var committingSession: Int?
    private var shownSummaryID: UUID?

    private var textDebounceTask: Task<Void, Never>?
    private var giphyTask: Task<Void, Never>?
    private var giphyGeneration = 0
    private var giphyWordsTask: Task<Void, Never>?
    /// Every GIF GIPHY gave for `giphyQuery`, in its order; the row shows `giphyPage`'s `Theme.columns` of them.
    private var giphyFound: [WebGIF] = []
    /// Which of `giphyFound` the row shows (`WebDiscover.page`): a new face caught with the same mood turns to the
    /// next ones. 0 for each new query and each time the panel opens.
    private var giphyPage = 0
    /// The GIPHY row waits for the held pose's name (`awaitGiphyName`): it shows it is loading, and keeps what it found
    /// for `giphyQuery` so a name that comes out the same words turns their page.
    private var giphyAwaitsName = false
    private var templateTask: Task<Void, Never>?
    private var templateGeneration = 0
    /// Which of the mood's templates the classic memes row shows (`MemeTemplateCatalog.pick(for:from:limit:page:)`),
    /// turned like `giphyPage`.
    private var templatePage = 0
    /// The face's mood whose templates follow those a described pose's words name (`pickTemplates`).
    private var templateFallback: Mood = .reaction
    /// Asks the on-device model for the held pose's name (`PoseNaming.name`), then searches the web rows with it.
    private var describeTask: Task<Void, Never>?
    /// The held query (`ExpressionSample.timestamp`) `describeTask` asks about.
    private var describingTimestamp: TimeInterval?
    /// The words the held query's pose was searched by, once known.
    private var describedPhrase: DescribedPhrase?
    private var cleanupTask: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?
    private var cameraAccessTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var indexerObservation: AnyCancellable?
    private var updatesObservation: AnyCancellable?

    private var limit: Int { Theme.resultLimit }

    convenience init(store: LibraryStore) {
        self.init(store: store, webCacheRoot: nil)
    }

    /// `webCacheRoot`: where web discovery keeps its cache (nil = ~/Library/Caches/MemeMe/Web); tests pass a temp folder,
    /// and the classic memes keep theirs next to it ("Templates").
    /// `poseNamer`: names poses with no word of their own (nil = `PoseNamer`, the on-device model); tests pass a stand-in.
    init(store: LibraryStore, webCacheRoot: URL?, poseNamer: (any PoseNaming)? = nil) {
        self.store = store
        if let poseNamer {
            self.poseNamer = poseNamer
        } else {
            self.poseNamer = PoseNamer()
        }
        let camera = CameraController()
        self.camera = camera
        self.capture = CaptureModel(camera: camera)
        self.indexer = LibraryIndexer(store: store)
        self.web = WebDiscover(store: store, cacheRoot: webCacheRoot)
        self.templates = MemeTemplates(
            store: store,
            cacheRoot: webCacheRoot.map { $0.deletingLastPathComponent().appendingPathComponent("Templates", isDirectory: true) }
        )
        self.friends = FriendService(store: store)
        self.updates = UpdateChecker(bundle: .main)
        self.tracker = PeakHoldTracker(baseline: store.settings.baseline)
        // Earlier versions kept sent GIPHY picks in the library; GIPHY's media is no longer kept. A kept image or
        // sticker deleted in Finder is forgotten too.
        if store.removeSavedWebItems() + store.removeItemsWithMissingFiles() > 0 {
            do {
                try store.save()
            } catch {
                modelLog.error("Saving the library after removing saved GIPHY picks or missing files failed")
            }
        }

        camera.onSample = { [weak self] sample in
            self?.handleSample(sample)
        }
        capture.onCaptured = { [weak self] result in
            self?.deliverCapture(result)
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
        startCleanup()
        updates.start()
        refreshFooter()
    }

    /// Every 10 minutes while the app runs: GIPHY copies, drag copies and clipboard copies older than an hour go,
    /// except the copy still on the pasteboard.
    private func startCleanup() {
        guard cleanupTask == nil else { return }
        Task.detached(priority: .utility) {
            // Earlier versions put drag copies here and never deleted them.
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("MemeMeDrag", isDirectory: true))
        }
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.web.pruneCache()
                self.templates.pruneCache()
                let onPasteboard = Clipboard.directoryOnPasteboard
                Task.detached(priority: .utility) {
                    Clipboard.removeStaleCopies(keeping: onPasteboard)
                }
                try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
            }
        }
    }

    func setHotKeyAvailable(_ available: Bool) {
        if hotKeyAvailable != available {
            hotKeyAvailable = available
        }
    }

    // MARK: - Panel lifecycle

    func panelWillShow(previousApp: NSRunningApplication?) {
        // A notice still showing (e.g. "Save as sticker" from the last capture) sits where the panel opens.
        HUDController.shared.dismiss()
        // A kept image or sticker deleted in Finder while the panel was closed doesn't come back as a tile.
        indexer.removeItemsWithMissingFiles()
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
        closeCapture()
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

    /// What the focused tile holds; nil when it is empty.
    var focusedPick: Pick? {
        pick(atSlot: focusedIndex)
    }

    /// Tab and "More like this" look for memes like the focused one (not like a GIPHY GIF).
    var canMoreLikeFocused: Bool {
        if case .meme? = focusedPick { return true }
        return false
    }

    /// The slot of the GIPHY row's `offset`-th tile.
    func giphySlot(_ offset: Int) -> Int {
        tileGrid.giphyStart + offset
    }

    /// The slot of the classic memes row's `offset`-th tile.
    func templateSlot(_ offset: Int) -> Int {
        tileGrid.templateStart + offset
    }

    func commit(index: Int) {
        guard let pick = pick(atSlot: index), committingSession != sessionID else { return }
        commitToken += 1
        let token = commitToken
        let session = sessionID
        let appBundleID = previousBundleID
        committingSession = session
        Task { [weak self] in
            await self?.performCommit(pick, token: token, session: session, appBundleID: appBundleID)
        }
    }

    func commitFocused() {
        // ↵ pressed to "run the search" right after typing must not copy something.
        guard CACurrentMediaTime() - lastTextEditAt >= AppModel.enterGuard else { return }
        commit(index: focusedIndex)
    }

    /// Number keys pick your memes, 1–6.
    func commitNumbered(index: Int) {
        guard index < tileGrid.webStart else { return }
        commit(index: index)
    }

    func moveFocus(dx: Int, dy: Int) {
        userInteracted = true
        guard let target = tileGrid.move(from: focusedIndex, dx: dx, dy: dy) else { return }
        focusedIndex = target
        prefetchFocused()
    }

    func hover(index: Int) {
        guard tileGrid.isFilled(index) else { return }
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
    /// In the capture view it drops a capture in progress, else goes back to the memes.
    func handleEscape() -> Bool {
        if isCaptureOpen {
            if capture.isBusy {
                capture.cancel()
            } else {
                closeCapture()
            }
            return true
        }
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

    /// Space with an empty search field: the current face (or a gesture hiding it) becomes the query, even a neutral one.
    func snap() {
        guard mode == .live, !showSetupCard, tracker.snap() else { return }
        if holdProgress != 0 { holdProgress = 0 }
        let previousPose = heldPose
        runExpressionSearch(animate: true, newQuery: true)
        notePoseCaught(after: previousPose)
        refreshHint()
    }

    func moreLikeFocused() {
        guard case let .meme(item)? = focusedPick else { return }
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
        switch pick(atSlot: index) {
        case let .meme(item)?:
            return Clipboard.dragItemProvider(for: item, fileURL: item.fileURL)
        case let .gif(gif)?:
            return giphyDragProvider(for: gif)
        case let .template(template)?:
            return templateDragProvider(for: template)
        case nil:
            return nil
        }
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

    /// No folders collected yet: the empty grid offers "Find my memes".
    var offersFindMyMemes: Bool {
        store.settings.watchedFolders.isEmpty && !indexer.isIndexing
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

    // MARK: - Capture view

    /// The camera button and ⇧Space open the capture view while the camera reads you.
    var canOpenCapture: Bool {
        mode == .live && !showSetupCard && camera.isRunning
    }

    func openCapture() {
        guard canOpenCapture, !isCaptureOpen else { return }
        // A GIPHY pick still downloading must not copy, show the You're-set card or close the panel under the capture view;
        // it no longer holds the one-pick-at-a-time lock either.
        commitToken += 1
        committingSession = nil
        isCaptureOpen = true
        capture.activate()
        tracker.clearHold()
        if holdProgress != 0 { holdProgress = 0 }
        earlyMood.reset()
    }

    /// Back to the memes (Esc, or after a capture is copied); a capture in progress is dropped.
    func closeCapture() {
        guard isCaptureOpen else { return }
        capture.deactivate()
        isCaptureOpen = false
        // The strip got no frames while the view was open: start the face-missing clock again, so a first frame
        // without a face (looking down at Esc) isn't read as a long gap.
        if mode == .live {
            liveSince = CACurrentMediaTime()
            faceMissing = false
            faceBackSince = nil
        }
        refreshHint()
    }

    /// A finished capture: copy it as "reaction.gif" / "reaction.png", close the panel, and offer
    /// "Save as sticker" on the HUD. A capture is never kept unless saved as a sticker.
    private func deliverCapture(_ result: CaptureResult) {
        // A pick that was still downloading must not overwrite this on the pasteboard.
        commitToken += 1
        let fileURL: URL
        do {
            fileURL = try Clipboard.copy(data: result.data, fileName: result.isGIF ? "reaction.gif" : "reaction.png")
        } catch {
            modelLog.error("Copying a capture to the pasteboard failed")
            HUDController.shared.show("Couldn’t copy that one. Try again.")
            return
        }
        // A photo is cut from the file just copied; a GIF from its strongest frame.
        let stickerSource = result.isGIF ? result.stickerFrame.flatMap { AppModel.writeStickerSource($0) } : fileURL
        closeCapture()
        if isPanelVisible {
            onRequestClose?()
        }
        let action = stickerSource.map { url in
            HUDAction(title: "Save as sticker") { [weak self] in
                self?.saveCaptureAsSticker(from: url)
            }
        }
        HUDController.shared.show("Copied your \(result.isGIF ? "GIF" : "photo") · ⌘V — not sent", thumbnail: fileURL, action: action)
    }

    /// A PNG of `frame` next to the clipboard's copies (deleted within the hour like them).
    private static func writeStickerSource(_ frame: CGImage) -> URL? {
        guard let data = CaptureEncoder.png(frame) else { return nil }
        let directory = Clipboard.clipboardDirectory().appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            let url = directory.appendingPathComponent("capture.png", isDirectory: false)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func saveCaptureAsSticker(from url: URL) {
        HUDController.shared.show("Making your sticker…")
        Task { [weak self] in
            guard let self else { return }
            let made = try? await self.friends.makeOwnSticker(fromCapture: url)
            if let made {
                // Reopened meanwhile: the notice would cover the panel, and the sticker is in the library.
                guard !self.isPanelVisible else { return }
                guard made.isNew else {
                    HUDController.shared.show("Already one of your stickers", thumbnail: made.item.fileURL)
                    return
                }
                let undo = HUDAction(title: "Undo") { [weak self] in
                    self?.friends.removeOwnSticker(id: made.item.id)
                    HUDController.shared.show("Sticker removed")
                }
                HUDController.shared.show("Saved “\(made.item.displayName)” as a sticker", thumbnail: made.item.fileURL, action: undo)
            } else {
                // Shown even over a reopened panel (like "Couldn’t read that image"): nothing else would say it failed.
                HUDController.shared.show("Couldn’t find you in that one.")
            }
        }
    }

    // MARK: - Camera

    private func handleSample(_ sample: ExpressionSample) {
        guard isPanelVisible, !showSetupCard else { return }
        if mode == .warming {
            mode = .live
            liveSince = sample.timestamp
            faceMissing = false
            warmPoseNamer()
        }
        // In text, image and more-like modes the camera only feeds the (dimmed) mirror; in the capture view it
        // only feeds the capture picture.
        guard mode == .live, !isCaptureOpen else {
            earlyMood.reset()
            standingBack.reset()
            return
        }

        standingBack.observe(bodyWidth: camera.bodyWidth, at: sample.timestamp)
        let queryChanged = tracker.ingest(sample)
        // Search the web for the expression being held, so its results are in by the time the hold completes. Not for
        // a clear gesture with no word of its own: it is searched by the words describing it, known once it is held,
        // and its face's mood would spend one of GIPHY's searches on GIFs never shown.
        let candidateMood = tracker.candidate.flatMap { candidate -> Mood? in
            if case .pose? = PoseBadge.of(candidate, baseline: tracker.baseline) { return nil }
            return MoodClassifier.mood(for: candidate.face, pose: candidate.pose, shape: candidate.shape, baseline: tracker.baseline)
        }
        if let mood = earlyMood.observe(candidateMood, at: sample.timestamp) {
            web.warm(mood)
        }
        let progress = queryChanged ? 0 : tracker.holdProgress
        if holdProgress != progress { holdProgress = progress }

        updateFaceMissing(with: sample)

        if queryChanged {
            let previousPose = heldPose
            runExpressionSearch(animate: true, newQuery: true)
            notePoseCaught(after: previousPose)
        }
        refreshHint()
    }

    /// A pose newly behind the search (another word, or a pose after the face alone) flashes the mirror; the same
    /// pose held while only the face changes doesn't.
    private func notePoseCaught(after previous: PoseBadge?) {
        guard let heldPose, heldPose != previous else { return }
        poseCatches &+= 1
    }

    /// "Can't see your face" after 1.5 s without a face; it clears once the face has been back for 1 s. A clear
    /// gesture hiding the face (a facepalm) counts as being seen.
    private func updateFaceMissing(with sample: ExpressionSample) {
        let gestureStandsIn = (sample.pose?.gestureStrength ?? 0) >= tracker.config.minimumGestureWithoutFace
        guard sample.face != nil || gestureStandsIn else {
            let lastSeen = max(tracker.lastSeenTimestamp ?? 0, liveSince ?? sample.timestamp)
            // A real gap starts the 1 s over; a frame or two without a detection (dim light) doesn't.
            if sample.timestamp - lastSeen >= AppModel.faceGap {
                faceBackSince = nil
            }
            if !faceMissing && sample.timestamp - lastSeen >= AppModel.faceMissingDelay {
                faceMissing = true
            }
            return
        }
        guard faceMissing else { return }
        let since = faceBackSince ?? sample.timestamp
        faceBackSince = since
        if sample.timestamp - since >= AppModel.faceBackDelay {
            faceMissing = false
            faceBackSince = nil
        }
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
        warmPoseNamer()
    }

    /// The camera went live: the on-device model loads now (where the Mac has one), so the first pose with no word of
    /// its own is named without waiting for it.
    private func warmPoseNamer() {
        guard poseNamer.isAvailable else { return }
        poseNamer.prewarm()
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

    /// Recent in this app; else the newest own memes. With none at all (first run), the GIPHY row shows GIPHY's
    /// "reaction" GIFs so the panel is never empty; the classic memes row shows the most popular templates until a
    /// face or words pick others. Library changes refresh it with `animateNew` (amber ring on arrivals) and without
    /// moving the focus.
    private func showRecentResults(animateNew: Bool = false, resetFocus: Bool = true) {
        resultSource = .recent
        if heldPose != nil { heldPose = nil }
        searchReadout = nil
        searchGeneration += 1
        let ranker = Ranker(baseline: tracker.baseline)
        let recentIDs = store.recents.recent(appBundleID: previousBundleID)
        let ranked = ranker.rank(
            ownItems,
            query: .recent(appBundleID: previousBundleID),
            people: store.people,
            recents: recentIDs,
            limit: limit
        )
        setResults(ranked, animateNew: animateNew, resetFocus: resetFocus)
        // GIPHY's "reaction" GIFs when you have no memes yet, or when no face can be read (no camera, denied, in use,
        // not yet allowed) to ask GIPHY about.
        let readsFaces = mode != .cameraOff && mode != .cameraBusy && mode != .prompt
        if (ranked.isEmpty || !readsFaces) && giphyQuery == nil {
            showGiphy(for: .mood(.reaction))
        }
        if templateQuery == nil {
            showTemplates(for: .mood(.reaction))
        }
    }

    /// Face query: mood → weights → your memes ranked at once; the GIPHY row shows GIPHY's results for the mood
    /// (often already searched while the face was being held), the classic memes row the templates for it.
    /// `newQuery`: the tracker just caught a new face (or Space snapped one), so web rows already showing its mood turn
    /// to their next GIFs and templates; re-showing the same face (pins, Esc, library changes) leaves them as they are.
    ///
    /// A clear gesture with no word of its own (`PoseDescription.of`) is searched by the words describing it instead of
    /// the face's mood: the on-device model's name for it, else the rule's phrase ("flexing", "rock on"). Your memes are
    /// ranked at once with the words known now (`heldPoseWords`). When the model can name the pose and was never asked
    /// about it, the web rows wait for its answer (`describe`, at most `PoseNamer.timeout`): the GIPHY row shows it is
    /// loading, the classic memes keep what they show. Re-showing the same query searches the words found for it
    /// (`describedPhrase`) and never asks again.
    private func runExpressionSearch(animate: Bool, newQuery: Bool = false) {
        guard let sample = tracker.query else {
            showRecentResults()
            return
        }
        resultSource = .expression
        let mood = MoodClassifier.mood(for: sample.face, pose: sample.pose, shape: sample.shape, baseline: tracker.baseline)
        let badge = PoseBadge.of(sample, baseline: tracker.baseline)
        if heldPose != badge { heldPose = badge }
        let describedPose = PoseDescription.of(sample, baseline: tracker.baseline)
        // A question about another query (or about a pose no longer described) is dropped; one about this query goes on.
        if describedPose == nil || describingTimestamp != sample.timestamp {
            cancelDescribing()
        }
        let poseWords = describedPose.map { heldPoseWords(for: $0, timestamp: sample.timestamp) }
        switch badge {
        case .word?:
            searchReadout = MoodReadout(word: mood.label, source: .pose)
        case .pose?:
            let source: MoodReadout.Source = sample.face == nil ? .pose : .faceAndPose
            if let poseWords {
                searchReadout = MoodReadout(word: poseWords.phrase, source: source, named: poseWords.named)
            } else {
                searchReadout = MoodReadout(word: mood.label, source: source)
            }
        case nil:
            // No face and no pose word reads "reaction": nothing worth showing.
            searchReadout = mood == .reaction ? nil : MoodReadout(word: mood.label, source: .face)
        }
        let deviation = sample.face.map { tracker.baseline.deviation(of: $0) } ?? [:]
        let weights = FeatureWeights.automatic(deviation: deviation, poseStrength: sample.pose?.gestureStrength ?? 0).pinning(pins)
        currentWeights = weights
        searchGeneration += 1

        let ranker = Ranker(baseline: tracker.baseline)
        let phraseWords = poseWords.map { [$0.phrase] } ?? []
        let ranked = ranker.rank(ownItems, query: .expression(sample, weights: weights, words: phraseWords),
                                 people: store.people, limit: limit)
        setResults(ranked, animateNew: animate, resetFocus: true)
        guard let description = describedPose, let described = poseWords else {
            showGiphy(for: .mood(mood), turningPage: newQuery)
            showTemplates(for: .mood(mood), turningPage: newQuery)
            return
        }
        guard described.waits else {
            // The words are settled for this query: a question still running about it changes nothing.
            cancelDescribing()
            let query = WebQuery.described(from: described.phrase) ?? .mood(mood)
            showGiphy(for: query, turningPage: newQuery)
            showTemplates(for: query, turningPage: newQuery, fallback: mood)
            return
        }
        // The model's words come within `PoseNamer.timeout`: GIFs for the rule's phrase or the face's mood would cost
        // one of GIPHY's searches and be replaced at once.
        awaitGiphyName()
        if templateQuery == nil {
            showTemplates(for: .mood(mood))
        }
        if describeTask == nil {
            describe(description, of: sample, mood: mood, animate: animate, newQuery: newQuery)
        }
    }

    /// The words the held pose is searched by now, and whether its web rows wait for the model: the words kept for
    /// this query (`describedPhrase`), else `describedWords(for:namer:)`'s, kept for the query unless they wait.
    private func heldPoseWords(for description: PoseDescription,
                               timestamp: TimeInterval) -> (phrase: String, named: Bool, waits: Bool) {
        if let kept = describedPhrase, kept.timestamp == timestamp {
            return (phrase: kept.phrase, named: kept.named, waits: false)
        }
        let words = AppModel.describedWords(for: description, namer: poseNamer)
        if !words.waits {
            describedPhrase = DescribedPhrase(timestamp: timestamp, phrase: words.phrase, named: words.named)
        }
        return words
    }

    /// What a described pose is searched by when it is held: the model's name for it when it gave one before
    /// (`named`); the rule's phrase (`PoseDescription.phrase`) when the model had no name for it or the Mac has no
    /// model; the rule's phrase with `waits` when the model can name the pose and was never asked about it, so the web
    /// rows wait for its answer.
    static func describedWords(for description: PoseDescription,
                               namer: any PoseNaming) -> (phrase: String, named: Bool, waits: Bool) {
        if let asked = namer.cachedName(for: description) {
            return (phrase: asked ?? description.phrase, named: asked != nil, waits: false)
        }
        return (phrase: description.phrase, named: false, waits: namer.isAvailable)
    }

    /// Asks the model for the held pose's name, then shows it: the readout (with sparkles), your memes ranked with its
    /// words when they aren't the rule's phrase, and the GIPHY row and the classic memes for them. An answer for a
    /// query no longer shown (a new face or pose, the panel closed or reopened, typing, the capture view) is dropped;
    /// the model keeps it for the next time the pose is held.
    private func describe(_ description: PoseDescription, of sample: ExpressionSample, mood: Mood, animate: Bool,
                          newQuery: Bool) {
        let session = sessionID
        let timestamp = sample.timestamp
        let source: MoodReadout.Source = sample.face == nil ? .pose : .faceAndPose
        describingTimestamp = timestamp
        describeTask = Task { [weak self] in
            guard let self else { return }
            let name = await self.poseNamer.name(description)
            guard !Task.isCancelled, session == self.sessionID else { return }
            self.describeTask = nil
            self.describingTimestamp = nil
            guard self.isPanelVisible, self.mode == .live, !self.isCaptureOpen, self.resultSource == .expression,
                  self.tracker.query?.timestamp == timestamp else {
                self.stopAwaitingGiphyName()
                return
            }
            let phrase = name ?? description.phrase
            let named = name != nil
            self.describedPhrase = DescribedPhrase(timestamp: timestamp, phrase: phrase, named: named)
            self.searchReadout = MoodReadout(word: phrase, source: source, named: named)
            if phrase != description.phrase {
                // Your memes were ranked by the rule's phrase; the model's words may name others.
                self.searchGeneration += 1
                let ranker = Ranker(baseline: self.tracker.baseline)
                let ranked = ranker.rank(self.ownItems, query: .expression(sample, weights: self.currentWeights, words: [phrase]),
                                         people: self.store.people, limit: self.limit)
                self.setResults(ranked, animateNew: animate, resetFocus: false)
            }
            let query = WebQuery.described(from: phrase) ?? .mood(mood)
            self.showGiphy(for: query, turningPage: newQuery)
            self.showTemplates(for: query, turningPage: newQuery, fallback: mood)
            self.refreshHint()
        }
    }

    /// Stops waiting for the held pose's name (a new query, the panel closing). The model still answers, and keeps the
    /// answer for the next time the pose is held.
    private func cancelDescribing() {
        describeTask?.cancel()
        describeTask = nil
        describingTimestamp = nil
    }

    // MARK: - GIPHY row

    /// Shows GIPHY's results for `query` in the GIPHY row: at once when searched in the last 10 minutes, else when
    /// the search answers. The same query already showing (or loading) is left alone, unless `turningPage` (a new face
    /// caught with the same mood): then the row shows the next `Theme.columns` of GIPHY's results, wrapping around.
    /// After waiting for a pose's name (`awaitGiphyName`), words that came out the same as the row's show its GIFs
    /// again, turned the same way.
    private func showGiphy(for query: WebQuery, turningPage: Bool = false) {
        guard showsGiphyRow else { return }
        if giphyAwaitsName {
            giphyAwaitsName = false
            if query == giphyQuery && !giphyFound.isEmpty {
                if isGiphyLoading { isGiphyLoading = false }
                if turningPage && giphyFound.count > Theme.columns {
                    giphyPage += 1
                }
                showGiphyPage()
                return
            }
        } else if query == giphyQuery && (isGiphyLoading || !giphyResults.isEmpty) {
            if turningPage && !isGiphyLoading && giphyFound.count > Theme.columns {
                giphyPage += 1
                showGiphyPage()
            }
            return
        }
        giphyGeneration += 1
        let generation = giphyGeneration
        giphyTask?.cancel()
        giphyTask = nil
        giphyQuery = query
        giphyPage = 0
        if giphyUnavailable { giphyUnavailable = false }
        if let cached = web.cachedGIFs(for: query) {
            if isGiphyLoading { isGiphyLoading = false }
            setGiphyResults(cached)
            return
        }
        // Another query's GIFs never sit under this one.
        setGiphyResults([])
        isGiphyLoading = true
        giphyTask = Task { [weak self] in
            guard let self else { return }
            let found = await self.web.gifs(for: query)
            guard !Task.isCancelled, generation == self.giphyGeneration else { return }
            self.isGiphyLoading = false
            self.giphyTask = nil
            if let found {
                self.setGiphyResults(found)
            } else {
                self.giphyUnavailable = true
            }
        }
    }

    /// Keeps all of `gifs` for paging and shows the current page of them.
    private func setGiphyResults(_ gifs: [WebGIF]) {
        giphyFound = gifs
        showGiphyPage()
    }

    /// Shows `giphyPage`'s GIFs of `giphyFound` in the row.
    private func showGiphyPage() {
        let row = WebDiscover.page(giphyPage, of: giphyFound, size: Theme.columns)
        if giphyResults != row {
            giphyResults = row
        }
        normalizeFocus()
        // The first GIF copies instantly; others start downloading when focused.
        if let first = row.first {
            web.prefetchForCopy([first])
        }
    }

    private func clearGiphyRow() {
        giphyGeneration += 1
        giphyTask?.cancel()
        giphyTask = nil
        giphyWordsTask?.cancel()
        giphyWordsTask = nil
        giphyAwaitsName = false
        giphyFound = []
        giphyPage = 0
        if !giphyResults.isEmpty { giphyResults = [] }
        if giphyQuery != nil { giphyQuery = nil }
        if isGiphyLoading { isGiphyLoading = false }
        if giphyUnavailable { giphyUnavailable = false }
    }

    /// The GIPHY row while the held pose is being named (`describe`): empty and loading, as for a new query, until
    /// `showGiphy` gets the name's words. A search still answering for the row is dropped from it (WebDiscover keeps
    /// its results); what the row found before stays in `giphyFound`, so a name that comes out the same words turns
    /// their page.
    private func awaitGiphyName() {
        guard showsGiphyRow else { return }
        giphyGeneration += 1
        giphyTask?.cancel()
        giphyTask = nil
        giphyAwaitsName = true
        if giphyUnavailable { giphyUnavailable = false }
        if !giphyResults.isEmpty { giphyResults = [] }
        if !isGiphyLoading { isGiphyLoading = true }
        normalizeFocus()
    }

    /// The held pose's name won't be shown (the search moved on: typing, the capture view): the GIPHY row shows what
    /// it had again, searching its query again (or joining that search) when the wait dropped it before it answered.
    private func stopAwaitingGiphyName() {
        guard giphyAwaitsName else { return }
        giphyAwaitsName = false
        if isGiphyLoading { isGiphyLoading = false }
        if let query = giphyQuery, giphyFound.isEmpty {
            showGiphy(for: query)
        } else {
            showGiphyPage()
        }
    }

    /// The GIPHY row follows typed words once typing pauses (at once when GIPHY answered them in the last 10
    /// minutes). nil words (only filter words, names or a single letter) leave the row as it is.
    private func scheduleGiphyWords(_ query: WebQuery?) {
        giphyWordsTask?.cancel()
        giphyWordsTask = nil
        guard showsGiphyRow, let query, query != giphyQuery else { return }
        if web.cachedGIFs(for: query) != nil {
            showGiphy(for: query)
            return
        }
        giphyWordsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: AppModel.giphyTypingPauseNanoseconds)
            guard !Task.isCancelled, let self, self.mode == .text else { return }
            self.giphyWordsTask = nil
            self.showGiphy(for: query)
        }
    }

    // MARK: - Classic memes row

    /// Shows the templates for `query` (picked on the Mac from Imgflip's list): at once from the list kept from
    /// earlier, else once Imgflip answers. The same query already showing (or loading) is left alone, unless
    /// `turningPage` (a new face caught with the same mood, or a pose with the same words): then the row shows the
    /// mood's (or the words') next templates. `fallback`: the face's mood, whose templates follow those a described
    /// pose's words name (`pickTemplates`).
    private func showTemplates(for query: WebQuery, turningPage: Bool = false, fallback: Mood = .reaction) {
        guard showsTemplateRow else { return }
        if query == templateQuery && (isTemplatesLoading || !templateResults.isEmpty) {
            if turningPage, !isTemplatesLoading, !query.isTyped, let list = templates.cachedList {
                templatePage += 1
                setTemplateResults(AppModel.pickTemplates(for: query, from: list, page: templatePage,
                                                          fallback: templateFallback))
            }
            return
        }
        templateGeneration += 1
        let generation = templateGeneration
        templateTask?.cancel()
        templateTask = nil
        templateQuery = query
        templateFallback = fallback
        templatePage = 0
        if templatesUnavailable { templatesUnavailable = false }
        if let list = templates.cachedList {
            if isTemplatesLoading { isTemplatesLoading = false }
            setTemplateResults(AppModel.pickTemplates(for: query, from: list, page: templatePage, fallback: fallback))
        } else {
            setTemplateResults([])
            isTemplatesLoading = true
        }
        // A list older than a day is refreshed (picked again if it changed); with none, this is the first fetch.
        templateTask = Task { [weak self] in
            guard let self else { return }
            let list = await self.templates.templates()
            guard !Task.isCancelled, generation == self.templateGeneration else { return }
            self.templateTask = nil
            if self.isTemplatesLoading { self.isTemplatesLoading = false }
            guard let list else {
                if self.templateResults.isEmpty { self.templatesUnavailable = true }
                return
            }
            self.setTemplateResults(AppModel.pickTemplates(for: query, from: list, page: self.templatePage,
                                                           fallback: fallback))
        }
    }

    /// The classic memes row for `query`: for a mood, its `page`th group of `Theme.columns` templates (page 0 the ones
    /// made for it, then the most popular; later pages the next ones, wrapping around); for words, the best matches;
    /// for a described pose, the templates its words name, then `fallback`'s (the face's mood: those made for it, then
    /// the most popular), paged like a mood's, so the row is never empty.
    static func pickTemplates(for query: WebQuery, from list: [MemeTemplate], page: Int = 0,
                              fallback: Mood = .reaction) -> [MemeTemplate] {
        let refs = list.map(\.ref)
        let indexes: [Int]
        switch query {
        case let .mood(mood):
            indexes = MemeTemplateCatalog.pick(for: mood, from: refs, limit: Theme.columns, page: page)
        case let .words(text):
            indexes = MemeTemplateCatalog.pick(forTerms: [text], from: refs, limit: Theme.columns)
        case let .described(phrase):
            indexes = MemeTemplateCatalog.pick(forDescription: phrase, mood: fallback, from: refs, limit: Theme.columns,
                                               page: page)
        }
        return indexes.map { list[$0] }
    }

    private func setTemplateResults(_ picked: [MemeTemplate]) {
        let row = Array(picked.prefix(Theme.columns))
        if templateResults != row {
            templateResults = row
        }
        normalizeFocus()
    }

    private func clearTemplateRow() {
        templateGeneration += 1
        templateTask?.cancel()
        templateTask = nil
        templatePage = 0
        templateFallback = .reaction
        if !templateResults.isEmpty { templateResults = [] }
        if templateQuery != nil { templateQuery = nil }
        if isTemplatesLoading { isTemplatesLoading = false }
        if templatesUnavailable { templatesUnavailable = false }
    }

    /// Leaving typed words: the GIPHY row stops showing results for them, the classic memes go back to the popular
    /// ones (a face, if one is held, picks others right after).
    private func dropTypedWebQueries() {
        giphyWordsTask?.cancel()
        giphyWordsTask = nil
        if case .words? = giphyQuery { clearGiphyRow() }
        if case .words? = templateQuery { showTemplates(for: .mood(.reaction)) }
    }

    private var tileGrid: TileGrid {
        TileGrid(columns: Theme.columns, ownRows: ownRows, ownCount: results.count, giphyCount: giphyResults.count,
                 templateCount: templateResults.count)
    }

    /// Follows how many memes you have, not what a search found, so the panel keeps its height as you search; but
    /// always enough rows for what is shown (a typed search can find personal photos when you have no memes).
    private func refreshOwnRows(showing shown: Int) {
        let memes = ownItems.lazy.filter { $0.tier != .skipped }.count
        let libraryRows = memes == 0 ? 0 : (memes <= Theme.columns ? 1 : Theme.rows)
        let neededRows = (shown + Theme.columns - 1) / Theme.columns
        let rows = min(Theme.rows, max(libraryRows, neededRows))
        if ownRows != rows {
            ownRows = rows
        }
    }

    /// Where the focus starts: the first tile top to bottom (`TileGrid.firstSlot`: the first meme, else the first
    /// classic meme, else the first GIF), or the classic memes row's first slot while nothing has come yet. A typed,
    /// image or more-like search starts on nothing when it finds no meme, so ↵ copies nothing; with no row of memes
    /// drawn, on the first tile below.
    private var startSlot: Int {
        let grid = tileGrid
        switch resultSource {
        case .recent, .expression:
            return grid.firstSlot ?? grid.templateStart
        case .text, .image, .moreLike:
            return ownRows > 0 ? 0 : (grid.firstSlot ?? grid.templateStart)
        }
    }

    private func pick(atSlot slot: Int) -> Pick? {
        let grid = tileGrid
        guard grid.isFilled(slot) else { return nil }
        switch grid.section(of: slot) {
        case .own:
            return .meme(results[slot].item)
        case .template:
            return .template(templateResults[slot - grid.templateStart])
        case .giphy:
            return .gif(giphyResults[slot - grid.giphyStart])
        }
    }

    /// Keeps the focus on a tile: before the user moves it, on the start slot (`startSlot`); after, on the nearest one
    /// in the same row.
    private func normalizeFocus() {
        let grid = tileGrid
        // Until the user points somewhere, the focus follows the start slot as rows fill in: with no memes, the first
        // classic meme, or the first GIF when the classic memes have nothing.
        if !userInteracted {
            let target = startSlot
            if focusedIndex != target {
                focusedIndex = target
            }
            return
        }
        guard !grid.isFilled(focusedIndex) else { return }
        let target: Int
        switch grid.section(of: focusedIndex) {
        case .own:
            // Your memes went: the last one left, else the first tile below (nothing while there is none).
            target = grid.ownCount > 0 ? grid.ownCount - 1 : (grid.firstSlot ?? focusedIndex)
        case .template:
            // The row's last tile; its start while it loads (or found nothing): it shows what is coming.
            target = showsTemplateRow ? grid.templateStart + max(0, grid.templateCount - 1) : (grid.firstSlot ?? focusedIndex)
        case .giphy:
            target = showsGiphyRow ? grid.giphyStart + max(0, grid.giphyCount - 1) : (grid.firstSlot ?? focusedIndex)
        }
        if focusedIndex != target {
            focusedIndex = target
        }
    }

    private func runTextSearch() {
        let raw = queryText
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        resultSource = .text
        searchGeneration += 1
        let ranker = Ranker(baseline: tracker.baseline)
        let face = showsFaceToken ? faceTokenSample : nil
        let weights = showsFaceToken ? faceTokenWeights : FeatureWeights.uniform
        let ranked = ranker.rank(ownItems, query: .text(raw, face: face, weights: weights), people: store.people, limit: limit)
        setResults(ranked, animateNew: false, resetFocus: true)
        updateNamingPrompt(raw: raw, hasResults: !ranked.isEmpty)
        // GIPHY and the classic memes follow the words too (without filter words or your people's names). A name
        // being set up ("Is one of these Sam?") is not a person's name yet: while the panel asks, a word that isn't
        // ordinary meme vocabulary ("sad", "facepalm", "cat") stays off GIPHY.
        let parsed = TextQuery.parse(raw, people: store.people)
        let words = WebQuery.words(from: parsed.terms)
        let pendingName = naming != nil ? parsed.possibleName : nil
        let holdsBackName = pendingName.map { !MemeTemplateCatalog.isMemeWord($0) } ?? false
        scheduleGiphyWords(holdsBackName ? nil : words)
        if let words {
            showTemplates(for: words)
        }
    }

    private func runImageSearch() {
        guard let query = imageQuery else { return }
        resultSource = .image
        searchGeneration += 1
        // The query image itself (once kept) is not a result.
        let excludedIDs = Set(keptImageBatch?.addedIDs ?? [])
        let queryURL = queryImageURL?.standardizedFileURL
        let pool = ownItems.filter { item in
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
        let ranker = Ranker(baseline: tracker.baseline)
        let ranked = ranker.rank(ownItems, query: .moreLike(item), people: store.people, limit: limit)
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

    /// Your memes: the library without GIPHY's GIFs (they have their own row and are never kept in it).
    private var ownItems: [LibraryItem] {
        store.items.filter { $0.kind != .web }
    }

    private func setResults(_ newResults: [RankedResult], animateNew: Bool, resetFocus: Bool) {
        let limited = Array(newResults.prefix(limit))
        // The web rows' slots move with the number of meme rows; a focused classic meme or GIF keeps its place.
        let oldWebStart = tileGrid.webStart
        refreshOwnRows(showing: limited.count)
        let newWebStart = tileGrid.webStart
        if !resetFocus && newWebStart != oldWebStart {
            if focusedIndex >= oldWebStart {
                focusedIndex = newWebStart + (focusedIndex - oldWebStart)
            } else if focusedIndex >= newWebStart {
                // A meme of yours whose row went: the last meme left, else the first web tile.
                focusedIndex = newWebStart > 0 ? newWebStart - 1 : (tileGrid.firstSlot ?? newWebStart)
            }
        }
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
            let first = startSlot
            if focusedIndex != first { focusedIndex = first }
        } else {
            normalizeFocus()
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

    /// A focused GIPHY GIF or classic meme starts downloading, so copying it is instant.
    private func prefetchFocused() {
        switch focusedPick {
        case let .gif(gif)?:
            web.prefetchForCopy([gif])
        case let .template(template)?:
            templates.prefetchForCopy(template)
        case .meme?, nil:
            break
        }
    }

    // MARK: - Text

    private func queryTextWasEdited(previous: String) {
        // A GIPHY search waits for typing to pause: any keystroke restarts the wait.
        giphyWordsTask?.cancel()
        giphyWordsTask = nil
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

    /// The held query kept while typing shows no face (a gesture hid it): the token reads "your pose".
    var faceTokenIsPose: Bool {
        showsFaceToken && faceTokenSample?.face == nil
    }

    /// Typing right after opening stops the camera; later, a held face (or a clear gesture that hid it) stays as a
    /// removable token.
    private func enterTextMode() {
        let began = textBeganAt ?? CACurrentMediaTime()
        let typedRightAfterOpening = began - shownAt < AppModel.typingStopsCameraWindow
        resetQueryImage()
        if holdProgress != 0 { holdProgress = 0 }
        if !typedRightAfterOpening, let held = tracker.query,
           held.face != nil || (held.pose?.gestureStrength ?? 0) >= Ranker.gestureWithoutFace, camera.isRunning {
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
        dropTypedWebQueries()
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

    private func performCommit(_ pick: Pick, token: Int, session: Int, appBundleID: String?) async {
        defer {
            // A pick dropped meanwhile (the capture view opened) leaves the lock to the pick that replaced it.
            if committingSession == session, token == commitToken { committingSession = nil }
        }
        let resolved = await resolveFileForCopy(pick)
        // A newer pick (made after reopening the panel) owns the clipboard.
        guard token == commitToken else { return }
        // The panel this pick came from may have closed (and another opened) while a GIPHY GIF downloaded.
        let isSameOpen = session == sessionID && isPanelVisible
        guard let fileURL = resolved else {
            // A kept image or sticker deleted in Finder while the panel was open: forget it (its tile goes too).
            if case .meme = pick {
                indexer.removeItemsWithMissingFiles()
            }
            HUDController.shared.show("Couldn’t copy that one. Try another.")
            return
        }
        do {
            try Clipboard.copy(fileURL: fileURL, item: clipboardItem(for: pick, fileURL: fileURL))
        } catch {
            modelLog.error("Copying to the pasteboard failed")
            HUDController.shared.show("Couldn’t copy that one. Try another.")
            return
        }
        // Only your memes are remembered as sent; GIPHY's GIFs are never kept.
        if case let .meme(item) = pick {
            recordSent(item, appBundleID: appBundleID)
        }

        if !store.settings.hasCompletedFirstRun, isSameOpen {
            // First pick: the panel stays open with the You're-set card (the camera has nothing to show meanwhile).
            var settings = store.settings
            settings.hasCompletedFirstRun = true
            store.settings = settings
            showSetupCard = true
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
        HUDController.shared.show("Copied “\(pick.title)” · ⌘V — not sent", thumbnail: fileURL)
    }

    /// The local file to put on the pasteboard; GIPHY GIFs and classic memes are downloaded first ("Copying…" if that
    /// is slow).
    private func resolveFileForCopy(_ pick: Pick) async -> URL? {
        switch pick {
        case let .meme(item):
            return FileManager.default.fileExists(atPath: item.fileURL.path) ? item.fileURL : nil
        case let .gif(gif):
            let slowNotice = AppModel.slowCopyNotice()
            let url = await web.prepareForCopy(gif)
            slowNotice.cancel()
            return url
        case let .template(template):
            let slowNotice = AppModel.slowCopyNotice()
            let url = await templates.prepareForCopy(template)
            slowNotice.cancel()
            return url
        }
    }

    /// "Copying…" once a download takes longer than `slowCopyNanoseconds`; cancel it when the file is there.
    private static func slowCopyNotice() -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: AppModel.slowCopyNanoseconds)
            guard !Task.isCancelled else { return }
            HUDController.shared.show("Copying…")
        }
    }

    /// What the clipboard names the copy after: your meme itself, a GIPHY GIF as "reaction.gif", a classic meme as
    /// "reaction.png".
    private func clipboardItem(for pick: Pick, fileURL: URL) -> LibraryItem {
        switch pick {
        case let .meme(item):
            return item
        case let .gif(gif):
            return LibraryItem(fileURL: fileURL, displayName: gif.title, kind: .web, source: "GIPHY", contentHash: "giphy:" + gif.id, isAnimated: true, remoteURL: gif.fullURL)
        case let .template(template):
            return LibraryItem(fileURL: fileURL, displayName: template.name, kind: .web, source: "Imgflip", contentHash: "imgflip:" + template.id, isAnimated: false, remoteURL: template.url)
        }
    }

    private func recordSent(_ item: LibraryItem, appBundleID: String?) {
        if var stored = store.item(id: item.id) {
            stored.timesSent += 1
            stored.lastSentAt = Date()
            store.update(stored)
        }
        var recents = store.recents
        recents.record(item.id, appBundleID: appBundleID)
        store.recents = recents
    }

    /// GIPHY tiles drag the full GIF, fetched when the receiving app asks for it, as "reaction.gif".
    private func giphyDragProvider(for gif: WebGIF) -> NSItemProvider {
        let provider = NSItemProvider()
        let web = self.web
        let fileName = "reaction.gif"
        provider.suggestedName = "reaction"
        // The load handler runs on a background queue when the receiving app asks for the file, so it is
        // explicitly @Sendable (not main-actor isolated) and hops to the main actor for the download.
        provider.registerFileRepresentation(forTypeIdentifier: UTType.gif.identifier, fileOptions: [], visibility: .all) { @Sendable completion in
            Task { @MainActor in
                let prepared = await web.prepareForCopy(gif)
                let shared = prepared.flatMap { makeDragCopy(of: $0, named: fileName) }
                completion(shared, false, nil)
            }
            return nil
        }
        return provider
    }

    /// Classic memes drag the template, fetched when the receiving app asks for it, as "meme.jpg" (or .png).
    private func templateDragProvider(for template: MemeTemplate) -> NSItemProvider {
        let provider = NSItemProvider()
        let templates = self.templates
        let pathExtension = template.url.pathExtension.lowercased()
        let type: UTType = pathExtension == "png" ? .png : (pathExtension == "gif" ? .gif : .jpeg)
        let fileName = "meme." + (type.preferredFilenameExtension ?? "jpg")
        provider.suggestedName = "meme"
        // Like GIPHY's: the load handler runs on a background queue and hops to the main actor for the download.
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { @Sendable completion in
            Task { @MainActor in
                let prepared = await templates.prepareForCopy(template)
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
        let showsRemovedItem = results.contains { store.item(id: $0.item.id) == nil }
        if resultSource == .recent {
            // Fill the recent grid as memes arrive (amber ring, focus kept), but never reshuffle tiles
            // the user is pointing at.
            if showsRemovedItem || !userInteracted || results.isEmpty {
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
        } else {
            state = .hidden
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

    // MARK: - Hint

    private func refreshHint() {
        let newHint = computeHint()
        if hint != newHint {
            hint = newHint
        }
        let newReadout = computeReadout()
        if readout != newReadout {
            readout = newReadout
        }
    }

    /// The search's word while live, unless pins (with their Clear) are set, or the face it came from (alone or with a
    /// pose) is lost: then the hint says so.
    private func computeReadout() -> MoodReadout? {
        guard mode == .live, pins.isEmpty, let searchReadout else { return nil }
        if searchReadout.source != .pose && faceMissing {
            return nil
        }
        return searchReadout
    }

    private func computeHint() -> PanelHint {
        switch mode {
        case .prompt:
            return PanelHint(title: HintCopy.promptTitle, subtitle: HintCopy.promptSubtitle, actionTitle: nil, action: nil)
        case .warming:
            return PanelHint(title: HintCopy.warmingTitle, subtitle: HintCopy.warmingSubtitle, actionTitle: nil, action: nil)
        case .live:
            if faceMissing {
                // Standing back, the face is too small to read: that's fine, the pose is read.
                if standingBack.isStandingBack {
                    return PanelHint(title: HintCopy.standingBackTitle, subtitle: HintCopy.standingBackSubtitle, actionTitle: nil, action: nil)
                }
                return PanelHint(title: HintCopy.noFaceTitle, subtitle: HintCopy.noFaceSubtitle, actionTitle: nil, action: nil)
            }
            if !pins.isEmpty {
                return PanelHint(title: "Focusing on " + pinDescription, subtitle: nil, actionTitle: HintCopy.clearAction, action: .clearPins)
            }
            // The same words the whole time the camera reads you: the ring around the mirror shows a face being held.
            return PanelHint(title: HintCopy.liveTitle, subtitle: nil, actionTitle: nil, action: nil)
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
        closeCapture()
        cancelSessionTasks()
        clearTextState()
        resetQueryImage()
        tracker = PeakHoldTracker(baseline: tracker.baseline)
        earlyMood.reset()
        standingBack.reset()
        if heldPose != nil { heldPose = nil }
        searchReadout = nil
        cancelDescribing()
        describedPhrase = nil
        clearGiphyRow()
        showsGiphyRow = store.settings.webDiscoverEnabled && web.hasAPIKey
        clearTemplateRow()
        showsTemplateRow = store.settings.webDiscoverEnabled
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
        shownSummaryID = nil
    }

    private func cancelSessionTasks() {
        textDebounceTask?.cancel()
        textDebounceTask = nil
        giphyTask?.cancel()
        giphyTask = nil
        giphyGeneration += 1
        giphyWordsTask?.cancel()
        giphyWordsTask = nil
        templateTask?.cancel()
        templateTask = nil
        templateGeneration += 1
        cancelDescribing()
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
