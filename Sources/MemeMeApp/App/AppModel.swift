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

/// `idle`: the panel opens on search with the camera off; the other camera modes only while face search is on (⌘F).
enum PanelMode: Equatable { case idle, prompt, warming, live, text, image, moreLike, cameraOff, cameraBusy }

/// A list over the panel: the source menu (beside the search field) or the actions for the selected result (⌘K).
enum PanelMenu: Equatable { case sources, actions }

/// Which of My Stickers' chips shows: All (a row per group, then Ungrouped), one group's stickers, or those in none.
enum StickerGroupFilter: Hashable { case all, group(UUID), ungrouped }

/// A chip over My Stickers' grid: All, a group, or Ungrouped.
struct GroupChip: Identifiable, Equatable {
    let filter: StickerGroupFilter
    let title: String
    /// Its stickers; nil for All.
    let count: Int?
    /// A saved search: it fills itself (sparkles on the chip).
    var isLive = false
    var id: StickerGroupFilter { filter }
    var groupID: UUID? {
        if case let .group(id) = filter { return id }
        return nil
    }
}

/// What the actions menu (⌘K) can do with the selected result.
enum PickAction: String, CaseIterable, Equatable {
    case copy, copyLink, copyMarkdown, toggleFavorite, moreLikeThis, showInFinder, openInBrowser, deleteSticker
}

/// One row of a menu over the panel.
struct MenuRow: Identifiable, Equatable {
    let id: String
    let title: String
    /// An SF Symbol, or a letter on a small square (GIPHY's sources).
    let symbol: String?
    let letter: String?
    let keys: [String]
    let isChecked: Bool
    /// A line goes above it.
    let startsGroup: Bool
    /// A small heading over it, under the line ("Groups").
    var heading: String? = nil
}

enum HintAction: Equatable { case backToFace, keepImage, turnOnCamera, useCamera }

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
    static let idleTitle = "Search with your face"
    static let idleSubtitle = "⌘F turns on the camera."
    static let promptTitle = "Make a face."
    static let promptSubtitle = "That’s the search. There’s no button to press."
    static let warmingTitle = "Starting camera…"
    static let warmingSubtitle = "Your recent picks are ready."
    static let liveTitle = "Make a face or a pose."
    /// While a face is held toward the search, under the big mirror.
    static let holdingTitle = "Hold it…"
    static let holdingSubtitle = "Then it searches."
    static let standingBackTitle = "Reading your pose"
    static let standingBackSubtitle = "Hold each pose for a second. Come closer for faces."
    static let noFaceTitle = "Can’t see your face"
    static let noFaceSubtitle = "Try more light, or just type."
    static let textTitle = "Searching by words"
    /// Also shown when a face token is kept (DESIGN.md): the camera then only feeds the dimmed mirror.
    static let textSubtitle = "The camera waits while you type."
    static let imageTitle = "Searching with your image"
    static let imageSubtitle = "It isn’t saved unless you keep it."
    static let keepAction = "Keep it"
    static let keptAction = "Kept · Undo"
    static let backToFaceAction = "Back to your face"
    /// Under the mirror while the face editor is open: the tiles follow your edit, not the camera.
    static let editingTitle = "Searching your edit"
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
    /// One of GIPHY's stickers (the GIPHY Stickers source): animated, on transparent.
    case giphySticker(WebGIF)
    case template(MemeTemplate)

    var title: String {
        switch self {
        case let .meme(item): return item.displayName
        case let .gif(gif), let .giphySticker(gif): return gif.title
        case let .template(template): return template.name
        }
    }

    /// What ↵ copies, for the bottom bar: "Copy GIF", "Copy Sticker", "Copy Image".
    var copyNoun: String {
        switch self {
        case let .meme(item):
            if item.isSticker { return "Sticker" }
            return item.isAnimated ? "GIF" : "Image"
        case .gif: return "GIF"
        case .giphySticker: return "Sticker"
        case .template: return "Image"
        }
    }

    /// Where it is from, for its tile's small badge: GIPHY, the classic memes, or yours.
    var isFromGiphy: Bool {
        switch self {
        case .gif, .giphySticker: return true
        case .meme, .template: return false
        }
    }
}

/// A titled run of the grid's picks that starts on its own row: My Stickers shows a row per group, then Ungrouped.
struct PickerSection: Equatable {
    /// Over its first row: the group's name, or "Ungrouped".
    let title: String
    /// How many stickers it has in all (the row shows at most a row of them).
    let total: Int
    /// What See all › opens.
    let filter: StickerGroupFilter
    /// Its picks: `picks[range]` of the layout.
    let range: Range<Int>
    /// The row it starts on.
    let firstRow: Int
}

/// What the grid shows for the source and search: every pick in order, `columns` to a row, under one title; or in
/// sections, each starting on its own row (`sections`), so a row can end early and slots no longer line up with picks.
struct PickerLayout: Equatable {
    let picks: [Pick]
    let columns: Int
    /// The rows' tiles for keyboard focus.
    let rows: TileRows
    /// More is on its way (GIPHY's search, Imgflip's list): placeholder tiles follow the picks.
    let isLoading: Bool
    /// What the grid says when it shows nothing ("GIPHY isn’t answering right now.").
    let message: String?
    /// GIPHY's GIFs or stickers are among the picks: its credit shows.
    let showsGiphy: Bool
    /// Over the grid: "Recent", "Matching your face", "Results for “sad”".
    let title: String
    /// Titled runs of picks, each from its own row; empty for one plain run.
    let sections: [PickerSection]
    /// Which pick each slot holds.
    private let slots: SectionedSlots

    init(picks: [Pick], columns: Int, isLoading: Bool, message: String?, title: String) {
        self.init(picks: picks, columns: columns, isLoading: isLoading, message: message, title: title, sections: [])
    }

    /// `sections`: (title, total, filter, picks) in order; their picks follow one another in `picks`.
    init(sectioned: [(title: String, total: Int, filter: StickerGroupFilter, picks: [Pick])], columns: Int,
         message: String?, title: String) {
        let columns = max(1, columns)
        let slots = SectionedSlots(columns: columns, counts: sectioned.map { $0.picks.count })
        var sections: [PickerSection] = []
        var start = 0
        for (index, section) in sectioned.enumerated() {
            let range = start..<(start + section.picks.count)
            start = range.upperBound
            guard !range.isEmpty else { continue }
            sections.append(PickerSection(title: section.title, total: section.total, filter: section.filter,
                                          range: range, firstRow: slots.firstRows[index]))
        }
        self.init(picks: sectioned.flatMap { $0.picks }, columns: columns, isLoading: false, message: message,
                  title: title, sections: sections, slots: slots)
    }

    private init(picks: [Pick], columns: Int, isLoading: Bool, message: String?, title: String,
                 sections: [PickerSection], slots: SectionedSlots? = nil) {
        let columns = max(1, columns)
        self.picks = picks
        self.columns = columns
        let slots = slots ?? SectionedSlots(columns: columns, counts: [picks.count])
        self.slots = slots
        rows = slots.rows
        self.isLoading = isLoading
        self.message = picks.isEmpty && !isLoading ? message : nil
        showsGiphy = picks.contains { $0.isFromGiphy }
        self.title = title
        self.sections = sections
    }

    func pick(at slot: Int) -> Pick? {
        guard let index = slots.pick(at: slot), index < picks.count else { return nil }
        return picks[index]
    }

    /// The slot of the `index`th tile (⌘1–⌘9 count tiles, not slots); nil when there are fewer.
    func slot(ofTile index: Int) -> Int? {
        slots.slot(ofPick: index)
    }

    /// The section that starts on `row`, for its title over the row.
    func section(startingAt row: Int) -> PickerSection? {
        sections.first { $0.firstRow == row }
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

/// What the last pen stroke did in the face editor; `undoable` when it changed something, so Undo sits beside it.
/// Under the grid after Clip me: the sticker it saved to My Stickers and copied, with Rename and Undo.
struct ClipNotice: Equatable {
    let itemID: UUID
    var name: String
    let thumbnail: URL
    let isGIF: Bool
    /// false: the same picture was already one of your stickers (Undo leaves it).
    let isNew: Bool
    var copied = true
    /// The groups offered as chips: the latest used when it was made, then any made from it (New group).
    var chipGroupIDs: [UUID] = []
    /// The groups the sticker is in. A change restarts the notice's 8 s.
    var groupIDs: Set<UUID> = []
}

/// A capture handed to the cutter off the main thread.
private struct ClipWork: @unchecked Sendable {
    let result: CaptureResult
}

/// The words a pose with no word of its own was searched by, kept for the query they were found for so re-showing it
/// (Esc, a library change, back from typing or from the face editor) searches the same words and never asks the model
/// again.
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
    @Published private(set) var mode: PanelMode = .prompt {
        didSet {
            // The editor refines the face the camera caught: leaving the camera's search closes it.
            if mode != .live, faceEdit != nil { endFaceEdit() }
        }
    }
    /// Your things for the source showing, best first (≤ Theme.resultLimit): every kind in All Sources, else the
    /// source's.
    @Published private(set) var results: [RankedResult] = []
    /// Where results come from: All Sources each time the panel opens.
    @Published private(set) var source: PickerSource = .all
    /// The camera searches with your face (⌘F, the button at the bottom left). Off each time the panel opens: it opens
    /// on search.
    @Published private(set) var faceSearchOn = false
    /// The part of your face the search leans on (a click on it in the camera); nil: the automatic weights.
    @Published private(set) var leanRegion: FaceRegion?
    /// The menu over the panel, if one is open.
    @Published private(set) var menu: PanelMenu?
    /// What is typed into the open menu's filter field.
    @Published var menuQuery: String = "" {
        didSet {
            if menuQuery != oldValue, menuSelection != 0 { menuSelection = 0 }
        }
    }
    /// The highlighted row of the open menu (↑ ↓, ↵ runs it).
    @Published private(set) var menuSelection = 0
    /// GIPHY's stickers for `giphyQuery` (the GIPHY Stickers source), in GIPHY's order.
    @Published private(set) var stickerResults: [WebGIF] = []
    @Published private(set) var isStickersLoading = false
    @Published private(set) var stickersUnavailable = false
    /// You have memes of your own (meme or maybe tier): until then the mirror's column offers "Find my memes".
    @Published private(set) var hasMemes: Bool = false
    @Published private(set) var newResultIDs: Set<UUID> = []          // just arrived, for 600 ms
    /// A slot of the grid (`layout`), row by row from 0; -1 for none.
    @Published var focusedIndex: Int = 0
    /// GIPHY's results for `giphyQuery` (the face's mood, or typed words) in GIPHY's order, never ranked or mixed with
    /// your memes: the page the grid shows (`giphySlots` of them).
    @Published private(set) var giphyResults: [WebGIF] = []
    @Published private(set) var giphyQuery: WebQuery? {
        didSet {
            if giphyQuery != oldValue { showGiphyStickers() }
        }
    }
    @Published private(set) var isGiphyLoading: Bool = false
    /// The row's search failed or GIPHY refused it.
    @Published private(set) var giphyUnavailable: Bool = false
    /// Web Discover is on and has a key (checked each time the panel opens).
    @Published private(set) var showsGiphyRow: Bool = false
    /// The classic memes: Imgflip templates picked on the Mac for `templateQuery` (popular ones before a face), up to
    /// `templatePickSize`.
    @Published private(set) var templateResults: [MemeTemplate] = []
    @Published private(set) var templateQuery: WebQuery?
    @Published private(set) var isTemplatesLoading: Bool = false
    /// There is no list of templates: Imgflip didn't answer and none was kept.
    @Published private(set) var templatesUnavailable: Bool = false
    /// Web Discover is on (checked each time the panel opens); no key needed.
    @Published private(set) var showsTemplateRow: Bool = false
    /// The word the camera's search went by (or the edited face's, while the face editor is open), beside the notch
    /// and under the mirror instead of the hint while live; nil when the hint should show (nothing read yet, or the
    /// face a word came from lost).
    @Published private(set) var readout: MoodReadout?
    /// The face editor, open while you edit the face the camera caught; nil otherwise.
    @Published private(set) var faceEdit: FaceEditSession?
    /// How much each part of the face counts in the search showing (the editor's weights, else the automatic ones):
    /// the mirror's glow and its caption. Empty without a face search.
    @Published private(set) var shownWeights: [FaceRegion: Double] = [:]
    /// The word an edit just replaced: beside the notch, struck out before the new one for a moment.
    @Published private(set) var replacedWord: String?
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
    /// Clip me is cutting you out of what the camera caught.
    @Published private(set) var isCutting: Bool = false
    /// The sticker Clip me just made: first in All Sources and My Stickers, marked NEW and selected.
    @Published private(set) var newStickerID: UUID?
    @Published private(set) var clipNotice: ClipNotice?
    /// Your things you saved (the star on a tile; the Favorites source).
    @Published private(set) var savedIDs: Set<UUID> = []
    /// Your sticker groups, in the order they were made (`RecentStore.groups`).
    @Published private(set) var stickerGroups: [StickerGroup] = []
    /// The chip showing over My Stickers: All each time the source is picked.
    @Published private(set) var groupFilter: StickerGroupFilter = .all
    /// What the camera reads in the face being held while the mirror is big ("Brows up", 0...5), strongest first;
    /// empty otherwise.
    @Published private(set) var faceReading: [HeldFaceReading.Cue] = []
    /// The app the panel was opened over ("Messages"), for the Recent row's title.
    @Published private(set) var previousAppName: String?

    let store: LibraryStore
    let camera: CameraController
    let capture: CaptureModel
    let indexer: LibraryIndexer
    let web: WebDiscover
    /// GIPHY's stickers, searched for the same words as its GIFs while the GIPHY Stickers source shows.
    let webStickers: WebDiscover
    let templates: MemeTemplates
    let friends: FriendService
    /// Update checks and the one-click install; disabled when the bundle has no feed URL (local builds, tests).
    let updates: UpdateChecker
    /// Names a clear gesture with no word of its own (`PoseDescription`) with the on-device model, where the Mac has
    /// one; the rule's phrase stands where it doesn't.
    private let poseNamer: any PoseNaming

    var onRequestClose: (() -> Void)?
    /// Opens the screen cut (✂ in the panel; ⌥S from anywhere): the app delegate closes the panel and starts it.
    var onRequestScreenCut: (() -> Void)?

    /// ✂ in the panel: cut a sticker out of what is on screen.
    func requestScreenCut() {
        onRequestScreenCut?()
    }

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
    /// How long the word an edit replaced stays struck out beside the new one.
    private static let replacedWordNanoseconds: UInt64 = 2_000_000_000
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
    /// When face search was turned on: typing right after that stops it instead of keeping the face.
    private var faceOnAt: TimeInterval = 0
    private var stickerQuery: WebQuery?
    private var stickerTask: Task<Void, Never>?
    private var stickerGeneration = 0
    private var liveSince: TimeInterval?
    private var faceMissing = false
    /// When the face came back while "Can't see your face" shows.
    private var faceBackSince: TimeInterval?
    private var userInteracted = false
    private var useCameraDespiteOtherApp = false
    /// Published: the grid's title follows it.
    @Published private var resultSource: ResultSource = .recent
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
    private var clipTask: Task<Void, Never>?
    /// The open whose pick is still being copied (one pick at a time per open).
    private var committingSession: Int?
    private var shownSummaryID: UUID?

    private var textDebounceTask: Task<Void, Never>?
    /// Clears `replacedWord` a moment after an edit changed the word.
    private var replacedWordTask: Task<Void, Never>?
    private var giphyTask: Task<Void, Never>?
    private var giphyGeneration = 0
    private var giphyWordsTask: Task<Void, Never>?
    /// Every GIF GIPHY gave for `giphyQuery`, in its order; the grid shows `giphyPage`'s `giphySlots` of them.
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

    /// Classic memes picked at a time (a page: the same face caught again turns to the next).
    static let templatePickSize = 10

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
        self.webStickers = WebDiscover(
            store: store,
            cacheRoot: webCacheRoot.map { $0.deletingLastPathComponent().appendingPathComponent("WebStickers", isDirectory: true) },
            kind: .stickers
        )
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
            self?.handleClip(result)
        }
        indexer.onLibraryChanged = { [weak self] in
            self?.libraryDidChange()
        }
        indexerObservation = indexer.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the new value is stored: read it on the next main-actor turn. Only
            // the open panel shows the footer (opening it refreshes the footer), so a first scan's thousands of
            // progress ticks don't redraw a hidden panel.
            let model = self
            Task { @MainActor in
                guard let model, model.isPanelVisible else { return }
                model.refreshFooter()
            }
        }
        updatesObservation = updates.objectWillChange.sink { [weak self] _ in
            // Same as the indexer: the new update or phase is readable on the next main-actor turn.
            let model = self
            Task { @MainActor in
                guard let model, model.isPanelVisible else { return }
                model.refreshFooter()
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
            previousAppName = previousApp?.localizedName
        } else {
            previousBundleID = nil
            previousAppName = nil
        }
        let saved = Set(store.recents.saved)
        if savedIDs != saved { savedIDs = saved }
        refreshGroups()
        isPanelVisible = true
        shownAt = CACurrentMediaTime()
        resetForNewSession()
        // The panel opens on search: the camera waits for ⌘F.
        enterCameraMode()
        showRecentResults()
        refreshFooter()
        refreshHint()
    }

    func panelDidHide() {
        isPanelVisible = false
        closeMenu()
        cancelClip()
        cancelSessionTasks()
        camera.stop()
        if holdProgress != 0 { holdProgress = 0 }
        if !faceReading.isEmpty { faceReading = [] }
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

    /// "More like this" looks for memes like the focused one (not like a GIPHY GIF).
    var canMoreLikeFocused: Bool {
        if case .meme? = focusedPick { return true }
        return false
    }

    /// What the grid shows for the source and search.
    var layout: PickerLayout {
        makeLayout()
    }

    /// Shows `newSource`: your things for it, ranked again for the search showing, or the web's; the focus goes to its
    /// first tile.
    func selectSource(_ newSource: PickerSource) {
        guard source != newSource else { return }
        source = newSource
        if groupFilter != .all { groupFilter = .all }
        userInteracted = false
        refreshCurrentResults()
        if newSource.showsGiphyGIFs, giphyQuery == nil {
            showGiphy(for: .trending)
        }
        showGiphyStickers()
        normalizeFocus()
    }

    /// Tab and Shift-Tab: the next or the previous source, wrapping around.
    func cycleSource(by offset: Int) {
        selectSource(source.cycled(by: offset))
    }

    /// The bottom bar's main action: "Copy GIF", "Copy Sticker", "Copy Image".
    var copyLabel: String {
        "Copy " + (focusedPick?.copyNoun ?? "")
    }

    // MARK: - Face search

    /// The camera's column shows beside the grid: face search is on, or an image is being searched with.
    var showsFaceColumn: Bool {
        faceSearchOn || mode == .image || mode == .moreLike
    }

    /// ⌘F and the button at the bottom left: the camera turns on and your face becomes the search (camera access is
    /// asked for the first time), or it turns off and the panel goes back to search.
    func toggleFaceSearch() {
        setFaceSearch(!faceSearchOn)
    }

    func setFaceSearch(_ on: Bool) {
        guard on != faceSearchOn else { return }
        closeMenu()
        if on {
            faceSearchOn = true
            faceOnAt = CACurrentMediaTime()
            clearTextState()
            resetQueryImage()
            tracker.reset()
            earlyMood.reset()
            enterCameraMode()
            if camera.authorization == .notDetermined && requestsCameraAccessOnShow {
                scheduleCameraAccessRequest(after: 0)
            }
            showRecentResults()
        } else {
            faceSearchOn = false
            if leanRegion != nil { leanRegion = nil }
            cancelClip()
            endFaceEdit()
            tracker.reset()
            earlyMood.reset()
            cancelDescribing()
            if holdProgress != 0 { holdProgress = 0 }
            if !faceReading.isEmpty { faceReading = [] }
            if showsFaceToken { showsFaceToken = false }
            faceTokenSample = nil
            if mode == .text {
                camera.stop()
                runTextSearch()
            } else {
                enterCameraMode()
                // GIPHY and the classic memes go back to what the panel opened with.
                showGiphy(for: .trending)
                showTemplates(for: .trending)
                showRecentResults()
            }
        }
        refreshHint()
    }

    /// The grid shows what your face found (not your recent picks, words or an image): its parts can be leaned on.
    var showsFaceResults: Bool {
        resultSource == .expression
    }

    /// A click on your brows, eyes or mouth (in the camera, or on its meter): the search leans on that part, so it
    /// counts most and the search's word is read from it. The same part again goes back to the whole face.
    func leanOn(_ region: FaceRegion) {
        guard faceSearchOn else { return }
        leanRegion = leanRegion == region ? nil : region
        if resultSource == .expression && faceEdit == nil {
            runExpressionSearch(animate: false)
        }
        refreshHint()
    }

    // MARK: - Menus

    /// ⌘P and the source button: the source menu; ⌘K and Actions: what can be done with the selected result. The
    /// same menu again closes it.
    func toggleMenu(_ which: PanelMenu) {
        if menu == which {
            closeMenu()
            return
        }
        if which == .actions && focusedPick == nil { return }
        menuQuery = ""
        menuSelection = which == .sources ? max(0, sourceRows.firstIndex { $0.isChecked } ?? 0) : 0
        menu = which
    }

    func closeMenu() {
        guard menu != nil else { return }
        menu = nil
        menuQuery = ""
        menuSelection = 0
    }

    /// The open menu's rows, filtered by what is typed into it.
    var menuRows: [MenuRow] {
        let rows: [MenuRow]
        switch menu {
        case .sources?: rows = sourceRows
        case .actions?: rows = actionRows
        case nil: return []
        }
        let query = menuQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return rows }
        return rows.filter { $0.title.lowercased().contains(query) }.map { row in
            MenuRow(id: row.id, title: row.title, symbol: row.symbol, letter: row.letter, keys: row.keys,
                    isChecked: row.isChecked, startsGroup: false)
        }
    }

    /// ↑ ↓ in an open menu.
    func moveMenuSelection(by offset: Int) {
        let count = menuRows.count
        guard count > 0 else { return }
        let next = min(max(0, menuSelection + offset), count - 1)
        if next != menuSelection { menuSelection = next }
    }

    func hoverMenuRow(_ index: Int) {
        guard index >= 0, index < menuRows.count, index != menuSelection else { return }
        menuSelection = index
    }

    /// ↵ in an open menu, or a click on a row.
    func performMenuRow(at index: Int? = nil) {
        let rows = menuRows
        let chosen = index ?? menuSelection
        guard chosen >= 0, chosen < rows.count, let which = menu else { return }
        let id = rows[chosen].id
        let focusedSticker: UUID? = {
            if case let .meme(item)? = focusedPick { return item.id }
            return nil
        }()
        closeMenu()
        switch which {
        case .sources:
            if let picked = PickerSource(rawValue: id) { selectSource(picked) }
        case .actions:
            if let action = PickAction(rawValue: id) {
                perform(action)
            } else if let stickerID = focusedSticker {
                if id == AppModel.newGroupRowID {
                    newGroup(filing: stickerID)
                } else if id.hasPrefix(AppModel.groupRowPrefix),
                          let groupID = UUID(uuidString: String(id.dropFirst(AppModel.groupRowPrefix.count))) {
                    toggleGroup(groupID, forSticker: stickerID)
                }
            }
        }
    }

    private var sourceRows: [MenuRow] {
        var previousGroup: Int?
        return PickerSource.allCases.map { item in
            let starts = previousGroup.map { $0 != item.group } ?? false
            previousGroup = item.group
            let letter: String?
            switch item {
            case .giphyGIFs, .giphyStickers: letter = "G"
            default: letter = nil
            }
            return MenuRow(id: item.rawValue, title: item.title, symbol: letter == nil ? AppModel.symbol(for: item) : nil,
                           letter: letter, keys: [], isChecked: item == source, startsGroup: starts)
        }
    }

    /// The SF Symbol beside a source in the menu and on its button.
    static func symbol(for source: PickerSource) -> String {
        switch source {
        case .all: return "square.grid.2x2"
        case .favorites: return "star"
        case .onMyMac: return "laptopcomputer"
        case .myStickers: return "face.smiling"
        case .giphyGIFs, .giphyStickers: return "play.rectangle"
        case .classicMemes: return "text.below.photo"
        }
    }

    /// The actions for the selected result, in groups: copying it; keeping it or finding more; where it lives.
    var actions: [[PickAction]] {
        guard let pick = focusedPick else { return [] }
        switch pick {
        case .meme:
            var keep: [PickAction] = []
            if canSave(pick) { keep.append(.toggleFavorite) }
            keep.append(.moreLikeThis)
            var groups: [[PickAction]] = [[.copy], keep, [.showInFinder]]
            if canDeleteSticker(pick) { groups.append([.deleteSticker]) }
            return groups
        case .gif, .giphySticker, .template:
            return [[.copy, .copyLink, .copyMarkdown], [.openInBrowser]]
        }
    }

    private var actionRows: [MenuRow] {
        guard let pick = focusedPick else { return [] }
        var rows: [MenuRow] = []
        for (groupIndex, group) in actions.enumerated() {
            for (index, action) in group.enumerated() {
                rows.append(MenuRow(id: action.rawValue, title: title(of: action, for: pick),
                                    symbol: AppModel.symbol(for: action, saved: isSaved(pick)), letter: nil,
                                    keys: AppModel.keys(for: action), isChecked: false,
                                    startsGroup: groupIndex > 0 && index == 0))
            }
            // A sticker of yours: its groups, after keeping it and finding more.
            if groupIndex == 1, canGroup(pick), case let .meme(item) = pick {
                rows += groupRows(for: item.id)
            }
        }
        return rows
    }

    static let groupRowPrefix = "group:"
    static let newGroupRowID = "newGroup"

    /// ⌘K's Groups section: each group, checked when the sticker is in it, then New Group….
    private func groupRows(for stickerID: UUID) -> [MenuRow] {
        var rows: [MenuRow] = []
        for group in filableGroups {
            let first = rows.isEmpty
            rows.append(MenuRow(id: AppModel.groupRowPrefix + group.id.uuidString, title: group.name,
                                symbol: "square.stack", letter: nil, keys: [], isChecked: group.contains(stickerID),
                                startsGroup: first, heading: first ? "Groups" : nil))
        }
        let first = rows.isEmpty
        rows.append(MenuRow(id: AppModel.newGroupRowID, title: "New Group…", symbol: "plus", letter: nil, keys: [],
                            isChecked: false, startsGroup: first, heading: first ? "Groups" : nil))
        return rows
    }

    private func title(of action: PickAction, for pick: Pick) -> String {
        switch action {
        case .copy: return "Copy " + pick.copyNoun
        case .copyLink: return "Copy Link"
        case .copyMarkdown: return "Copy Markdown"
        case .toggleFavorite: return isSaved(pick) ? "Remove from Favorites" : "Add to Favorites"
        case .moreLikeThis: return "More Like This"
        case .showInFinder: return "Show in Finder"
        case .openInBrowser: return pick.isFromGiphy ? "Open on GIPHY" : "Open in Browser"
        case .deleteSticker: return "Delete Sticker…"
        }
    }

    static func symbol(for action: PickAction, saved: Bool) -> String {
        switch action {
        case .copy: return "doc.on.doc"
        case .copyLink: return "link"
        case .copyMarkdown: return "chevron.left.forwardslash.chevron.right"
        case .toggleFavorite: return saved ? "star.slash" : "star"
        case .moreLikeThis: return "sparkles"
        case .showInFinder: return "folder"
        case .openInBrowser: return "globe"
        case .deleteSticker: return "trash"
        }
    }

    /// The shortcut each action has while no menu is open (the panel controller routes them).
    static func keys(for action: PickAction) -> [String] {
        switch action {
        case .copy: return ["↩"]
        case .copyLink: return ["⇧", "⌘", "C"]
        case .copyMarkdown: return ["⌥", "⌘", "C"]
        case .toggleFavorite: return ["⌘", "S"]
        case .moreLikeThis: return ["⌘", "M"]
        case .showInFinder: return ["⇧", "⌘", "R"]
        case .openInBrowser: return ["⌘", "O"]
        case .deleteSticker: return ["⌘", "⌫"]
        }
    }

    /// Runs `action` on the selected result; one it doesn't offer does nothing.
    func perform(_ action: PickAction) {
        guard let pick = focusedPick, actions.joined().contains(action) else { return }
        switch action {
        case .copy:
            commit(index: focusedIndex)
        case .copyLink:
            guard let link = AppModel.link(for: pick) else { return }
            copyText(link.absoluteString, notice: "Copied the link · ⌘V")
        case .copyMarkdown:
            guard let markdown = AppModel.markdown(for: pick) else { return }
            copyText(markdown, notice: "Copied as Markdown · ⌘V")
        case .toggleFavorite:
            toggleSaved(pick)
        case .moreLikeThis:
            moreLikeFocused()
        case .showInFinder:
            guard case let .meme(item) = pick else { return }
            onRequestClose?()
            NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
        case .openInBrowser:
            guard let link = AppModel.link(for: pick) else { return }
            onRequestClose?()
            NSWorkspace.shared.open(link)
        case .deleteSticker:
            deleteSticker(pick)
        }
    }

    /// The page a web result lives on (GIPHY's page, else the file), for Copy Link and Open in Browser.
    static func link(for pick: Pick) -> URL? {
        switch pick {
        case let .gif(gif), let .giphySticker(gif): return gif.pageURL ?? gif.fullURL
        case let .template(template): return template.url
        case .meme: return nil
        }
    }

    /// `![title](media)`: the image itself, so a Markdown editor shows it.
    static func markdown(for pick: Pick) -> String? {
        let media: URL
        switch pick {
        case let .gif(gif), let .giphySticker(gif): media = gif.fullURL
        case let .template(template): media = template.url
        case .meme: return nil
        }
        let title = pick.title.replacingOccurrences(of: "]", with: "").replacingOccurrences(of: "[", with: "")
        return "![\(title)](\(media.absoluteString))"
    }

    /// Puts `text` on the clipboard, closes the panel and says so.
    private func copyText(_ text: String, notice: String) {
        commitToken += 1
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if isPanelVisible { onRequestClose?() }
        HUDController.shared.show(notice)
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

    /// Number keys pick any tile, 1–9 in order, row by row (skipping the gaps where a section's row ends early).
    func commitNumbered(index: Int) {
        guard index >= 0, index < 9, let slot = makeLayout().slot(ofTile: index) else { return }
        commit(index: slot)
    }

    func moveFocus(dx: Int, dy: Int) {
        userInteracted = true
        guard let target = makeLayout().rows.move(from: focusedIndex, dx: dx, dy: dy) else { return }
        focusedIndex = target
        prefetchFocused()
    }

    func hover(index: Int) {
        guard makeLayout().rows.isFilled(index) else { return }
        userInteracted = true
        if focusedIndex != index {
            focusedIndex = index
            prefetchFocused()
        }
    }

    /// Esc: the first press clears refinements (the face editor, text, more-like-this, image query); returns false when
    /// there were none.
    /// A clip being recorded is dropped first; the Clip me notice goes next.
    func handleEscape() -> Bool {
        if menu != nil {
            closeMenu()
            return true
        }
        if capture.isBusy {
            capture.cancel()
            return true
        }
        if clipNotice != nil {
            clipNotice = nil
            return true
        }
        // The You're-set card closes with the panel.
        if showSetupCard { return false }
        if faceEdit != nil {
            closeFaceEditor()
            return true
        }
        let hadText = !queryText.isEmpty || mode == .text || naming != nil
        let hadQueryImage = mode == .image || mode == .moreLike
        guard hadText || hadQueryImage else {
            // Then face search turns off; with nothing else on, Esc closes the panel.
            guard faceSearchOn else { return false }
            setFaceSearch(false)
            return true
        }
        clearTextState()
        returnToFace()
        return true
    }

    /// Space with an empty search field: the current face (or a gesture hiding it) becomes the query, even a neutral one.
    func snap() {
        // While you edit, the camera's face waits: Space does nothing until you go back to it.
        guard mode == .live, !showSetupCard, faceEdit == nil, tracker.snap() else { return }
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
        if faceEdit != nil {
            closeFaceEditor()
            return
        }
        guard mode == .moreLike || mode == .image || mode == .text else { return }
        clearTextState()
        returnToFace()
    }

    // MARK: - Making a face

    /// Tiles per row: 4 beside the camera's column, else 5.
    var gridColumns: Int {
        showsFaceColumn ? Theme.faceColumns : Theme.columns
    }

    /// A face is being held toward the first search: the camera's glow shows what it reads.
    var isReadingFace: Bool {
        faceSearchOn && resultSource == .recent && faceEdit == nil && mode == .live && holdProgress >= 0.05
    }

    /// The mirror's glow: what counts in the face search showing, else what is read in the face being held.
    var mirrorWeights: [FaceRegion: Double] {
        if !shownWeights.isEmpty { return shownWeights }
        return isReadingFace ? HeldFaceReading.glow(of: faceReading) : [:]
    }

    /// What the search field says while empty: it always invites typing.
    var searchPlaceholder: String {
        if readout != nil { return "Add words to refine…" }
        switch mode {
        case .live, .warming: return "Make a face, or type to search…"
        default: return "Search GIFs, stickers and memes…"
        }
    }

    /// The × on the word in the search field: the camera caught a face, and nothing else covers it.
    var canDismissCaughtFace: Bool {
        mode == .live && resultSource == .expression && faceEdit == nil && tracker.query != nil
    }

    /// The × on the word in the search field: not this face. The panel goes back to your recent and frequent picks
    /// with the big mirror, and the next face you hold is searched as before.
    func dismissCaughtFace() {
        guard canDismissCaughtFace else { return }
        tracker.reset()
        earlyMood.reset()
        cancelDescribing()
        clearReplacedWord()
        if holdProgress != 0 { holdProgress = 0 }
        clearGiphyRow()
        showTemplates(for: .trending)
        showRecentResults()
        refreshHint()
    }

    /// The live face's cues while it is held toward the first search (`isReadingFace`).
    private func updateFaceReading(with sample: ExpressionSample) {
        var cues: [HeldFaceReading.Cue] = []
        if isReadingFace, let face = sample.face {
            cues = HeldFaceReading.cues(face: face, shape: sample.shape, baseline: tracker.baseline)
        }
        if faceReading != cues { faceReading = cues }
    }

    // MARK: - Saved

    /// Only your own things are kept: GIPHY's GIFs and the classic memes aren't saved.
    func canSave(_ pick: Pick) -> Bool {
        guard case let .meme(item) = pick else { return false }
        return item.kind != .web && store.item(id: item.id) != nil
    }

    func isSaved(_ pick: Pick) -> Bool {
        guard case let .meme(item) = pick else { return false }
        return savedIDs.contains(item.id)
    }

    /// The star on a tile (and ⌘S on the focused one): saves it to Favorites, or takes it out.
    func toggleSaved(_ pick: Pick) {
        guard canSave(pick), case let .meme(item) = pick else { return }
        var recents = store.recents
        recents.toggleSaved(item.id)
        store.recents = recents
        savedIDs = Set(recents.saved)
        saveSoon()
        if source == .favorites {
            refreshCurrentResults()
        }
    }

    func toggleSaveFocused() {
        guard let pick = focusedPick else { return }
        toggleSaved(pick)
    }

    // MARK: - Sticker groups

    /// Groups the Clip me notice offers as chips: the latest used.
    static let noticeGroupLimit = 3

    private func refreshGroups() {
        let groups = store.recents.groups
        if stickerGroups != groups { stickerGroups = groups }
        if case let .group(id) = groupFilter, !groups.contains(where: { $0.id == id }) {
            groupFilter = .all
        }
    }

    /// Changes the groups, keeps them and shows the change.
    private func updateGroups(_ change: (inout RecentStore) -> Void) {
        var recents = store.recents
        change(&recents)
        guard recents != store.recents else { return }
        store.recents = recents
        refreshGroups()
        saveSoon()
    }

    /// Your own stickers can be put in groups; GIPHY's can't.
    func canGroup(_ pick: Pick) -> Bool {
        canDeleteSticker(pick)
    }

    /// Your stickers that still exist, by id.
    private var stickersByID: [UUID: LibraryItem] {
        var byID: [UUID: LibraryItem] = [:]
        for item in store.items where item.isSticker && item.kind != .web {
            byID[item.id] = item
        }
        return byID
    }

    /// Groups you file stickers in (⌘K, the right-click menu): not live ones, whose words pick their stickers.
    var filableGroups: [StickerGroup] {
        stickerGroups.filter { !$0.isLive }
    }

    /// Each group's stickers that still exist, the latest filed first (a live group's: what its words match, newest
    /// first), by group.
    private func groupMembers() -> [UUID: [UUID]] {
        var members: [UUID: [UUID]] = [:]
        let items = store.items
        let people = store.people
        for group in stickerGroups {
            members[group.id] = group.members(in: items, people: people)
        }
        return members
    }

    /// My Stickers' chips: All, each group with its count, Ungrouped (once there are groups).
    var groupChips: [GroupChip] {
        let stickers = stickersByID
        var chips = [GroupChip(filter: .all, title: "All", count: nil)]
        guard !stickerGroups.isEmpty else { return chips }
        let membersByGroup = groupMembers()
        var grouped = Set<UUID>()
        for group in stickerGroups {
            let members = membersByGroup[group.id] ?? []
            grouped.formUnion(members)
            chips.append(GroupChip(filter: .group(group.id), title: group.name, count: members.count, isLive: group.isLive))
        }
        let ungrouped = stickers.keys.filter { !grouped.contains($0) }.count
        chips.append(GroupChip(filter: .ungrouped, title: "Ungrouped", count: ungrouped))
        return chips
    }

    /// A chip over My Stickers (or See all › on a row): its stickers, searched again for what is typed.
    func selectGroupFilter(_ filter: StickerGroupFilter) {
        guard source == .myStickers, filter != groupFilter else { return }
        closeMenu()
        groupFilter = filter
        userInteracted = false
        refreshCurrentResults()
        normalizeFocus()
    }

    /// My Stickers on All with nothing searched, once there are groups: a row per group (its latest filed first), then
    /// Ungrouped (newest first), each from its own row. nil otherwise: the ranked grid as before.
    private func groupedStickersLayout(columns: Int) -> PickerLayout? {
        guard source == .myStickers, groupFilter == .all, resultSource == .recent, !stickerGroups.isEmpty else {
            return nil
        }
        let stickers = stickersByID
        let membersByGroup = groupMembers()
        var sections: [(title: String, total: Int, filter: StickerGroupFilter, picks: [Pick])] = []
        var grouped = Set<UUID>()
        for group in stickerGroups {
            let members = (membersByGroup[group.id] ?? []).compactMap { stickers[$0] }
            grouped.formUnion(members.map(\.id))
            guard !members.isEmpty else { continue }
            sections.append((title: group.name, total: members.count, filter: StickerGroupFilter.group(group.id),
                             picks: members.prefix(columns).map { Pick.meme($0) }))
        }
        let ungrouped = stickers.values.filter { !grouped.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
                return lhs.displayName < rhs.displayName
            }
        if !ungrouped.isEmpty {
            sections.append((title: "Ungrouped", total: ungrouped.count, filter: StickerGroupFilter.ungrouped,
                             picks: ungrouped.prefix(columns).map { Pick.meme($0) }))
        }
        return PickerLayout(sectioned: sections, columns: columns, message: stickersEmptyMessage, title: "")
    }

    /// Over the grid while a chip other than All shows: its name.
    private var groupFilterTitle: String? {
        switch groupFilter {
        case .all: return nil
        case let .group(id): return stickerGroups.first { $0.id == id }?.name
        case .ungrouped: return "Ungrouped"
        }
    }

    /// Files the sticker in the group, or takes it out (⌘K's Groups, the Clip me notice's chips).
    func toggleGroup(_ groupID: UUID, forSticker stickerID: UUID) {
        guard let item = store.item(id: stickerID), item.isSticker, item.kind != .web,
              stickerGroups.contains(where: { $0.id == groupID && !$0.isLive }) else { return }
        updateGroups { $0.toggleSticker(stickerID, inGroup: groupID) }
        noteGroupsChanged(forSticker: stickerID)
    }

    /// The notice's chips and the grid follow a sticker's groups; the focus stays on it.
    private func noteGroupsChanged(forSticker stickerID: UUID) {
        if var notice = clipNotice, notice.itemID == stickerID {
            notice.groupIDs = Set(store.recents.groups(containing: stickerID).map(\.id))
            clipNotice = notice
        }
        guard source == .myStickers else { return }
        refreshCurrentResults()
        focus(onItem: stickerID)
    }

    /// Moves the focus to the tile showing `id`, if one does.
    private func focus(onItem id: UUID) {
        let layout = makeLayout()
        for slot in 0..<layout.rows.slotCount {
            if case let .meme(item)? = layout.pick(at: slot), item.id == id {
                userInteracted = true
                if focusedIndex != slot { focusedIndex = slot }
                return
            }
        }
    }

    /// The chips on the Clip me notice: its groups that still exist, in the order offered.
    var noticeGroups: [StickerGroup] {
        guard let notice = clipNotice else { return [] }
        return notice.chipGroupIDs.compactMap { id in stickerGroups.first { $0.id == id } }
    }

    /// A chip on the Clip me notice: files the sticker just made in that group, or takes it out.
    func toggleNoticeGroup(_ groupID: UUID) {
        guard let notice = clipNotice else { return }
        toggleGroup(groupID, forSticker: notice.itemID)
    }

    /// New group on the Clip me notice: names a group and files the sticker in it; the chip joins the others.
    func newGroupFromNotice() {
        guard let notice = clipNotice, let group = newGroup(filing: notice.itemID) else { return }
        guard var current = clipNotice, current.itemID == notice.itemID else { return }
        if !current.chipGroupIDs.contains(group.id) { current.chipGroupIDs.append(group.id) }
        current.groupIDs = Set(store.recents.groups(containing: notice.itemID).map(\.id))
        clipNotice = current
    }

    /// New Group… (⌘K, the + chip, the notice): asks for a name and makes the group (a name already taken is that
    /// group), filing `stickerID` in it. Made from the + chip, its chip shows. Returns the group.
    @discardableResult
    func newGroup(filing stickerID: UUID? = nil) -> StickerGroup? {
        closeMenu()
        guard let name = askGroupName(title: "New Group", button: "Create") else { return nil }
        var created: StickerGroup?
        updateGroups { recents in
            created = recents.addGroup(named: name)
            if let group = created, let stickerID { recents.setSticker(stickerID, inGroup: group.id, true) }
        }
        guard let made = created else { return nil }
        if let stickerID {
            noteGroupsChanged(forSticker: stickerID)
        } else if source == .myStickers {
            selectGroupFilter(.group(made.id))
        }
        return made
    }

    /// Rename… on a group's chip.
    func renameGroup(_ id: UUID) {
        guard let group = stickerGroups.first(where: { $0.id == id }),
              let name = askGroupName(title: "Rename Group", button: "Rename", initial: group.name),
              name != group.name else { return }
        var renamed = false
        updateGroups { renamed = $0.renameGroup(id, to: name) }
        if !renamed {
            HUDController.shared.show("There’s already a group named “\(StickerGroup.cleanName(name) ?? name)”.")
        }
    }

    /// Delete Group on a group's chip: the group goes (its stickers stay), with Undo.
    func deleteGroup(_ id: UUID) {
        var taken: (group: StickerGroup, index: Int)?
        updateGroups { taken = $0.removeGroup(id) }
        guard let removed = taken else { return }
        if source == .myStickers { refreshCurrentResults() }
        let undo = HUDAction(title: "Undo") { [weak self] in
            guard let self else { return }
            let existing = Set(self.stickersByID.keys)
            self.updateGroups { $0.restoreGroup(removed.group, at: removed.index, keeping: existing) }
            if self.source == .myStickers { self.refreshCurrentResults() }
        }
        HUDController.shared.show("Deleted “\(removed.group.name)” · its stickers stay", action: undo)
    }

    /// The screen cut's Save: files the sticker in the ticked groups and in new ones named on the card. Returns the
    /// names of the groups it is now in, for the notice.
    @discardableResult
    func fileSticker(_ stickerID: UUID, inGroups groupIDs: Set<UUID>, newGroupNames: [String]) -> [String] {
        guard store.item(id: stickerID) != nil, !groupIDs.isEmpty || !newGroupNames.isEmpty else { return [] }
        updateGroups { recents in
            for name in newGroupNames {
                if let made = recents.addGroup(named: name) { recents.setSticker(stickerID, inGroup: made.id, true) }
            }
            for id in groupIDs {
                recents.setSticker(stickerID, inGroup: id, true)
            }
        }
        if isPanelVisible, source == .myStickers { refreshCurrentResults() }
        return store.recents.groups(containing: stickerID).map(\.name)
    }

    // MARK: Suggested groups

    /// Groups MemeMe offers over My Stickers' All, with nothing searched: the same named friend, the word your face
    /// was read as, the app a screen cut came from (`GroupSuggestion`). At most three.
    var groupSuggestions: [GroupSuggestion] {
        guard source == .myStickers, groupFilter == .all, resultSource == .recent else { return [] }
        let items = store.items
        let people = store.people
        let groups = stickerGroups.map { (name: $0.name, members: Set($0.members(in: items, people: people))) }
        return GroupSuggestion.suggest(items: items, people: people, groups: groups,
                                       dismissed: store.recents.dismissedSuggestions)
    }

    /// Make group on a suggestion: the group, named as offered, with all its stickers (the newest first).
    func acceptSuggestion(_ suggestion: GroupSuggestion) {
        var created: StickerGroup?
        updateGroups { recents in
            guard let group = recents.addGroup(named: suggestion.name) else { return }
            created = group
            for id in suggestion.stickerIDs.reversed() {
                recents.setSticker(id, inGroup: group.id, true)
            }
        }
        guard let made = created else { return }
        if source == .myStickers { refreshCurrentResults() }
        HUDController.shared.show("Made “\(made.name)” with \(suggestion.stickerIDs.count) stickers")
    }

    /// Not now on a suggestion: it isn't offered again until it has more stickers.
    func dismissSuggestion(_ suggestion: GroupSuggestion) {
        // Only the turned-down list changes, which nothing published follows: the grid redraws on this.
        objectWillChange.send()
        updateGroups { $0.dismissSuggestion(suggestion.key, count: suggestion.stickerIDs.count) }
    }

    // MARK: Live groups

    /// The words searched in My Stickers (All), which Save as Group keeps as a group that fills itself.
    var savableSearch: String? {
        guard source == .myStickers, groupFilter == .all, resultSource == .text else { return nil }
        let words = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
    }

    /// Save as Group: asks for a name ("Cat" for "cat"), keeps the search as a live group holding every sticker the
    /// words match, now and later, and shows its chip.
    func saveSearchAsGroup() {
        guard let words = savableSearch else { return }
        let suggested = words.prefix(1).uppercased() + words.dropFirst()
        guard let name = askGroupName(title: "Save as Group", button: "Save Group", initial: suggested,
                                      message: "It holds every sticker matching “\(words)”: those you have now and the ones you make later.")
        else { return }
        var created: StickerGroup?
        updateGroups { created = $0.addLiveGroup(named: name, query: words) }
        guard let made = created else { return }
        clearTextState()
        returnToFace()
        selectGroupFilter(.group(made.id))
    }

    /// A group's name, asked for in a small sheet; nil when cancelled or left empty.
    private func askGroupName(title: String, button: String, initial: String = "", message: String? = nil) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        if let message { alert.informativeText = message }
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.placeholderString = "Reactions, Work, Sam & Jo…"
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard AppModel.runInFront(alert) == .alertFirstButtonReturn else { return nil }
        return StickerGroup.cleanName(field.stringValue)
    }

    // MARK: - Deleting stickers

    /// Stickers in your collection (clipped, cut from the screen, made from photos) can be deleted; GIPHY's can't.
    func canDeleteSticker(_ pick: Pick) -> Bool {
        guard case let .meme(item) = pick, item.isSticker, item.kind != .web else { return false }
        return store.item(id: item.id) != nil
    }

    /// Delete on a tile's menu (and ⌘⌫ on the focused one): asks first, then removes the sticker and its file.
    func deleteSticker(_ pick: Pick) {
        guard canDeleteSticker(pick), case let .meme(item) = pick else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(item.displayName)”?"
        alert.informativeText = "It's removed from My Stickers and its file is deleted. This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard AppModel.runInFront(alert) == .alertFirstButtonReturn else { return }
        removeSticker(id: item.id)
    }

    /// Runs `alert` above the panel, which floats over the menu bar: at its normal level it would open behind it.
    static func runInFront(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        alert.window.level = level
        // runModal may set its own level as it shows the window; raise it again once it is up.
        RunLoop.main.perform(inModes: [.modalPanel, .default]) {
            MainActor.assumeIsolated {
                alert.window.level = level
                alert.window.orderFrontRegardless()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    /// Deletes the sticker without asking (`deleteSticker` asks); the grid drops its tile.
    func removeSticker(id: UUID) {
        guard let item = store.item(id: id), item.isSticker, item.kind != .web else { return }
        friends.deleteSticker(id: id)
        if clipNotice?.itemID == id { clipNotice = nil }
        if newStickerID == id { newStickerID = nil }
        savedIDs = Set(store.recents.saved)
        refreshGroups()
        refreshFooter()
        refreshCurrentResults()
    }

    func deleteFocusedSticker() -> Bool {
        guard let pick = focusedPick, canDeleteSticker(pick) else { return false }
        deleteSticker(pick)
        return true
    }

    // MARK: - Face editor

    /// The face editor can open: the camera's search shows a face (not a pose alone) and nothing covers it.
    var canEditFace: Bool {
        mode == .live && !capture.isBusy && !showSetupCard && faceEdit == nil && !shownWeights.isEmpty
    }

    /// "mostly your brows", "your whole face"…: what counts in the face search showing; nil without one.
    var weightSummary: String? {
        shownWeights.isEmpty ? nil : FeatureWeights.summary(of: shownWeights)
    }

    /// Opens the face editor on the face the camera caught (the button on the mirror, a click on it, ⌘E). The camera
    /// keeps showing you but stops searching until you go back to your face.
    func openFaceEditor() {
        guard canEditFace, let query = tracker.query,
              let session = FaceEditSession(query: query, baseline: tracker.baseline) else { return }
        faceEdit = session
        clearReplacedWord()
        tracker.clearHold()
        if holdProgress != 0 { holdProgress = 0 }
        earlyMood.reset()
        runExpressionSearch(animate: false)
        refreshHint()
    }

    /// ⌘E: opens the editor, or goes back to your face when it is open.
    func toggleFaceEditor() {
        if faceEdit != nil {
            closeFaceEditor()
        } else {
            openFaceEditor()
        }
    }

    /// "Back to your face" (or Esc): the edits go, the face the camera caught is searched again, and the camera's next
    /// face replaces it as before.
    func closeFaceEditor() {
        guard faceEdit != nil else { return }
        endFaceEdit()
        if mode == .live, tracker.query != nil {
            runExpressionSearch(animate: false)
        }
        refreshHint()
    }

    /// Takes hold of a handle on the editor's face.
    func beginFaceDrag(_ handle: FaceHandle) {
        guard var edit = faceEdit else { return }
        edit.beginDrag(handle)
        faceEdit = edit
    }

    /// The pointer moved `movement` since the drag began and is at `pointer` (the drawing's space, 200 × 200). Your
    /// memes re-rank at once; the web rows wait until you let go (`endFaceDrag`), so GIPHY's hourly limit lasts.
    func dragFace(by movement: SketchPoint, pointer: SketchPoint) {
        guard var edit = faceEdit, edit.draggedHandle != nil else { return }
        edit.drag(by: movement, pointer: pointer)
        guard edit != faceEdit else { return }
        faceEdit = edit
        runExpressionSearch(animate: false, settled: false)
        refreshHint()
    }

    /// A pinch on a part whose ring is held (`beginFaceDrag(.ring(_:))`).
    func pinchFace(by magnification: Double) {
        guard var edit = faceEdit, edit.draggedHandle != nil else { return }
        edit.pinch(by: magnification)
        guard edit != faceEdit else { return }
        faceEdit = edit
        runExpressionSearch(animate: false, settled: false)
        refreshHint()
    }

    /// Lets go: the web rows follow the word the face settled on.
    func endFaceDrag() {
        guard var edit = faceEdit, edit.draggedHandle != nil else { return }
        edit.endDrag()
        faceEdit = edit
        runExpressionSearch(animate: false)
        refreshHint()
    }

    /// − and + beside a part.
    func stepFaceWeight(_ region: FaceRegion, by delta: Int) {
        guard var edit = faceEdit else { return }
        edit.step(region, by: delta)
        guard edit != faceEdit else { return }
        faceEdit = edit
        runExpressionSearch(animate: false)
        refreshHint()
    }

    /// ⌘Z, or Undo in the editor.
    func undoFaceEdit() {
        guard var edit = faceEdit, edit.undo() else { return }
        faceEdit = edit
        runExpressionSearch(animate: false)
        refreshHint()
    }

    /// Reset: back to the face as it was caught (Undo brings the edits back).
    func resetFaceEdit() {
        guard var edit = faceEdit else { return }
        edit.reset()
        guard edit != faceEdit else { return }
        faceEdit = edit
        runExpressionSearch(animate: false)
        refreshHint()
    }

    /// Closes the editor without searching again (the panel closes, the mode changes, the capture view opens).
    private func endFaceEdit() {
        if faceEdit != nil { faceEdit = nil }
        clearReplacedWord()
    }

    /// An edit changed the word: the old one shows struck out beside the new one for a moment.
    private func noteReplacedWord(_ word: String) {
        replacedWord = word
        replacedWordTask?.cancel()
        replacedWordTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: AppModel.replacedWordNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.replacedWord = nil
        }
    }

    private func clearReplacedWord() {
        replacedWordTask?.cancel()
        replacedWordTask = nil
        if replacedWord != nil { replacedWord = nil }
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
            return giphyDragProvider(for: gif, from: web)
        case let .giphySticker(gif)?:
            return giphyDragProvider(for: gif, from: webStickers)
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
        return AppModel.runInFront(alert) == .alertFirstButtonReturn
    }

    // MARK: - App-shell helpers (used by the status item and the app delegate)

    /// Persists the store about 2 s after the last change, encoding and writing it off the main thread.
    func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: AppModel.saveDelayNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            self.persistBaseline()
            self.store.saveInBackground { error in
                modelLog.error("Saving the library failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Persists the resting face and the store right away (quit). Also waits for any save still being written in
    /// the background, so nothing is lost when the app exits.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        persistBaseline()
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

    // MARK: - Clip me

    /// Clip me (the ✂ island, ⌥S, ⇧Space, the chip under the mirror) clips your reaction while face search reads you.
    var canClip: Bool {
        faceSearchOn && mode == .live && camera.isRunning && !showSetupCard && faceEdit == nil && !isCutting
    }

    /// Shutter down: a short press takes a still, holding records a moving sticker (up to 3 s). Returns false when
    /// it was refused; that input's release then does nothing.
    @discardableResult
    func clipPress(from input: ShutterInput) -> Bool {
        guard canClip else { return false }
        closeMenu()
        return capture.press(from: input)
    }

    func clipRelease(from input: ShutterInput) {
        capture.release(from: input)
    }

    /// A tap (✂, ⌥S): a still.
    func clipTap() {
        guard clipPress(from: .key) else { return }
        capture.release(from: .key)
    }

    /// Drops a clip being recorded (Esc, face search off, the panel closing); a cut already under way finishes.
    private func cancelClip() {
        if capture.isBusy { capture.deactivate() }
    }

    /// Rename on the notice: the sticker's name, asked for in a small sheet.
    func renameClippedSticker() {
        guard let notice = clipNotice, var item = store.item(id: notice.itemID) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename sticker"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: item.displayName)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard AppModel.runInFront(alert) == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != item.displayName else { return }
        item.displayName = name
        store.update(item)
        saveSoon()
        var renamed = notice
        renamed.name = name
        clipNotice = renamed
        refreshCurrentResults()
    }

    /// Undo on the notice: the sticker is deleted (the clipboard keeps its copy).
    func undoClippedSticker() {
        guard let notice = clipNotice else { return }
        clipNotice = nil
        if newStickerID == notice.itemID { newStickerID = nil }
        if notice.isNew {
            friends.removeOwnSticker(id: notice.itemID)
        }
        refreshGroups()
        refreshCurrentResults()
    }

    func dismissClipNotice() {
        clipNotice = nil
    }

    /// A clip came in: cut you out (off the main thread), save the sticker to My Stickers, copy it, and show it
    /// first in the grid, marked NEW and selected. The panel stays open.
    private func handleClip(_ result: CaptureResult) {
        // A GIPHY pick still downloading must not overwrite the sticker on the pasteboard.
        commitToken += 1
        committingSession = nil
        isCutting = true
        clipNotice = nil
        let name = clipName
        let box = ClipWork(result: result)
        clipTask?.cancel()
        clipTask = Task { [weak self] in
            let clip = await Task.detached(priority: .userInitiated) { ClipSticker.make(from: box.result) }.value
            guard let self, !Task.isCancelled else { return }
            guard let clip else {
                self.isCutting = false
                HUDController.shared.show("Couldn’t find you in that one.")
                return
            }
            let made: (item: LibraryItem, isNew: Bool)
            do {
                made = try await self.friends.makeClipSticker(clip, name: name)
            } catch {
                self.isCutting = false
                modelLog.error("Saving a clipped sticker failed")
                HUDController.shared.show("Couldn’t save that one. Try again.")
                return
            }
            self.isCutting = false
            var copied = true
            do {
                try Clipboard.copy(fileURL: made.item.fileURL, item: made.item)
            } catch {
                copied = false
                modelLog.error("Copying a clipped sticker failed")
            }
            guard self.isPanelVisible else {
                HUDController.shared.show(copied ? "Saved “\(made.item.displayName)” · copied, ⌘V to paste"
                                                 : "Saved “\(made.item.displayName)” to My Stickers",
                                          thumbnail: made.item.fileURL)
                return
            }
            self.newStickerID = made.item.id
            let recents = self.store.recents
            self.clipNotice = ClipNotice(itemID: made.item.id, name: made.item.displayName,
                                         thumbnail: made.item.fileURL, isGIF: clip.isGIF, isNew: made.isNew,
                                         copied: copied,
                                         chipGroupIDs: recents.recentGroups(limit: AppModel.noticeGroupLimit).map(\.id),
                                         groupIDs: Set(recents.groups(containing: made.item.id).map(\.id)))
            if self.source != .all && self.source != .myStickers {
                self.selectSource(.myStickers)
            }
            self.userInteracted = true
            self.focusedIndex = 0
            // In My Stickers' row per group the new sticker isn't first: select it where it is.
            self.focus(onItem: made.item.id)
        }
    }

    /// "You — laughing": the word the camera reads now.
    private var clipName: String {
        if let word = readout?.word, !word.isEmpty { return "You — \(word)" }
        return "You"
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
        // In text, image and more-like modes the camera only feeds the (dimmed) mirror; while the face editor is
        // open, only the dimmed mirror.
        guard mode == .live, faceEdit == nil else {
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
        updateFaceReading(with: sample)
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
        // Search first: the camera runs only while face search is on.
        guard faceSearchOn else {
            camera.stop()
            if mode != .idle { mode = .idle }
            return
        }
        camera.refreshAuthorization()
        if camera.authorization == .authorized && camera.isRunning {
            setLive()
            return
        }
        // One device lookup for both questions: it runs on the main thread as ⌘F is pressed.
        let device = camera.usableDevice
        if !useCameraDespiteOtherApp && (device?.isInUseByAnotherApplication ?? false) {
            mode = .cameraBusy
            return
        }
        switch camera.authorization {
        case .authorized:
            if device != nil {
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

    /// The home page: recent in this app (else the newest own memes), mixed in All Sources with GIPHY's trending GIFs
    /// and Imgflip's most popular templates (`HomeMix`) until a face or words pick others. Library changes refresh it
    /// with `animateNew` (amber ring on arrivals) and without moving the focus.
    private func showRecentResults(animateNew: Bool = false, resetFocus: Bool = true) {
        resultSource = .recent
        if heldPose != nil { heldPose = nil }
        searchReadout = nil
        if !shownWeights.isEmpty { shownWeights = [:] }
        searchGeneration += 1
        let ranker = Ranker(baseline: tracker.baseline)
        // Favorites: what you saved, newest first.
        let recentIDs: [UUID]
        if source == .favorites {
            recentIDs = store.recents.saved
        } else if source == .myStickers, case let .group(id) = groupFilter, let group = store.recents.group(id: id) {
            // A group: the latest filed first (a live one: newest first).
            recentIDs = group.members(in: store.items, people: store.people)
        } else {
            recentIDs = store.recents.recent(appBundleID: previousBundleID)
        }
        let ranked = ranker.rank(
            sourceItems,
            query: .recent(appBundleID: previousBundleID),
            people: store.people,
            recents: recentIDs,
            limit: limit
        )
        setResults(ranked, animateNew: animateNew, resetFocus: resetFocus)
        // What's trending on GIPHY and the popular classic memes beside your recent picks, until a face or words pick
        // others.
        if giphyQuery == nil {
            showGiphy(for: .trending)
        }
        if templateQuery == nil {
            showTemplates(for: .trending)
        }
    }

    /// Face query: mood → weights → your memes ranked at once; the GIPHY row shows GIPHY's results for the mood
    /// (often already searched while the face was being held), the classic memes row the templates for it.
    /// `newQuery`: the tracker just caught a new face (or Space snapped one), so web rows already showing its mood turn
    /// to their next GIFs and templates; re-showing the same face (Esc, library changes) leaves them as they are.
    ///
    /// While the face editor is open the search is the edited face (`FaceEditSession.sample`) with the editor's
    /// weights, and its word the edited face's (tears drawn: "crying"). `settled` false (a drag in progress): your
    /// memes and the readout follow at once, the web rows wait for the drag to end.
    ///
    /// A clear gesture with no word of its own (`PoseDescription.of`) is searched by the words describing it instead of
    /// the face's mood: the on-device model's name for it, else the rule's phrase ("flexing", "rock on"). Your memes are
    /// ranked at once with the words known now (`heldPoseWords`). When the model can name the pose and was never asked
    /// about it, the web rows wait for its answer (`describe`, at most `PoseNamer.timeout`): the GIPHY row shows it is
    /// loading, the classic memes keep what they show. Re-showing the same query searches the words found for it
    /// (`describedPhrase`) and never asks again.
    private func runExpressionSearch(animate: Bool, newQuery: Bool = false, settled: Bool = true) {
        let edit = faceEdit
        guard let sample = edit?.sample ?? tracker.query else {
            showRecentResults()
            return
        }
        resultSource = .expression
        let previousWord = searchReadout?.word
        // Leaning on a part: the word is read from it alone, and it counts most below.
        let lean = edit == nil ? leanRegion : nil
        let wordSample = lean.map { FaceLean.sample(sample, leaningOn: $0, baseline: tracker.baseline) } ?? sample
        let mood = edit?.mood(baseline: tracker.baseline)
            ?? MoodClassifier.mood(for: wordSample.face, pose: wordSample.pose, shape: wordSample.shape,
                                   baseline: tracker.baseline)
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
        if edit != nil, let previousWord, let word = searchReadout?.word, word != previousWord {
            noteReplacedWord(previousWord)
        }
        let weights: FeatureWeights
        if let edit {
            weights = edit.featureWeights(baseline: tracker.baseline)
        } else {
            let deviation = sample.face.map { tracker.baseline.deviation(of: $0) } ?? [:]
            let automatic = FeatureWeights.automatic(deviation: deviation, poseStrength: sample.pose?.gestureStrength ?? 0)
            weights = lean.map { FaceLean.weights(automatic, leaningOn: $0) } ?? automatic
        }
        currentWeights = weights
        let shown: [FaceRegion: Double] = sample.face == nil
            ? [:]
            : (edit?.weightValues ?? [.brows: weights.brows, .eyes: weights.eyes, .mouth: weights.mouth])
        if shownWeights != shown { shownWeights = shown }
        searchGeneration += 1

        let ranker = Ranker(baseline: tracker.baseline)
        let phraseWords = poseWords.map { [$0.phrase] } ?? []
        let ranked = ranker.rank(sourceItems, query: .expression(sample, weights: weights, words: phraseWords),
                                 people: store.people, limit: limit, capsFriends: source != .myStickers)
        setResults(ranked, animateNew: animate, resetFocus: true)
        // A drag in progress: the web rows follow the word you let go on.
        guard settled else { return }
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
            // .warming too: Esc back from typing restarts the camera and searches the held pose (returnToFace).
            guard self.isPanelVisible, self.mode == .live || self.mode == .warming,
                  self.resultSource == .expression, self.tracker.query?.timestamp == timestamp else {
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
                let ranked = ranker.rank(self.sourceItems, query: .expression(sample, weights: self.currentWeights, words: [phrase]),
                                         people: self.store.people, limit: self.limit,
                                         capsFriends: self.source != .myStickers)
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
    /// caught with the same mood): then the grid shows the next `giphySlots` of GIPHY's results, wrapping around.
    /// After waiting for a pose's name (`awaitGiphyName`), words that came out the same as the row's show its GIFs
    /// again, turned the same way.
    private func showGiphy(for query: WebQuery, turningPage: Bool = false) {
        guard showsGiphyRow else { return }
        if giphyAwaitsName {
            giphyAwaitsName = false
            if query == giphyQuery && !giphyFound.isEmpty {
                if isGiphyLoading { isGiphyLoading = false }
                if turningPage && giphyFound.count > giphySlots {
                    giphyPage += 1
                }
                showGiphyPage()
                return
            }
        } else if query == giphyQuery && (isGiphyLoading || !giphyResults.isEmpty) {
            if turningPage && !isGiphyLoading && giphyFound.count > giphySlots {
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
        let row = WebDiscover.page(giphyPage, of: giphyFound, size: giphySlots)
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

    // MARK: - GIPHY's stickers

    /// GIPHY's stickers for the words GIPHY's GIFs go by (its trending before a face or words), while the GIPHY
    /// Stickers source shows. The same query already showing (or loading) is left alone.
    private func showGiphyStickers() {
        guard showsGiphyRow, source.showsGiphyStickers else { return }
        let query = giphyQuery ?? .trending
        if query == stickerQuery && (isStickersLoading || !stickerResults.isEmpty) { return }
        stickerGeneration += 1
        let generation = stickerGeneration
        stickerTask?.cancel()
        stickerTask = nil
        stickerQuery = query
        if stickersUnavailable { stickersUnavailable = false }
        if let cached = webStickers.cachedGIFs(for: query) {
            if isStickersLoading { isStickersLoading = false }
            setStickerResults(cached)
            return
        }
        setStickerResults([])
        isStickersLoading = true
        stickerTask = Task { [weak self] in
            guard let self else { return }
            let found = await self.webStickers.gifs(for: query)
            guard !Task.isCancelled, generation == self.stickerGeneration else { return }
            self.isStickersLoading = false
            self.stickerTask = nil
            if let found {
                self.setStickerResults(found)
            } else {
                self.stickersUnavailable = true
            }
        }
    }

    private func setStickerResults(_ stickers: [WebGIF]) {
        if stickerResults != stickers { stickerResults = stickers }
        normalizeFocus()
        if let first = stickers.first, source.showsGiphyStickers {
            webStickers.prefetchForCopy([first])
        }
    }

    private func clearStickers() {
        stickerGeneration += 1
        stickerTask?.cancel()
        stickerTask = nil
        stickerQuery = nil
        if !stickerResults.isEmpty { stickerResults = [] }
        if isStickersLoading { isStickersLoading = false }
        if stickersUnavailable { stickersUnavailable = false }
    }

    // MARK: - Classic memes row

    /// Shows the templates for `query` (picked on the Mac from Imgflip's list): at once from the list kept from
    /// earlier, else once Imgflip answers. The same query already showing (or loading) is left alone, unless
    /// `turningPage` (a new face caught with the same mood, or a pose with the same words): then the row shows the
    /// mood's (or the words') next templates. `fallback`: the face's mood, whose templates follow those a described
    /// pose's words name (`pickTemplates`); the same words with another face's mood are another order, shown from its
    /// first page.
    private func showTemplates(for query: WebQuery, turningPage: Bool = false, fallback: Mood = .reaction) {
        guard showsTemplateRow else { return }
        let sameOrder: Bool
        switch query {
        case .described: sameOrder = fallback == templateFallback
        case .trending, .mood, .words: sameOrder = true
        }
        if query == templateQuery && sameOrder && (isTemplatesLoading || !templateResults.isEmpty) {
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

    /// The classic memes for `query`: for `.trending`, the most popular, paged like a mood's; for a mood, its `page`th
    /// group of `templatePickSize` templates (page 0 the ones made for it, then the most popular; later pages the next
    /// ones, wrapping around); for words, the best matches; for a described pose, the templates its words name, then
    /// `fallback`'s (the face's mood: those made for it, then the most popular), paged like a mood's, so the row is
    /// never empty.
    static func pickTemplates(for query: WebQuery, from list: [MemeTemplate], page: Int = 0,
                              fallback: Mood = .reaction) -> [MemeTemplate] {
        let refs = list.map(\.ref)
        let indexes: [Int]
        switch query {
        case .trending:
            // Imgflip's list is in order of popularity: `.reaction` picks it as it is.
            indexes = MemeTemplateCatalog.pick(for: .reaction, from: refs, limit: templatePickSize, page: page)
        case let .mood(mood):
            indexes = MemeTemplateCatalog.pick(for: mood, from: refs, limit: templatePickSize, page: page)
        case let .words(text):
            indexes = MemeTemplateCatalog.pick(forTerms: [text], from: refs, limit: templatePickSize)
        case let .described(phrase):
            indexes = MemeTemplateCatalog.pick(forDescription: phrase, mood: fallback, from: refs, limit: templatePickSize,
                                               page: page)
        }
        return indexes.map { list[$0] }
    }

    private func setTemplateResults(_ picked: [MemeTemplate]) {
        let row = Array(picked.prefix(AppModel.templatePickSize))
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

    /// Leaving typed words: the GIPHY row stops showing results for them (back to trending with the recent picks), the
    /// classic memes go back to the popular ones (a face, if one is held, picks others right after).
    private func dropTypedWebQueries() {
        giphyWordsTask?.cancel()
        giphyWordsTask = nil
        if case .words? = giphyQuery { clearGiphyRow() }
        if case .words? = templateQuery { showTemplates(for: .trending) }
    }

    // MARK: - Tiles

    /// How many of GIPHY's GIFs the grid shows: all of a search's (WebDiscover asks for 24).
    private var giphySlots: Int { 24 }

    /// What the grid shows, in order. All Sources: on open, your recent picks taking turns with GIPHY's trending GIFs
    /// and the popular classic memes (`HomeMix`); for a search, a first row mixing your best matches with the classic
    /// memes (`ForYouMix`), then GIPHY's GIFs in GIPHY's order, then the rest of yours and of the classic memes. The
    /// other sources show their own.
    private func makeLayout() -> PickerLayout {
        let columns = gridColumns
        let ownPicks = results.map { Pick.meme($0.item) }
        let templatePicks = showsTemplateRow ? templateResults.map { Pick.template($0) } : []
        let gifPicks = showsGiphyRow ? giphyResults.map { Pick.gif($0) } : []
        var picks: [Pick] = []
        var loading = false
        var message: String?
        switch source {
        case .all:
            if resultSource == .recent {
                picks = HomeMix.picks(own: ownPicks.count, gifs: gifPicks.count, templates: templatePicks.count)
                    .map { pick in
                        switch pick {
                        case let .own(index): return ownPicks[index]
                        case let .gif(index): return gifPicks[index]
                        case let .template(index): return templatePicks[index]
                        }
                    }
            } else {
                let mix = ForYouMix.row(own: results.map { TileKind($0.item) }, templates: templatePicks.count,
                                        slots: columns)
                var usedOwn = Set<Int>()
                var usedTemplates = Set<Int>()
                for pick in mix {
                    switch pick {
                    case let .own(index):
                        usedOwn.insert(index)
                        picks.append(ownPicks[index])
                    case let .template(index):
                        usedTemplates.insert(index)
                        picks.append(templatePicks[index])
                    }
                }
                picks += gifPicks
                picks += ownPicks.indices.filter { !usedOwn.contains($0) }.map { ownPicks[$0] }
                picks += templatePicks.indices.filter { !usedTemplates.contains($0) }.map { templatePicks[$0] }
            }
            loading = (showsGiphyRow && isGiphyLoading) || (showsTemplateRow && isTemplatesLoading)
            message = ownEmptyMessage
        case .favorites:
            picks = ownPicks
            message = savedEmptyMessage
        case .onMyMac:
            picks = ownPicks
            message = ownEmptyMessage
        case .myStickers:
            if let sectioned = groupedStickersLayout(columns: columns) { return sectioned }
            picks = ownPicks
            message = stickersEmptyMessage
        case .giphyGIFs:
            picks = gifPicks
            loading = showsGiphyRow && isGiphyLoading
            message = showsGiphyRow ? giphyEmptyMessage : AppModel.webOffMessage
        case .giphyStickers:
            picks = showsGiphyRow ? stickerResults.map { Pick.giphySticker($0) } : []
            loading = showsGiphyRow && isStickersLoading
            if !showsGiphyRow {
                message = AppModel.webOffMessage
            } else if stickersUnavailable {
                message = "GIPHY isn’t answering right now."
            } else {
                message = "Nothing on GIPHY for this one."
            }
        case .classicMemes:
            picks = templatePicks
            loading = showsTemplateRow && isTemplatesLoading
            if !showsTemplateRow {
                message = AppModel.webOffMessage
            } else if templatesUnavailable {
                message = "Imgflip isn’t answering right now."
            } else {
                if let query = templateQuery, query != .trending {
                    message = "No classic memes for “\(query.label)”."
                } else {
                    message = "No classic memes."
                }
            }
        }
        // Clip me's new sticker comes first, wherever the ranking put it.
        if let id = newStickerID, source == .all || source == .myStickers, groupFilterAllows(id),
           let item = store.item(id: id) {
            picks.removeAll { if case let .meme(shown) = $0 { return shown.id == id }; return false }
            picks.insert(.meme(item), at: 0)
        }
        return PickerLayout(picks: picks, columns: columns, isLoading: loading, message: message,
                            title: sectionTitle)
    }

    private static let webOffMessage = "Turn on Web Discover in the menu for GIPHY and the classic memes."

    /// Over the grid: what it shows.
    private var sectionTitle: String {
        switch resultSource {
        case .recent:
            if source == .myStickers, let title = groupFilterTitle { return title }
            switch source {
            case .all: return results.isEmpty ? "Trending" : recentTitle + " & Trending"
            case .onMyMac, .myStickers: return recentTitle
            case .favorites: return "Favorites"
            case .giphyGIFs, .giphyStickers: return "Trending"
            case .classicMemes: return "Popular"
            }
        case .expression:
            if let word = readout?.word { return "Matching your face · \(word)" }
            return "Matching your face"
        case .text:
            let words = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
            return words.isEmpty ? "Results" : "Results for “\(words)”"
        case .image:
            return "Like your image"
        case .moreLike:
            return "More like “\(moreLikeItem?.displayName ?? "this")”"
        }
    }

    /// What you sent last here ("Recent in Messages"), else "Recent", or your newest before you sent anything.
    private var recentTitle: String {
        guard !results.isEmpty else { return "Recent" }
        let recent = store.recents.recent(appBundleID: previousBundleID)
        guard results.contains(where: { recent.contains($0.item.id) }) else { return "Your newest" }
        if let bundleID = previousBundleID, let name = previousAppName, !name.isEmpty,
           store.recents.byApp[bundleID]?.isEmpty == false {
            return "Recent in \(name)"
        }
        return "Recent"
    }

    private var savedEmptyMessage: String {
        savedIDs.isEmpty
            ? "No favorites yet. Select one of your memes and press ⌘S."
            : "None of your favorites match."
    }

    /// What a row of yours that shows nothing says.
    private var ownEmptyMessage: String {
        let words = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .text && !words.isEmpty {
            return "No memes match “\(words)”."
        }
        return hasMemes ? "No memes match." : "Your memes will show here."
    }

    /// What GIPHY's row says while it has no GIFs; nil while they load.
    private var giphyEmptyMessage: String? {
        if isGiphyLoading { return nil }
        if giphyUnavailable { return "GIPHY isn’t answering right now." }
        return giphyQuery == nil ? "Make a face or a pose for GIFs from GIPHY." : "Nothing on GIPHY for this one."
    }

    private var stickersEmptyMessage: String {
        let hasStickers = store.items.contains { $0.isSticker && $0.kind != .web }
        guard hasStickers else { return "Drop a photo of a friend on the MemeMe icon to make a sticker." }
        if resultSource == .recent {
            switch groupFilter {
            case .all: break
            case .group: return "Nothing in this group yet. Select a sticker and press ⌘K to add it."
            case .ungrouped: return "Every sticker is in a group."
            }
        }
        return "No stickers match."
    }

    private func refreshHasMemes() {
        let has = store.items.contains { $0.kind != .web && $0.tier != .skipped }
        if hasMemes != has {
            hasMemes = has
        }
    }

    /// Where the focus starts: the first tile, top to bottom. A typed, image or more-like search that found nothing
    /// of yours starts on none when you have memes, so ↵ copies nothing; GIPHY's and the classic memes' tiles are an
    /// arrow away.
    private var startSlot: Int {
        makeLayout().rows.firstSlot ?? 0
    }

    private func pick(atSlot slot: Int) -> Pick? {
        makeLayout().pick(at: slot)
    }

    /// Keeps the focus on a tile: before the user moves it, on the start slot (`startSlot`); after, on the last tile of
    /// its row when its own went (the first tile when the row has none).
    private func normalizeFocus() {
        // Until the user points somewhere, the focus follows the start slot as the rows fill in.
        if !userInteracted {
            let target = startSlot
            if focusedIndex != target {
                focusedIndex = target
            }
            return
        }
        let rows = makeLayout().rows
        guard !rows.isFilled(focusedIndex) else { return }
        let target = rows.lastSlot(inRow: rows.row(of: focusedIndex)) ?? rows.firstSlot ?? focusedIndex
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
        let ranked = ranker.rank(sourceItems, query: .text(raw, face: face, weights: weights), people: store.people, limit: limit)
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
        let pool = sourceItems.filter { item in
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
        let ranked = ranker.rank(sourceItems, query: .moreLike(item), people: store.people, limit: limit)
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

    /// Your things the source shows: the library without GIPHY's GIFs (they are never kept in it), of the source's
    /// kinds (none for GIPHY's and the classic memes).
    private var sourceItems: [LibraryItem] {
        let inGroup = groupFilterAllows
        return store.items.filter { item in
            item.kind != .web && source.shows(TileKind(item)) && (source != .favorites || savedIDs.contains(item.id))
                && inGroup(item.id)
        }
    }

    /// My Stickers' chip: whether a sticker is shown (one group's, or those in none); everything elsewhere.
    private var groupFilterAllows: (UUID) -> Bool {
        guard source == .myStickers else { return { _ in true } }
        switch groupFilter {
        case .all:
            return { _ in true }
        case let .group(id):
            let members = Set(stickerGroups.first { $0.id == id }?.members(in: store.items, people: store.people) ?? [])
            return { members.contains($0) }
        case .ungrouped:
            let grouped = Set(groupMembers().values.flatMap { $0 })
            return { !grouped.contains($0) }
        }
    }

    private func setResults(_ newResults: [RankedResult], animateNew: Bool, resetFocus: Bool) {
        let limited = Array(newResults.prefix(limit))
        refreshHasMemes()
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

    /// Tiles that just arrived, for 600 ms.
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
        case let .giphySticker(gif)?:
            webStickers.prefetchForCopy([gif])
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
        let typedRightAfterOpening = began - max(shownAt, faceOnAt) < AppModel.typingStopsCameraWindow
        resetQueryImage()
        if holdProgress != 0 { holdProgress = 0 }
        if !typedRightAfterOpening, let held = tracker.query,
           held.face != nil || (held.pose?.gestureStrength ?? 0) >= Ranker.gestureWithoutFace, camera.isRunning {
            faceTokenSample = held
            faceTokenWeights = currentWeights
            showsFaceToken = true
        } else {
            // Typing takes over: without a face caught, face search turns off.
            faceTokenSample = nil
            showsFaceToken = false
            camera.stop()
            if faceSearchOn {
                faceSearchOn = false
                if leanRegion != nil { leanRegion = nil }
            }
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
        // The drawer folds back into the notch, which says so: "✓ Copied" and "⌘V to paste" beside it.
        HUDController.shared.showCopied(thumbnail: fileURL)
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
        case let .giphySticker(gif):
            let slowNotice = AppModel.slowCopyNotice()
            let url = await webStickers.prepareForCopy(gif)
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
        case let .gif(gif), let .giphySticker(gif):
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
    private func giphyDragProvider(for gif: WebGIF, from web: WebDiscover) -> NSItemProvider {
        let provider = NSItemProvider()
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
        guard isPanelVisible else { return }
        refreshGroups()
        refreshFooter()
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

    /// The search's word while live, unless the face it came from (alone or with a pose) is lost: then the hint says
    /// so. While the face editor is open it is the edited face's word (the camera isn't searching).
    private func computeReadout() -> MoodReadout? {
        guard mode == .live, let searchReadout else { return nil }
        if faceEdit == nil, searchReadout.source != .pose && faceMissing {
            return nil
        }
        return searchReadout
    }

    private func computeHint() -> PanelHint {
        switch mode {
        case .idle:
            return PanelHint(title: HintCopy.idleTitle, subtitle: HintCopy.idleSubtitle, actionTitle: nil, action: nil)
        case .prompt:
            return PanelHint(title: HintCopy.promptTitle, subtitle: HintCopy.promptSubtitle, actionTitle: nil, action: nil)
        case .warming:
            return PanelHint(title: HintCopy.warmingTitle, subtitle: HintCopy.warmingSubtitle, actionTitle: nil, action: nil)
        case .live:
            if faceEdit != nil {
                return PanelHint(title: HintCopy.editingTitle, subtitle: nil, actionTitle: HintCopy.backToFaceAction,
                                 action: .backToFace)
            }
            if faceMissing {
                // Standing back, the face is too small to read: that's fine, the pose is read.
                if standingBack.isStandingBack {
                    return PanelHint(title: HintCopy.standingBackTitle, subtitle: HintCopy.standingBackSubtitle, actionTitle: nil, action: nil)
                }
                return PanelHint(title: HintCopy.noFaceTitle, subtitle: HintCopy.noFaceSubtitle, actionTitle: nil, action: nil)
            }
            // Under the big mirror, until a face is caught: the words say small changes count, then "Hold it…" while one
            // is held. After that the same words the whole time: the ring around the mirror shows a face being held.
            if isReadingFace {
                return PanelHint(title: HintCopy.holdingTitle, subtitle: HintCopy.holdingSubtitle, actionTitle: nil,
                                 action: nil)
            }
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

    // MARK: - Session and persistence

    private func resetForNewSession() {
        cancelClip()
        newStickerID = nil
        clipNotice = nil
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
        endFaceEdit()
        if !shownWeights.isEmpty { shownWeights = [:] }
        if holdProgress != 0 { holdProgress = 0 }
        if !newResultIDs.isEmpty { newResultIDs = [] }
        if showSetupCard { showSetupCard = false }
        // Always open on search in All Sources, so ⌥M then ↩ repeats your last pick.
        if source != .all { source = .all }
        if groupFilter != .all { groupFilter = .all }
        if faceSearchOn { faceSearchOn = false }
        if leanRegion != nil { leanRegion = nil }
        closeMenu()
        clearStickers()
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
        stickerTask?.cancel()
        stickerTask = nil
        stickerGeneration += 1
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
