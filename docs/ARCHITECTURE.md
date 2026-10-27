# MemeMe — architecture & code contract

This file is the contract between source files. **Signatures below are binding**: implement them exactly (names, labels, types, optionality, `async`/`throws`, actor isolation). You may add private helpers and extra `private`/`fileprivate` members freely. If you need a cross-file change, do not edit another owner's file; report it.

Read `docs/DESIGN.md` for behavior and exact UI strings.

## Build setup

- Swift Package (`Package.swift`, tools 5.9, **Swift 5 language mode**), `platforms: [.macOS(.v14)]`. No third-party dependencies.
- Targets:
  - `MemeMeCore` — library, **Foundation only** (no AppKit/Vision/CoreGraphics/Accelerate/CryptoKit). Must also compile on Linux. Everything is `public`.
  - `MemeMeApp` — executable (product name `MemeMe`). AppKit + SwiftUI + AVFoundation + Vision + CoreImage + ImageIO + CryptoKit + Carbon + ServiceManagement + UniformTypeIdentifiers + Network. Types are `internal`.
  - `MemeMeCoreTests` — XCTest for the core.
  - `MemeMeAppTests` — XCTest for the app target (`@testable import MemeMeApp`): GIPHY decoding via a URLProtocol stub, ImageAnalyzer on generated images, clipboard naming, keep/undo, sticker eligibility, headless AppModel text search.
- `scripts/build-app.sh` assembles `build/MemeMe.app` (Info.plist from `Resources/Info.plist`; `GiphyAPIKey` from `$GIPHY_API_KEY`; `CFBundleShortVersionString` from `$APP_VERSION`, default the `VERSION` file; `CFBundleVersion` from `$APP_BUILD`, default `git rev-list --count HEAD`; `MemeMeUpdateFeedURL` from `$UPDATE_FEED_URL`, default empty = updates off) and signs it: ad hoc, or with `$CODESIGN_IDENTITY` (a Developer ID), the hardened runtime, a timestamp and `Resources/MemeMe.entitlements`. `scripts/build-dmg.sh` packs it into `build/MemeMe.dmg` (the app plus an `Applications` link, UDZO) with dmgbuild (`scripts/dmg-settings.py`: a 660×400 icon-view window, the app at (170, 196), Applications at (490, 196), background from `Resources/DMG`), signs the DMG with the same identity and, given `$APPLE_ID`, `$APPLE_TEAM_ID` and `$APPLE_APP_PASSWORD`, notarizes and staples it. It then mounts the DMG and checks the app's signature and the link.
- CI (`.github/workflows/ci.yml`): job `build` (`macos-15`) runs `swift build`, `swift test`, both scripts and uploads `MemeMe.dmg` as the `MemeMe-app` artifact; it also decides whether this run is a release (push or manual run on the default branch, and app files changed since the last `v*` tag, or a manual run). Job `release` (`ubuntu-latest`, `contents: write`) runs `scripts/publish-release.sh`, which publishes GitHub Release `v<version>-<build>` with `MemeMe.dmg` and `latest.json` (the update feed, see `UpdateManifest`) and marks it latest.
- Logging: `os.Logger(subsystem: "com.mememe.app", category: "<file area>")`. Never log file contents, OCR text or face data.
- Concurrency: classes that publish UI state are `@MainActor`. Heavy work (Vision, ImageIO, hashing, network decoding) runs off the main actor (`Task.detached(priority: .utility)` or a private `DispatchQueue`), results hop back with `await MainActor.run` or `@MainActor` methods. Avoid `Sendable` warnings becoming errors: no `-strict-concurrency=complete`.

## File ownership

| Owner | Files |
|---|---|
| Core | `Sources/MemeMeCore/*.swift`, `Tests/MemeMeCoreTests/*.swift` |
| Vision & camera | `Sources/MemeMeApp/Vision/FaceFeatureExtractor.swift`, `Vision/ImageAnalyzer.swift`, `Vision/ThumbnailCache.swift`, `Camera/CameraController.swift`, `Camera/CameraPreviewView.swift` |
| Library, web, stickers | `Sources/MemeMeApp/Library/LibraryIndexer.swift`, `Library/FolderWatcher.swift`, `Web/GIFProvider.swift`, `Web/GiphyProvider.swift`, `Web/WebDiscover.swift`, `Stickers/StickerMaker.swift`, `Stickers/FriendService.swift`, `System/Clipboard.swift`, `System/SystemConditions.swift` |
| Panel UI | `Sources/MemeMeApp/UI/PanelController.swift`, `UI/PanelView.swift`, `UI/MirrorColumn.swift`, `UI/ResultGrid.swift`, `UI/FooterView.swift`, `UI/SetupCardView.swift`, `UI/HUDController.swift`, `UI/StickerPopoverView.swift`, `UI/AnimatedImageView.swift`, `UI/Theme.swift` |
| App shell | `Sources/MemeMeApp/App/main.swift`, `App/AppDelegate.swift`, `App/AppModel.swift`, `App/HotKey.swift`, `App/StatusItemController.swift`, `App/StickerPopoverModel.swift`, `App/LoginItem.swift`, `Resources/Info.plist`, `scripts/build-app.sh`, `.github/workflows/ci.yml`, `README.md`, `.gitignore` |
| Updates | `Sources/MemeMeApp/Update/UpdateChecker.swift`, `Update/UpdateInstaller.swift`, `Tests/MemeMeAppTests/UpdateCheckerTests.swift`, `Tests/MemeMeAppTests/UpdateInstallerTests.swift` |
| Release | `VERSION`, `scripts/build-dmg.sh`, `scripts/publish-release.sh`, `scripts/build-site.sh`, `site/index.html` |

`Package.swift`, `docs/*` are owned by the lead; do not edit.

---

## MemeMeCore (public API)

### FaceFeatures.swift

```swift
public enum FaceRegion: String, CaseIterable, Codable, Hashable, Sendable { case brows, eyes, mouth }

public struct FaceFeatures: Codable, Hashable, Sendable {
    public var browRaise: Double      // 0...1
    public var eyeOpenness: Double    // 0...1
    public var mouthOpenness: Double  // 0...1
    public var mouthWidth: Double     // 0...1
    public var smile: Double          // 0...1; 0.5 = neutral corners, > 0.5 corners up
    public var headTilt: Double       // 0...1 (|roll| / 45°)
    public var gazeSide: Double       // 0...1 (pupils toward one side = side-eye)
    public init(browRaise: Double, eyeOpenness: Double, mouthOpenness: Double, mouthWidth: Double, smile: Double, headTilt: Double, gazeSide: Double)
    /// Typical resting face under the extractor's mapping (see FaceFeatureExtractor).
    public static let populationNeutral: FaceFeatures   // (0.45, 0.45, 0.05, 0.45, 0.5, 0.0, 0.1)
    /// [browRaise, eyeOpenness, mouthOpenness, mouthWidth, smile, headTilt, gazeSide]
    public var vector: [Double] { get }
    /// Indices into `vector` per region: brows [0], eyes [1, 6], mouth [2, 3, 4].
    public static func indices(for region: FaceRegion) -> [Int]
    public func clamped() -> FaceFeatures   // every field clamped to 0...1
}

public struct PoseFeatures: Codable, Hashable, Sendable {
    public var handsRaised: Double   // 0...1 wrists at/above shoulders or near the face
    public var armsSpread: Double    // 0...1 wrist span relative to shoulder width
    public var bodyVisible: Double   // 0...1 confidence that shoulders are in frame
    public init(handsRaised: Double, armsSpread: Double, bodyVisible: Double)
    public static let none: PoseFeatures            // all 0
    public var activity: Double { get }             // max(handsRaised, armsSpread) * bodyVisible, clamped 0...1
}

public struct ExpressionSample: Codable, Hashable, Sendable {
    public var face: FaceFeatures?
    public var pose: PoseFeatures?
    public var timestamp: TimeInterval   // seconds, monotonic (CACurrentMediaTime on the app side)
    public var sharpness: Double         // 0...1, 1 when unknown
    public init(face: FaceFeatures?, pose: PoseFeatures? = nil, timestamp: TimeInterval, sharpness: Double = 1)
}
```

### Baseline.swift

```swift
public struct RestingBaseline: Codable, Equatable, Sendable {
    public private(set) var neutral: FaceFeatures
    public private(set) var sampleCount: Int
    public init(neutral: FaceFeatures = .populationNeutral, sampleCount: Int = 0)
    /// Updates an EMA from calm frames: a frame is calm when intensity(of:) < (sampleCount < 30 ? 0.25 : 0.08).
    /// alpha = sampleCount < 30 ? 0.2 : 0.05. Increments sampleCount for calm frames only.
    public mutating func observe(_ face: FaceFeatures)
    /// face.vector - neutral.vector
    public func signedDeviation(of face: FaceFeatures) -> [Double]
    /// Per region: min(1, 2 * mean |deviation| over the region's indices)
    public func deviation(of face: FaceFeatures) -> [FaceRegion: Double]
    /// min(1, 2 * RMS(signedDeviation))
    public func intensity(of face: FaceFeatures) -> Double
}
```

### FeatureWeights.swift

```swift
public struct FeatureWeights: Codable, Hashable, Sendable {
    public var brows: Double
    public var eyes: Double
    public var mouth: Double
    public var pose: Double     // 0...1 share of the face score taken by pose similarity
    public init(brows: Double = 1, eyes: Double = 1, mouth: Double = 1, pose: Double = 0.15)
    public static let uniform: FeatureWeights
    public subscript(region: FaceRegion) -> Double { get set }
    /// m = max deviation; if m < 0.05 → all 1, else 1 + 2 * d / m per region. pose = clamp(0.15 + 0.5 * poseActivity, 0.15, 0.6)
    public static func automatic(deviation: [FaceRegion: Double], poseActivity: Double) -> FeatureWeights
    /// Pinned regions get weight 6.
    public func pinning(_ pins: Set<FaceRegion>) -> FeatureWeights
}
```

### PeakHoldTracker.swift

```swift
public struct PeakHoldConfig: Sendable {
    public var holdDuration: TimeInterval = 0.3
    public var newExpressionHold: TimeInterval = 1.0
    public var strongerRatio: Double = 1.15
    public var sameDirectionCosine: Double = 0.85
    public var minimumIntensity: Double = 0.12
    public var bufferWindow: TimeInterval = 0.5
    public init()
}

public final class PeakHoldTracker {
    public var baseline: RestingBaseline
    public let config: PeakHoldConfig
    public private(set) var query: ExpressionSample?
    public private(set) var queryIntensity: Double          // 0 when no query
    public private(set) var holdProgress: Double            // 0...1 toward replacing the query
    public private(set) var candidateIsNewExpression: Bool
    public private(set) var lastSample: ExpressionSample?
    public private(set) var lastFaceTimestamp: TimeInterval? // timestamp of the last sample that had a face
    public init(baseline: RestingBaseline = RestingBaseline(), config: PeakHoldConfig = PeakHoldConfig())
    /// Feed every analyzed frame. Returns true when `query` changed.
    @discardableResult public func ingest(_ sample: ExpressionSample) -> Bool
    /// Space: makes the last sample with a face the query, even if neutral. Returns true if it changed the query.
    @discardableResult public func snap() -> Bool
    /// Clears query and candidate (keeps the baseline).
    public func reset()
}
```

Algorithm (binding):
- `ingest`: set `lastSample`. No face → clear the candidate, `holdProgress = 0`, return false. Calm frames feed `baseline.observe`.
- Effective intensity `e = max(baseline.intensity(of: face), 0.8 * (pose?.activity ?? 0))`. Direction vector = `signedDeviation(of: face) + [pose?.activity ?? 0]` (8 values), normalized.
- A sample is a candidate if `e >= minimumIntensity`; otherwise clear the candidate, return false.
- The candidate is a run of consecutive candidate samples whose direction cosine with the run's first sample is ≥ `sameDirectionCosine`; a sample outside that cone starts a new run. Within a run keep the best sample by `e * sharpness` among samples whose timestamp is within `bufferWindow` of the newest.
- Required hold: no query → `holdDuration`. Same direction as the query (cosine ≥ `sameDirectionCosine`) → `holdDuration`, and only if `bestE >= queryIntensity * strongerRatio` (otherwise `holdProgress = 0`, no replacement). Different direction → `newExpressionHold` and `candidateIsNewExpression = true`.
- `holdProgress = min(1, (newest.timestamp - run.start) / required)`. When it reaches 1: `query = best`, `queryIntensity = bestE`, clear the run, `holdProgress = 0`, `candidateIsNewExpression = false`, return true.

### Mood.swift

```swift
public enum Mood: String, CaseIterable, Codable, Hashable, Sendable {
    case shocked, screaming, laughing, happy, smug, sideEye, crying, sad, angry, confused, unimpressed, nervous, excited, reaction
    /// GIPHY query, e.g. "shocked reaction", "side eye", "unimpressed", "reaction"
    public var searchQuery: String { get }
    /// Human word, e.g. "shocked", "side eye"
    public var label: String { get }
    /// Moods prefetched in the background, most common first.
    public static let prefetchOrder: [Mood]   // [.shocked, .laughing, .sideEye, .unimpressed, .crying, .smug, .happy, .screaming, .confused, .angry]
}

public enum MoodClassifier {
    /// Rules in this order (d = signed deviation from baseline.neutral; o = face.mouthOpenness; s = face.smile - 0.5):
    /// 1. face nil → .reaction
    /// 2. pose.handsRaised ≥ 0.5 && o ≥ 0.35 → .screaming;  pose.activity ≥ 0.5 && s > 0.08 → .excited
    /// 3. o ≥ 0.45 && s ≤ 0.05 && (d.eye ≥ 0.1 || d.brow ≥ 0.1) → o ≥ 0.7 ? .screaming : .shocked
    /// 4. o ≥ 0.2 && s > 0.08 → .laughing
    /// 5. d.eye ≥ 0.15 && d.brow ≥ 0.12 → .shocked
    /// 6. face.gazeSide ≥ 0.45 → .sideEye
    /// 7. s > 0.12 → d.eye < -0.12 ? .smug : .happy
    /// 8. s < -0.1 → d.brow > 0.05 ? .crying : .sad
    /// 9. d.brow > 0.12 && s < 0 → .nervous
    /// 10. d.brow < -0.12 → .angry
    /// 11. face.headTilt ≥ 0.35 → .confused
    /// 12. else → .unimpressed
    public static func mood(for face: FaceFeatures?, pose: PoseFeatures?, baseline: RestingBaseline) -> Mood
}
```

### LibraryItem.swift

```swift
public enum ItemKind: String, Codable, Sendable { case mine, friend, pack, web }
public enum ItemTier: String, Codable, Sendable { case meme, maybe, skipped }

public struct LibraryItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var fileURL: URL               // local file (web items: the cached still)
    public var displayName: String        // file name without extension, or the web title
    public var kind: ItemKind
    public var tier: ItemTier
    public var source: String             // "Downloads", "Desktop", "Screenshots", "Kept", "Friend sticker", "GIPHY", or a folder name
    public var sourceDetail: String?      // e.g. "from reddit.com" (kMDItemWhereFroms host), "IMG_2207.HEIC"
    public var addedAt: Date
    public var fileModifiedAt: Date?
    public var fileSize: Int64
    public var contentHash: String        // SHA-256 hex of the file bytes (web: "giphy:<id>")
    public var isSticker: Bool
    public var isAnimated: Bool
    public var face: FaceFeatures?
    public var pose: PoseFeatures?
    public var intensity: Double          // 0...1 against FaceFeatures.populationNeutral
    public var featurePrint: [Float]?     // JSON: base64 of little-endian Float32 (FloatCoding)
    public var featurePrintRevision: Int
    public var text: String               // OCR, ≤ 200 chars
    public var labels: [String]
    public var personID: UUID?
    public var faceEmbedding: [Float]?    // stickers only; JSON like featurePrint
    public var remoteURL: URL?            // web: full GIF to download on commit
    public var previewURL: URL?           // web: small animated GIF for the focused tile
    public var attribution: String?       // web: "via GIPHY"
    public var timesSent: Int
    public var lastSentAt: Date?
    public init(id: UUID = UUID(), fileURL: URL, displayName: String, kind: ItemKind, tier: ItemTier = .meme, source: String, sourceDetail: String? = nil, addedAt: Date = Date(), fileModifiedAt: Date? = nil, fileSize: Int64 = 0, contentHash: String, isSticker: Bool = false, isAnimated: Bool = false, face: FaceFeatures? = nil, pose: PoseFeatures? = nil, intensity: Double = 0, featurePrint: [Float]? = nil, featurePrintRevision: Int = 0, text: String = "", labels: [String] = [], personID: UUID? = nil, faceEmbedding: [Float]? = nil, remoteURL: URL? = nil, previewURL: URL? = nil, attribution: String? = nil, timesSent: Int = 0, lastSentAt: Date? = nil)
    public var isOwn: Bool { get }          // kind == .mine || kind == .friend
    /// "March 2026" (en_US_POSIX "LLLL yyyy", UTC) of fileModifiedAt ?? addedAt
    public var monthKey: String { get }
    /// Own: "Downloads · from reddit.com · Mar 2026"; friend: "Friend sticker · Sep 2026"; web: "via GIPHY"
    public var provenance: String { get }
}

public enum FloatCoding {
    public static func encode(_ values: [Float]) -> String      // base64 of little-endian Float32
    public static func decode(_ string: String) -> [Float]?
}
```
`LibraryItem` implements `init(from:)` with `decodeIfPresent` + defaults for every non-essential key so older JSON keeps loading.

### Person.swift

```swift
public struct Person: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String?            // nil = unnamed ("New face")
    public var embeddings: [[Float]]    // up to 20, FloatCoding in JSON
    public var createdAt: Date
    public init(id: UUID = UUID(), name: String? = nil, embeddings: [[Float]] = [], createdAt: Date = Date())
    public var displayName: String { get }          // name ?? "New face"
    public mutating func addEmbedding(_ e: [Float]) // keeps the newest 20
}

public enum PersonMatch: Equatable, Sendable {
    case confident(UUID)
    case likely(UUID, Double)
    case newFace
}

public struct FriendMatcher: Sendable {
    public var confidentThreshold: Double
    public var likelyThreshold: Double
    public init(confidentThreshold: Double = 0.90, likelyThreshold: Double = 0.80)
    /// Score per person = mean of the top-3 cosine similarities to its embeddings. Best person ≥ confident → .confident; ≥ likely → .likely; else .newFace.
    public func match(_ embedding: [Float], among people: [Person]) -> PersonMatch
}
```

### VectorMath.swift

```swift
public enum VectorMath {
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double     // 0 when sizes differ or a norm is 0
    public static func cosine(_ a: [Double], _ b: [Double]) -> Double
    public static func normalized(_ v: [Double]) -> [Double]             // zeros when norm < 1e-9
    public static func meanAbsDiff(_ a: [Double], _ b: [Double]) -> Double
}
```

### Ranker.swift

```swift
public enum SearchQuery: Sendable {
    case recent(appBundleID: String?)
    case expression(ExpressionSample, weights: FeatureWeights)
    case text(String, face: ExpressionSample?, weights: FeatureWeights)
    case image(featurePrint: [Float]?, face: FaceFeatures?, intensity: Double)
    case moreLike(LibraryItem)
}

public struct RankedResult: Identifiable, Hashable, Sendable {
    public var id: UUID { get }          // item.id
    public let item: LibraryItem
    public let score: Double
    public let section: String?          // text search: month key, "From GIPHY", "From your photos"
    public init(item: LibraryItem, score: Double, section: String? = nil)
}

public struct TextQuery: Equatable, Sendable {
    public var terms: [String]           // lowercased, filters removed
    public var onlyMine: Bool            // "mine"
    public var onlyGIFs: Bool            // "gif" / "gifs"
    public var onlyStickers: Bool        // "sticker" / "stickers"
    public var personIDs: Set<UUID>      // terms equal (case-insensitive) to a person's name are removed from terms and become filters
    public static func parse(_ raw: String, people: [Person]) -> TextQuery
    /// The single remaining term when it is alphabetic, ≥ 3 letters and matched no person (used for "Is one of these Sam?").
    public var possibleName: String? { get }
}

public struct Ranker: Sendable {
    public var baseline: RestingBaseline
    public init(baseline: RestingBaseline = RestingBaseline())
    public func rank(_ items: [LibraryItem], query: SearchQuery, people: [Person] = [], recents: [UUID] = [], limit: Int = 10) -> [RankedResult]
    public func expressionScore(item: LibraryItem, sample: ExpressionSample, weights: FeatureWeights) -> Double
}
```

Scoring (binding):
- **expressionScore**: target `t = sample.face.map { baseline.intensity(of: $0) } ?? 0.3`. If `item.face` and `sample.face` exist: `qDev = baseline.signedDeviation(of: sample.face)`, `iDev = item.face.vector - populationNeutral.vector`; per region `sim_r = max(0, 1 - meanAbsDiff(qDev[idx_r], iDev[idx_r]) / 0.5)`; `featureSim = Σ w_r·sim_r / Σ w_r`; `poseSim = 1 - |(item.pose?.activity ?? 0.1) - (sample.pose?.activity ?? 0)|`; `faceScore = (1 - w.pose)·featureSim + w.pose·poseSim`; `fit = 1 - |item.intensity - t|`; `score = 0.7·faceScore + 0.3·fit`. Without item or sample face: `score = 0.25 + 0.3·fit`. Then `+0.02` if `isOwn`, `+0.01·min(timesSent,5)/5`, `-0.01` if `kind == .web`.
- **expression** results: items with `tier == .meme` only; sort by score desc; keep at most 2 `kind == .friend` items within the first `limit` (extras are dropped from the window); return `limit`.
- **text**: parse with `TextQuery.parse`. Pool: `tier` meme or maybe, matching filters; every term must be a substring of `lowercased(displayName + " " + text + " " + labels.joined(" ") + " " + source + " " + (sourceDetail ?? "") + " " + person name)`. Order inside groups: by `expressionScore` when `face` is non-nil, else newest first (`fileModifiedAt ?? addedAt`). Groups and `section`: own items grouped by `monthKey` (newest month first), then `.pack` ("Packs"), then `.web` ("From GIPHY"). If fewer than 3 hits, append matching `skipped` items with section "From your photos". Return up to `limit`.
- **image**: meme tier; `fp = featurePrint != nil && item.featurePrint != nil ? (cosine + 1) / 2 : 0.5`; `fs = face sim with uniform weights using populationNeutral for both (0.5 when either is nil)`; `score = 0.7·fp + 0.3·fs`, then the same own/web adjustments.
- **moreLike(L)**: exclude `L.id`; `score = 0.6·fp + 0.3·fs + 0.1·(1 - |item.intensity - L.intensity|)` (fp/fs as above, comparing to L).
- **recent(app)**: items whose ids appear in `recents` (in that order, meme or maybe tier), then fill up to `limit` with own meme-tier items by `lastSentAt` desc, then `addedAt` desc. Score 1.

### ResultMerger.swift

```swift
public enum ResultMerger {
    /// Keeps current[0..<min(lockedCount, current.count)] in place, then fills from `incoming` (skipping ids already kept) up to `limit`.
    public static func merge(current: [RankedResult], incoming: [RankedResult], lockedCount: Int, limit: Int) -> [RankedResult]
    /// Count of leading results that are own items with score ≥ threshold (default 0.6).
    public static func strongOwnPrefix(_ results: [RankedResult], threshold: Double = 0.6) -> Int
}
```

### Classifier.swift

```swift
public struct ImageFacts: Codable, Hashable, Sendable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var isAnimated: Bool
    public var isCameraPhoto: Bool        // EXIF/TIFF Make or Model present and not a screenshot
    public var isScreenshot: Bool         // file name starts with "Screenshot"/"Screen Shot"/"CleanShot", or EXIF UserComment == "Screenshot"
    public var textCharacterCount: Int
    public var faceCount: Int
    public var largestFaceHeightFraction: Double
    public var labels: [String]
    public init(pixelWidth: Int, pixelHeight: Int, isAnimated: Bool, isCameraPhoto: Bool, isScreenshot: Bool, textCharacterCount: Int, faceCount: Int, largestFaceHeightFraction: Double, labels: [String])
}

public enum MemeTierClassifier {
    /// 1. min(w, h) < 64 → skipped   2. animated → meme   3. screenshot && faceCount == 0 && text > 280 → skipped
    /// 4. camera photo → skipped     5. faceCount > 0 || text ≥ 8 → meme
    /// 6. any label contains cat, dog, animal, cartoon, illustration, drawing, comic, meme (case-insensitive) → meme   7. else → maybe
    public static func tier(for facts: ImageFacts) -> ItemTier
}

public enum StickerPolicy: String, Codable, CaseIterable, Sendable { case automatic, ask, never }

public enum StickerEligibility {
    public static let minimumFaceHeightFraction: Double   // 0.06
    /// [] when animated or text ≥ 8 characters (it's a meme, not a photo of people); else indices of faces with height fraction ≥ minimum.
    public static func eligibleFaceIndices(facts: ImageFacts, faceHeightFractions: [Double]) -> [Int]
}
```

### RecentStore.swift

```swift
public struct RecentStore: Codable, Equatable, Sendable {
    public private(set) var byApp: [String: [UUID]]
    public static let globalKey: String          // "*"
    public init()
    /// Moves id to the front of the app's list and of the global list; each capped at 30.
    public mutating func record(_ id: UUID, appBundleID: String?)
    /// App list first, then global entries not already included.
    public func recent(appBundleID: String?) -> [UUID]
    public mutating func remove(_ ids: Set<UUID>)
}
```

### AppSettings.swift

```swift
public struct AppSettings: Codable, Equatable, Sendable {
    public var hotKeyKeyCode: UInt32            // 46 (kVK_ANSI_M)
    public var hotKeyModifiers: UInt32          // 4352 = Carbon controlKey (4096) | cmdKey (256)
    public var openAtLogin: Bool                // true
    public var stickerPolicy: StickerPolicy     // .automatic
    public var groupFaces: Bool?                // nil = not asked yet
    public var watchedFolders: [String]         // standardized paths
    public var collectingPausedUntil: Date?
    public var webDiscoverEnabled: Bool         // true
    public var giphyAPIKey: String?             // overrides Info.plist GiphyAPIKey
    public var hasCompletedFirstRun: Bool       // false
    public var libraryOfferDismissals: Int      // 0
    public var libraryOfferAccepted: Bool       // false
    public var baseline: RestingBaseline
    public var skippedUpdateBuild: Int?         // nil; the build whose panel line got "Not now"
    public init()
}
```
Decoding uses `decodeIfPresent` with these defaults for every key.

### Update.swift

```swift
/// latest.json, the update feed CI publishes next to MemeMe.dmg in every GitHub Release.
public struct UpdateManifest: Codable, Equatable, Sendable {
    public var version: String                 // marketing version, "1.0"
    public var build: Int                      // CFBundleVersion of the release, ≥ 1
    public var downloadURL: URL                // the release's MemeMe.dmg (tag-specific URL, not /latest/)
    public var sha256: String                  // lowercase hex of the DMG (decode lowercases it)
    public var size: Int?                      // bytes of the DMG
    public var minimumSystemVersion: String?   // "14.0"
    public var notes: [String]                 // one line per change, newest first; [] when missing
    public var releasePageURL: URL?
    public var publishedAt: Date?              // ISO 8601
    public init(version: String, build: Int, downloadURL: URL, sha256: String, size: Int? = nil,
                minimumSystemVersion: String? = nil, notes: [String] = [], releasePageURL: URL? = nil, publishedAt: Date? = nil)
    /// "1.0 (58)"
    public var displayVersion: String { get }
    /// Decodes latest.json. Throws `.malformed` for bad JSON or wrong types, `.invalid(reason)` for an empty
    /// version, build < 1, a sha256 that isn't 64 hex characters, or a size < 1.
    public static func decode(from data: Data) throws -> UpdateManifest
}

public enum UpdateManifestError: Error, Equatable, Sendable { case malformed, invalid(String) }

public enum UpdateDecision: Equatable, Sendable {
    case upToDate
    case available(UpdateManifest)
    case requiresNewerSystem(UpdateManifest)   // newer build, but this macOS is older than its minimumSystemVersion
}

public enum UpdatePolicy {
    public static let checkInterval: TimeInterval      // 6 * 3600
    public static let firstCheckDelay: TimeInterval    // 20
    public static let wakeCheckAge: TimeInterval       // 3600: after wake, check when the last check is older
    /// `.upToDate` unless manifest.build > installedBuild; then `.requiresNewerSystem` when
    /// minimumSystemVersion is set and newer than `systemVersion`, else `.available`.
    public static func decide(installedBuild: Int, manifest: UpdateManifest, systemVersion: OperatingSystemVersion) -> UpdateDecision
    /// Dotted numeric comparison ("14.0" < "14.2.1"); missing parts count as 0, non-numeric parts as 0.
    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult
    public static func isSystem(_ system: OperatingSystemVersion, atLeast minimum: String) -> Bool
    /// HTTPS, no user/password, host exactly "github.com" or ending in ".githubusercontent.com" (case-insensitive).
    public static func isTrustedDownloadURL(_ url: URL) -> Bool
    /// Exactly 64 characters 0-9a-f (lowercase).
    public static func isValidSHA256(_ hex: String) -> Bool
    /// The panel line shows unless this build was dismissed with "Not now".
    public static func shouldOfferInPanel(_ manifest: UpdateManifest, skippedBuild: Int?) -> Bool
}
```

### LibraryStore.swift

```swift
public final class LibraryStore {
    public let rootURL: URL
    public private(set) var items: [LibraryItem]
    public private(set) var people: [Person]
    public var recents: RecentStore { get set }      // setting marks dirty
    public var settings: AppSettings { get set }     // setting marks dirty
    public private(set) var isDirty: Bool
    public init(rootURL: URL) throws    // creates the directory; loads library.json, people.json, recents.json, settings.json if present; an unreadable file is renamed to *.bak and replaced by empty state
    public static func defaultRootURL() -> URL       // ~/Library/Application Support/MemeMe
    public var keptDirectory: URL { get }             // rootURL/Kept, created on access
    public var stickersDirectory: URL { get }         // rootURL/Stickers, created on access
    public func item(id: UUID) -> LibraryItem?
    public func item(atPath path: String) -> LibraryItem?
    public func contains(hash: String) -> Bool
    @discardableResult public func add(_ item: LibraryItem) -> Bool   // false (no-op) when an item with the same contentHash exists
    public func update(_ item: LibraryItem)                           // replaces by id
    public func remove(ids: Set<UUID>)                                 // deletes files only when they are inside rootURL; also removes from recents
    public func upsert(_ person: Person)
    public func removePerson(id: UUID)                                 // clears personID on its items
    public func stickerCount(personID: UUID) -> Int
    public func save() throws                                          // atomic JSON writes (sorted keys, ISO-8601 dates); clears isDirty
}
```
Not thread-safe: used from the main actor only.

---

## MemeMeApp (internal API)

### Vision/FaceFeatureExtractor.swift

```swift
enum FaceFeatureExtractor {
    /// nil when the observation has no landmarks.
    static func features(from face: VNFaceObservation) -> FaceFeatures?
    static func pose(from body: VNHumanBodyPoseObservation?) -> PoseFeatures
    /// Vision-normalized image rects (origin bottom-left) for .eyes (union of both eyes) and .mouth (outer lips), padded 25 %; .brows (union of brows).
    static func regionRects(from face: VNFaceObservation) -> [FaceRegion: CGRect]
}
```
Mapping (landmark `normalizedPoints` are relative to the face bounding box, origin bottom-left):
- eye ratio = (maxY − minY) / (maxX − minX) per eye, averaged → `eyeOpenness = clamp((ratio − 0.05) / 0.5)`.
- brow gap = mean(y of both brows) − mean(y of both eyes) → `browRaise = clamp((gap − 0.02) / 0.2)`.
- `mouthOpenness = clamp(innerLipsHeight / 0.25)`; `mouthWidth = clamp((outerLipsWidth − 0.2) / 0.5)`.
- smile: corners = leftmost and rightmost outer-lip points; `s = (mean corner y − mean outer-lip y) / max(width, 0.01)`; `smile = clamp(0.5 + 2.5·s)`.
- `headTilt = clamp(|roll| / (π/4))` (`face.roll?.doubleValue ?? 0`).
- gaze: per eye `(pupil.x − eyeCenter.x) / eyeWidth`, averaged → `gazeSide = clamp(|offset| · 3)`; 0.1 when pupils are missing.
- pose: joints with confidence ≥ 0.3. `bodyVisible` = mean shoulder confidence (0 if missing). `handsRaised` = max over wrists of (wrist above shoulder line → 1, within 0.6·shoulderWidth of the nose → 0.8, else 0). `armsSpread = clamp((|lw.x − rw.x| / shoulderWidth − 1) / 1.5)`.

### Vision/ImageAnalyzer.swift

```swift
struct LoadedImage {
    let cgImage: CGImage          // representative frame (first)
    let frames: [CGImage]         // up to 3 frames for animated images (first, middle, 3/4), else [cgImage]
    let isAnimated: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let isCameraPhoto: Bool
    let isScreenshot: Bool
    let data: Data
}

struct ImageAnalysis {
    var face: FaceFeatures?
    var pose: PoseFeatures?
    var intensity: Double
    var featurePrint: [Float]?
    var featurePrintRevision: Int
    var text: String
    var labels: [String]
    var facts: ImageFacts
    var contentHash: String
    var faceBoxes: [CGRect]        // Vision-normalized boxes of all faces in the chosen frame
    var chosenFrame: CGImage
}

enum ImageAnalyzer {
    static var featurePrintRevision: Int { get }   // VNGenerateImageFeaturePrintRequest revision used everywhere
    static func load(url: URL) -> LoadedImage?      // ImageIO; nil if not an image or > 25 MB
    /// Synchronous; never call on the main thread. For animated images analyzes up to 3 frames and keeps the most intense.
    static func analyze(url: URL, includeText: Bool = true) throws -> ImageAnalysis
    static func analyze(_ image: LoadedImage, includeText: Bool = true) throws -> ImageAnalysis
    static func featurePrint(of cgImage: CGImage) throws -> [Float]
    static func sha256Hex(_ data: Data) -> String
    /// kMDItemWhereFroms host, e.g. "reddit.com", if any.
    static func downloadedFromHost(url: URL) -> String?
}
```
Requests per frame: `VNDetectFaceLandmarksRequest`, `VNDetectHumanBodyPoseRequest`; per image once: `VNGenerateImageFeaturePrintRequest`, `VNClassifyImageRequest` (top labels with confidence ≥ 0.3, at most 8), `VNRecognizeTextRequest` (`.fast`, no language correction, joined, ≤ 200 chars) when `includeText`. Intensity uses `RestingBaseline()` (population neutral).

### Vision/ThumbnailCache.swift

```swift
@MainActor final class ThumbnailCache {
    static let shared: ThumbnailCache
    func cached(_ url: URL, minPixel: Int = 256) -> NSImage?   // nil unless an entry decoded at >= minPixel exists
    /// CGImageSourceCreateThumbnailAtIndex off the main actor; NSCache (≈300 entries).
    func thumbnail(for url: URL, maxPixel: Int = 256) async -> NSImage?
}
```

### Camera/CameraController.swift

```swift
@MainActor final class CameraController: NSObject, ObservableObject {
    @Published private(set) var authorization: AVAuthorizationStatus
    @Published private(set) var isRunning: Bool
    @Published private(set) var faceVisible: Bool
    @Published private(set) var regionRects: [FaceRegion: CGRect]   // latest face, Vision-normalized image coordinates
    let session: AVCaptureSession
    var onSample: ((ExpressionSample) -> Void)?   // delivered on the main actor, ≤ 10 per second
    var isInUseByAnotherApplication: Bool { get } // the device start() would use
    var hasUsableCamera: Bool { get }             // false when no connected, unsuspended camera exists
    func refreshAuthorization()
    func requestAccess() async -> Bool
    func start()   // no-op unless authorized; lazily configures (front/default camera, .vga640x480 or .medium preset, BGRA output, alwaysDiscardsLateVideoFrames); startRunning on a private serial queue
    func stop()    // stopRunning on the private queue; clears faceVisible and regionRects
}
```
Frames: `AVCaptureVideoDataOutputSampleBufferDelegate` on a private queue, throttled to 10 fps; per frame `VNDetectFaceLandmarksRequest` (+ `VNDetectHumanBodyPoseRequest` every other frame, reusing the last pose), `VNImageRequestHandler(cvPixelBuffer:orientation: .up)`. Sample timestamp `CACurrentMediaTime()`; sharpness `1`.

### Camera/CameraPreviewView.swift

```swift
struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    var regionRects: [FaceRegion: CGRect]   // Vision-normalized image coordinates
    var pins: Set<FaceRegion>
    var onToggle: (FaceRegion) -> Void      // only .eyes and .mouth are clickable
}
```
`AVCaptureVideoPreviewLayer` (aspect fill, mirrored via `connection.automaticallyAdjustsVideoMirroring = false; isVideoMirrored = true`). Overlays for .eyes and .mouth converted with `layerRectConverted(fromMetadataOutputRect:)` from the metadata rect `(x, 1 − y − h, w, h)`. Pinned regions: amber `#F5C451` fill at 45 % opacity. While the pointer is inside (NSTrackingArea), unpinned regions show a dashed white outline. Clicks inside a region call `onToggle`.

### Library/FolderWatcher.swift

```swift
final class FolderWatcher {
    init?(url: URL, onChange: @escaping () -> Void)   // DispatchSource file-system object (.write, .rename, .delete) on an O_EVTONLY descriptor; onChange delivered on the main queue, coalesced 1 s
    func cancel()
}
```

### Library/LibraryIndexer.swift

```swift
struct IndexBatch: Identifiable, Equatable {
    let id: UUID
    var addedIDs: [UUID]
    var skipped: Int
    var duplicates: Int
    var sources: [String]
}

@MainActor final class LibraryIndexer: ObservableObject {
    @Published private(set) var isIndexing: Bool
    @Published private(set) var progressCount: Int          // memes added in the running scan
    @Published private(set) var pendingSummary: IndexBatch?   // set when a folder scan finishes; AppModel clears it after showing
    var onLibraryChanged: (() -> Void)?
    init(store: LibraryStore)
    func defaultFolders() -> [URL]           // Downloads, Desktop, screenshot location (if different); standardized, deduped
    func startWatching()                      // watchers for store.settings.watchedFolders + incremental scan
    func stopWatching()
    func addWatchedFolders(_ urls: [URL])     // persist, watch, scan newest first
    func removeWatchedFolder(_ url: URL)
    func isWatching(_ url: URL) -> Bool
    /// Hand-ins (menu-bar drop / Keep it): copies files into store.keptDirectory (http(s) URLs are downloaded first), analyzes, adds as .mine with source "Kept".
    func keep(urls: [URL], source: String) async -> IndexBatch
    func undo(_ batch: IndexBatch)
    func pauseCollecting(for interval: TimeInterval)
    func resumeCollecting()
    func clearPendingSummary()
}
```
Scanning: top-level files only; skip hidden files, non-images (UTType conforming to `.image`), files > 25 MB, files already indexed with the same path + modification date + size. Analyze at most 2 at a time at utility priority; pause while `SystemConditions.shouldDeferBackgroundWork`. Item fields: `kind .mine`, `tier` from `MemeTierClassifier`, `source` = folder display name ("Downloads", "Desktop", "Screenshots" for the screenshot folder, else the folder name), `sourceDetail` = "from <host>" via `downloadedFromHost`. Skipped-tier items keep only path, hash, dates, facts-derived tier (no face, fingerprint, text, labels). Save the store at most every 5 s while indexing and at the end.

### System/SystemConditions.swift

```swift
enum SystemConditions {
    static var shouldDeferBackgroundWork: Bool { get }   // Low Power Mode or thermal state ≥ .serious
    static var isOnExpensiveNetwork: Bool { get }        // from a shared NWPathMonitor (isExpensive || isConstrained); false until known
    static func startMonitoring()                        // idempotent
}
```

### Web/GIFProvider.swift, Web/GiphyProvider.swift

```swift
struct WebGIF: Codable, Hashable {
    let id: String
    let title: String
    let stillURL: URL        // GIPHY images.fixed_width_small_still.url (fallback fixed_width_still)
    let previewURL: URL?     // images.fixed_width_small.url (animated, small)
    let fullURL: URL         // images.downsized.url (≤ 2 MB), fallback original
    let width: Int
    let height: Int
    let pageURL: URL?
    let provider: String     // "GIPHY"
}

protocol GIFProvider: Sendable {
    var name: String { get }
    func search(_ query: String, limit: Int) async throws -> [WebGIF]
}

struct GiphyProvider: GIFProvider {
    init(apiKey: String, rating: String = "pg-13", session: URLSession = .shared)
    var name: String { get }   // "GIPHY"
    func search(_ query: String, limit: Int) async throws -> [WebGIF]
    // GET https://api.giphy.com/v1/gifs/search?api_key=&q=&limit=&offset=0&rating=&lang=en ; decode data[] leniently (numbers arrive as strings); skip entries without the needed renditions.
}
```

### Web/WebDiscover.swift

```swift
@MainActor final class WebDiscover: ObservableObject {
    @Published private(set) var isFetching: Bool
    init(store: LibraryStore)
    var isAvailable: Bool { get }                    // settings.webDiscoverEnabled && an API key exists && under the rate limit
    /// Instant: analyzed items for the mood if cached and fresh (24 h), else [].
    func cachedItems(for mood: Mood) -> [LibraryItem]
    /// Cache first; otherwise search + download stills in parallel + analyze off-main. Returns [] on timeout/error (the fetch continues in the background and fills the cache).
    func items(for mood: Mood, timeout: TimeInterval = 1.5) async -> [LibraryItem]
    /// Background warm-up for moods not cached; skipped on expensive networks or when SystemConditions.shouldDeferBackgroundWork.
    func prefetch(_ moods: [Mood])
    /// Local animated preview file for a web item (downloads previewURL once), nil for non-web items.
    func localPreview(for item: LibraryItem) async -> URL?
    /// Downloads remoteURL (if needed) and returns the local GIF file to copy. Times out after 8 s.
    func prepareForCopy(_ item: LibraryItem) async -> URL?
    func prefetchForCopy(_ items: [LibraryItem])
    func pruneCache()                                 // 24 h TTL, LRU to 50 MB
}
```
Web items: `kind .web`, `tier .meme`, `source "GIPHY"`, `attribution "via GIPHY"`, `isAnimated true`, `fileURL` = cached still, `remoteURL` = full, `previewURL` = preview, `contentHash "giphy:<id>"`, a stable `id` derived from the hash (first 16 bytes of SHA-256 of "giphy:<id>" → UUID). API key: `store.settings.giphyAPIKey` (non-empty) ?? `Bundle.main.object(forInfoDictionaryKey: "GiphyAPIKey") as? String` (non-empty and not starting with "$("). Cache: `~/Library/Caches/MemeMe/Web/<mood>.json` (fetchedAt + items) and `Web/files/<id>-still.<ext>`, `-preview.gif`, `-full.gif`. Rate guard: at most 90 network searches per rolling hour (timestamps persisted in the cache directory).

### Stickers/StickerMaker.swift

```swift
struct StickerCut {
    let pngURL: URL
    let faceEmbedding: [Float]     // feature print of the face crop (box expanded 20 %)
    let face: FaceFeatures?
    let intensity: Double
    let featurePrint: [Float]?     // feature print of the sticker image
    let contentHash: String
    let faceBox: CGRect            // Vision-normalized box in the source photo
}

enum StickerMaker {
    /// Facts + Vision-normalized boxes of eligible faces (StickerEligibility). Empty faces → not a photo of people.
    static func eligibleFaces(in url: URL) throws -> (facts: ImageFacts, faces: [CGRect])
    /// macOS 14 subject lifting (VNGenerateForegroundInstanceMaskRequest): one sticker per person instance that contains an eligible face; white die-cut outline (radius ≈ 2.5 % of the longer side, ≥ 6 px); scaled to ≤ 512 px; PNG files written into `directory`.
    static func makeStickers(from url: URL, into directory: URL, faces: [CGRect], outline: Bool = true) throws -> [StickerCut]
}
```

### Stickers/FriendService.swift

```swift
struct MadeSticker: Identifiable, Equatable {
    let id: UUID              // the sticker's LibraryItem id
    var fileURL: URL
    var match: PersonMatch
    var personName: String?   // for .confident / .likely
    var removed: Bool
}

struct StickerBatch: Identifiable, Equatable {
    let id: UUID
    let sourceURL: URL
    var stickers: [MadeSticker]
    var skippedFaces: Int     // detected faces below the size threshold
    var undone: Bool
}

@MainActor final class FriendService: ObservableObject {
    init(store: LibraryStore)
    var needsGroupingConsent: Bool { get }          // store.settings.groupFaces == nil
    /// nil when the file isn't a photo of people (caller keeps it as a meme) or the policy is .never.
    func process(photo url: URL) async throws -> StickerBatch?
    /// Persists consent. When enabled, matches the batch's stickers (and earlier unmatched stickers) and returns the updated batch.
    func setGrouping(_ enabled: Bool, batch: StickerBatch?) -> StickerBatch?
    func confirm(stickerID: UUID, personID: UUID, in batch: StickerBatch) -> StickerBatch
    func toggleRemoved(stickerID: UUID, in batch: StickerBatch) -> StickerBatch   // removing deletes the item+file; restoring re-adds it
    func undo(_ batch: StickerBatch) -> StickerBatch                               // removes all of the batch's stickers
    func unnamedPeople(limit: Int) -> [(person: Person, stickerCount: Int, sample: LibraryItem?)]
    func name(personID: UUID, as name: String)
    func forget(personID: UUID)                                                     // removes the person's embeddings and unlinks stickers
}
```
Sticker items: `kind .friend`, `isSticker true`, `source "Friend sticker"`, `sourceDetail` = source file name, `displayName` = person name (or "New face") + " — " + mood label of its face, `tier .meme`. Matching only runs when `groupFaces == true`: `.confident` → set `personID` and add the embedding; `.likely` → leave `personID` nil until `confirm`; `.newFace` → create an unnamed `Person` with the embedding and assign it.

### System/Clipboard.swift

```swift
enum Clipboard {
    /// Writes a pasteable representation of `fileURL` for `item`; returns the pasteboard changeCount after writing.
    @MainActor @discardableResult static func copy(fileURL: URL, item: LibraryItem) throws -> Int
    @MainActor static var lastWriteChangeCount: Int { get }
    /// When the pasteboard holds an image (or image file) that MemeMe didn't write, returns a local file URL (temp copy for raw image data).
    @MainActor static func imageOnPasteboard() -> URL?
    static func dragItemProvider(for item: LibraryItem, fileURL: URL) -> NSItemProvider
    static func neutralFileName(for item: LibraryItem) -> String   // own items keep their file name; else "reaction.gif" / "sticker.png" / "reaction.png"
}
```
Copy writes one `NSPasteboardItem` with `.fileURL` of a temp copy named by `neutralFileName` (in `~/Library/Caches/MemeMe/Clipboard/<uuid>/`), plus `com.compuserve.gif` data for GIFs, or `.png` data (converted with ImageIO) for stills; temp copies older than 1 h are deleted on each copy.

### UI/Theme.swift

```swift
enum Theme {
    static let panelWidth: CGFloat          // 640
    static let background: Color            // #1E1F24
    static let surface: Color               // #26282E
    static let border: Color                // #3A3C44
    static let text: Color                  // #ECECEF
    static let mutedText: Color             // #A9ACB5
    static let accent: Color                // #7AA2FF
    static let amber: Color                 // #F5C451
    static let green: Color                 // #5FD38D
    static let columns: Int                 // 5
    static let rows: Int                    // 2
    static var resultLimit: Int { get }     // columns * rows
}
```

### UI/PanelController.swift

```swift
@MainActor final class PanelController: NSObject {
    init(model: AppModel)
    var isVisible: Bool { get }
    func toggle()
    func show(centered: Bool = false)   // captures NSWorkspace.shared.frontmostApplication before showing; calls model.panelWillShow; non-activating NSPanel; top-center under the menu bar (or centered on screen when `centered`)
    func hide()                         // orders out, calls model.panelDidHide, reactivates the previous app if it is no longer frontmost
}
```
NSPanel subclass: `styleMask [.borderless, .nonactivatingPanel]`, `canBecomeKey true`, `canBecomeMain false`, `isFloatingPanel true`, `level .floating`, `collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]`, `hidesOnDeactivate false`, `backgroundColor .clear`, `hasShadow true`, `sharingType .none`. Hosting: `NSHostingView(rootView: PanelView(model:))`, sized to fit (width 640). While visible: a local key-down monitor (keys in DESIGN.md: Esc, ↵/Enter, digits 1–9 as typed on the active keyboard layout, arrows, Space with empty query, Tab / Shift-Tab, ⌘V) and a global mouse-down monitor (outside click → hide). `model.onRequestClose = { [weak self] in self?.hide() }`.

Key handling:
- Esc → `if !model.handleEscape() { hide() }`
- ↵ / Enter → `model.commitFocused()`
- digits 1–9 as typed on the active keyboard layout (main row or keypad; Shift allowed, no ⌘/⌃/⌥; 0 is swallowed) → `model.commit(index: n - 1)`
- ←/→ → `model.moveFocus(dx: ∓1, dy: 0)` only when `model.queryText` is empty; ↑/↓ → `model.moveFocus(dx: 0, dy: ∓1)`
- Space with empty query → `model.snap()`
- Tab → `model.moreLikeFocused()`; Shift-Tab → `model.backToFace()`
- ⌘V → consume only if `model.pasteFromClipboard()` returns true
- everything else passes through to the focused search field.

### UI/PanelView.swift and subviews

```swift
struct PanelView: View { @ObservedObject var model: AppModel }                       // compact layout per DESIGN.md
struct MirrorColumn: View { @ObservedObject var model: AppModel }                    // mirror (CameraPreviewView / silhouette / image / drop well) + hint
struct ResultGrid: View { @ObservedObject var model: AppModel }                      // 5 × 2 LazyVGrid of ResultTile
struct ResultTile: View { let result: RankedResult; let number: Int?; let isFocused: Bool; let isNew: Bool; @ObservedObject var model: AppModel }
struct FooterView: View { @ObservedObject var model: AppModel }
struct SetupCardView: View { @ObservedObject var model: AppModel }
struct AnimatedImageView: NSViewRepresentable { let url: URL }                       // NSImageView with animates = true
```
- The search field is a SwiftUI `TextField` bound to `$model.queryText`, focused on appear (`@FocusState`), plain style.
- Drops on the whole panel: `.onDrop(of: [.fileURL, .image], …)` → `model.search(withImageAt:)`.
- Tiles: `.onHover { if $0 { model.hover(index:) } }`, `.onTapGesture { model.commit(index:) }`, `.onDrag { model.dragItemProvider(index:) ?? NSItemProvider() }`.
- Thumbnails via `ThumbnailCache.shared`; the focused GIF tile shows `AnimatedImageView` (local file, or `await model.web.localPreview(for:)` for web items).

### UI/HUDController.swift

```swift
@MainActor final class HUDController {
    static let shared: HUDController
    /// Pill at the top center of the main screen for 1.6 s (or until replaced). Optional 28 px thumbnail.
    func show(_ message: String, thumbnail: URL? = nil)
}
```

### UI/StickerPopoverView.swift

```swift
struct StickerPopoverView: View { @ObservedObject var model: StickerPopoverModel }
```

### App/StickerPopoverModel.swift

```swift
@MainActor final class StickerPopoverModel: ObservableObject {
    @Published var stickerBatch: StickerBatch?
    @Published var keptBatch: IndexBatch?
    @Published private(set) var askGrouping: Bool
    let friends: FriendService
    let indexer: LibraryIndexer
    var onClose: (() -> Void)?
    init(friends: FriendService, indexer: LibraryIndexer)
    func present(stickers: StickerBatch)
    func present(kept: IndexBatch)
    func groupYes()
    func groupNo()
    func confirm(stickerID: UUID, personID: UUID)
    func toggle(stickerID: UUID)
    func undoAll()
    func keepAsPhotoOnly()     // undoes the stickers and keeps the photo as a normal (maybe-tier) item via indexer.keep
    func undoKept()
    func close()
    var store: LibraryStore?                    // set by AppDelegate; "Keep as photo only" files the photo as maybe-tier
    func dismissGroupingQuestionIfUnanswered()  // called when the popover closes, so the grouping question is asked once
}
```

### Update/UpdateInstaller.swift

```swift
/// The mechanics of one update: download and verify, stage from the DMG, relaunch. No UI.
struct UpdateInstaller {
    enum Failure: Error, Equatable {
        case untrustedURL, downloadFailed(String), sizeMismatch, checksumMismatch
        case mountFailed(String), appNotFound, wrongBundle(String), signatureInvalid
        case notReplaceable, stagingFailed(String), relaunchFailed(String)
        /// size/checksum/host/bundle/signature problems: the DMG must not be opened.
        var isVerificationFailure: Bool { get }
    }
    var session: URLSession                     // .shared
    var updatesDirectory: URL                   // ~/Library/Caches/MemeMe/Updates
    init(session: URLSession = .shared, updatesDirectory: URL = UpdateInstaller.defaultUpdatesDirectory())
    static func defaultUpdatesDirectory() -> URL
    /// Downloads to updatesDirectory/<build>/MemeMe.dmg (replacing an older file) and checks the host before
    /// and after redirects, HTTP 200, the size (when given) and the SHA-256. Returns the DMG's URL.
    func download(_ manifest: UpdateManifest) async throws -> URL
    /// SHA-256 of a file as lowercase hex, read in 1 MB chunks (CryptoKit).
    static func sha256(ofFileAt url: URL) throws -> String
    /// Throws `.wrongBundle` unless the bundle's Info.plist has this CFBundleIdentifier and exactly this CFBundleVersion.
    static func validateBundle(at appURL: URL, bundleIdentifier: String, build: Int) throws
    /// True for a ".app" directory that isn't under /AppTranslocation/, isn't on a read-only volume and whose
    /// parent folder is writable.
    static func canReplace(appAt url: URL) -> Bool
    /// The staged bundle's location: a hidden sibling, `<parent>/.MemeMe-update-<build>.app`.
    static func stagedURL(for currentApp: URL, build: Int) -> URL
    /// Mounts the DMG read-only (hdiutil attach -nobrowse -readonly -noautoopen -mountpoint), finds the .app
    /// (MemeMe.app first), validates it, checks `codesign --verify --deep --strict`, copies it with `ditto` to
    /// `stagedURL(for:build:)`, and always detaches. Runs the tools off the main actor.
    func stage(dmg: URL, manifest: UpdateManifest, currentApp: URL, bundleIdentifier: String) async throws -> URL
    /// The relaunch script (POSIX sh). Arguments: $1 pid, $2 current app, $3 staged app, $4 open command.
    /// Waits up to 30 s for the pid to exit, moves current aside, moves staged into place (restoring current if
    /// that fails), deletes the old copy, then runs `$4 "$2"`. Paths are never interpolated into the text.
    static let relaunchScript: String
    /// Writes `relaunchScript` to a temporary file and starts `/bin/sh <file> pid current staged openCommand`
    /// detached (no waiting, output to /dev/null).
    func launchRelauncher(pid: Int32, current: URL, staged: URL, openCommand: String = "/usr/bin/open") throws
    /// Deletes updatesDirectory and `.MemeMe-update-*.app` leftovers next to `currentApp`. Never throws.
    func cleanUp(currentApp: URL)
}
```

### Update/UpdateChecker.swift

```swift
/// Checks the feed, publishes what's available and runs the one-click update (DESIGN.md › Updates).
@MainActor final class UpdateChecker: ObservableObject {
    enum Phase: Equatable { case idle, checking, downloading, installing }
    @Published private(set) var available: UpdateManifest?   // a newer build this Mac can run; nil otherwise
    @Published private(set) var phase: Phase                  // .idle
    let feedURL: URL?                                         // nil = updates off (no checks, no UI)
    let installedVersion: String                              // CFBundleShortVersionString, "0" when missing
    let installedBuild: Int                                   // CFBundleVersion, 0 when missing or not a number
    var isEnabled: Bool { get }                               // feedURL != nil
    var installedDisplayVersion: String { get }               // "1.0 (57)"
    /// Reads MemeMeUpdateFeedURL (empty or invalid = nil), CFBundleShortVersionString and CFBundleVersion.
    convenience init(bundle: Bundle)
    init(feedURL: URL?, installedVersion: String, installedBuild: Int,
         session: URLSession = .shared, installer: UpdateInstaller = UpdateInstaller(), defaults: UserDefaults = .standard)
    /// No-op when disabled. Cleans leftovers, shows "Updated to MemeMe …" once after an update (UserDefaults
    /// key "lastLaunchedBuild"), checks after 20 s, then every 6 h, and after wake when the last check is > 1 h old.
    func start()
    /// One request (no cache, 15 s timeout). Sets `available`; returns nil and changes nothing when the request,
    /// the HTTP status, the JSON or the download URL's host fails. Never shows UI.
    @discardableResult func check() async -> UpdateDecision?
    /// "Check for Updates…": runs `check()` and answers in an alert (DESIGN.md strings).
    func checkFromMenu()
    /// Download, verify, stage, relaunch; the fallbacks and alerts from DESIGN.md. Ignored unless an update is
    /// available and phase is .idle or .checking (a background check doesn't block the footer's Update button).
    func installAvailableUpdate()
    /// Runs when an install starts, from every Update path; AppModel closes the panel here.
    var willInstall: (@MainActor () -> Void)?
}
```

### App/StatusItemController.swift (updates)

- Observes `model.updates.$available`: the icon is `face.smiling` with a small dot when an update is available (one template image, so it follows the menu bar's color).
- Menu: with an update, the first item is "Update to MemeMe <displayVersion>…" (→ `model.installUpdate()`), or "Updating MemeMe…" disabled while `phase` is `.downloading`/`.installing`, then a separator. When `model.updates.isEnabled`, a section before Quit: "Check for Updates…" (→ `model.updates.checkFromMenu()`) and a disabled "Version <installedDisplayVersion>".

### App/AppModel.swift

```swift
enum PanelMode: Equatable { case prompt, warming, live, text, image, moreLike, cameraOff, cameraBusy }
enum HintAction: Equatable { case clearPins, backToFace, keepImage, turnOnCamera, useCamera }
struct PanelHint: Equatable { var title: String; var subtitle: String?; var actionTitle: String?; var action: HintAction? }
enum FooterState: Equatable { case legend, libraryOffer, indexing(count: Int), added(IndexBatch), update(UpdateManifest) }
struct NamingCandidate: Identifiable, Equatable { let personID: UUID; let stickerCount: Int; let sample: LibraryItem?; var id: UUID { personID } }
struct NamingPrompt: Equatable { var name: String; var candidates: [NamingCandidate] }
enum DropOutcome { case kept(IndexBatch), stickers(StickerBatch), nothing }

@MainActor final class AppModel: ObservableObject {
    @Published var queryText: String
    @Published private(set) var mode: PanelMode
    @Published private(set) var results: [RankedResult]        // ≤ Theme.resultLimit
    @Published private(set) var newResultIDs: Set<UUID>         // amber ring for 600 ms
    @Published var focusedIndex: Int
    @Published private(set) var pins: Set<FaceRegion>
    @Published private(set) var hint: PanelHint
    @Published private(set) var footer: FooterState
    @Published private(set) var showSetupCard: Bool
    @Published private(set) var queryImageURL: URL?             // image / moreLike mirror content
    @Published private(set) var moreLikeItem: LibraryItem?
    @Published private(set) var imageKept: Bool
    @Published private(set) var showsFaceToken: Bool
    @Published private(set) var naming: NamingPrompt?
    @Published private(set) var holdProgress: Double
    @Published private(set) var hotKeyAvailable: Bool
    @Published private(set) var isPanelVisible: Bool

    let store: LibraryStore
    let camera: CameraController
    let indexer: LibraryIndexer
    let web: WebDiscover
    let friends: FriendService
    let updates: UpdateChecker                       // UpdateChecker(bundle: .main); disabled in tests (no feed URL)

    var onRequestClose: (() -> Void)?

    init(store: LibraryStore)
    init(store: LibraryStore, webCacheRoot: URL?)   // tests pass a temp cache folder
    var requestsCameraAccessOnShow: Bool             // default true; tests turn it off
    func start()                                     // after launch: indexer.startWatching(), web.prefetch(Mood.prefetchOrder), SystemConditions.startMonitoring(), updates.start()
    func setHotKeyAvailable(_ available: Bool)

    // Panel lifecycle
    func panelWillShow(previousApp: NSRunningApplication?)
    func panelDidHide()

    // Input
    func commit(index: Int)
    func commitFocused()
    func moveFocus(dx: Int, dy: Int)
    func hover(index: Int)
    func togglePin(_ region: FaceRegion)
    func handleEscape() -> Bool
    func snap()
    func moreLikeFocused()
    func backToFace()
    func search(withImageAt url: URL)
    func pasteFromClipboard() -> Bool
    func performHintAction()
    func removeFaceToken()
    func dragItemProvider(index: Int) -> NSItemProvider?
    func nameUnknownFace(personID: UUID)

    // Library
    func findMyMemes()
    func dismissLibraryOffer()
    func undoAddedBatch()
    func toggleOpenAtLogin()
    func dismissSetupCard()

    // Updates
    func installUpdate()          // updates.installAvailableUpdate(); init sets updates.willInstall to close the panel (onRequestClose)
    func dismissUpdateOffer()     // "Not now": settings.skippedUpdateBuild = available build; footer refreshes; saveSoon()

    // Menu-bar drops
    func handleMenuBarDrop(urls: [URL]) async -> DropOutcome

    // Persistence & menu helpers (internal extras)
    func saveSoon()
    func saveNow()
    func forgetRestingFace()
}
```
Other internal helpers that exist outside the contract: `StickerBatchSources` (App/StickerPopoverModel.swift) and `TileDragEvents` (UI/PanelController.swift).
Behavior summary (details in DESIGN.md):
- `panelWillShow`: remember previous app + bundle id; reset query state; mode = `.cameraBusy` if `camera.isInUseByAnotherApplication`, `.prompt` if authorization is `.notDetermined`, `.cameraOff` if denied/restricted, else `.warming` (start camera); results = recent for that app (or GIPHY `reaction` cached items / newest own memes); footer per rules; on first run (`!settings.hasCompletedFirstRun`) request camera access 0.6 s after show (activate the app just for the prompt).
- `camera.onSample` → `tracker.ingest`; publish `holdProgress`; on query change: mood → weights (`automatic(...).pinning(pins)`) → local rank immediately → web `cachedItems` merged → `web.items(for:)` merged later via `ResultMerger` with `lockedCount = max(strongOwnPrefix, focusedIndex + 1)`; `newResultIDs` for ids not shown before (cleared after 600 ms); `web.prefetchForCopy(top 3)`. No face for 1.5 s → hint "Can’t see your face".
- Text changes (debounced 80 ms) → text mode; camera stops if typing began within 1 s of show, otherwise `showsFaceToken = true`; naming prompt when `TextQuery.possibleName` is set, no results, and `friends.unnamedPeople` is non-empty. Empty text → back to live (restart camera if it was stopped).
- `commit`: resolve file (web → `await web.prepareForCopy`, HUD "Copying…" if it takes > 150 ms); `Clipboard.copy`; increment `timesSent`, set `lastSentAt`, `recents.record`; first run → `showSetupCard = true` and `hasCompletedFirstRun = true` (panel stays open); otherwise close and HUD "Copied “<displayName>” · ⌘V — not sent". ↵ is ignored within 300 ms of the last text edit.
- Persist the store (debounced 2 s) after changes; persist `tracker.baseline` into settings on hide.
- Footer priority: `.indexing` > `.added` (panel visible) > `.update(manifest)` (when `updates.available` is set, `updates.phase` is `.idle` or `.checking` and `UpdatePolicy.shouldOfferInPanel(manifest, skippedBuild: settings.skippedUpdateBuild)`) > `.libraryOffer` > `.legend`. AppModel subscribes to `updates.objectWillChange` like it does to the indexer and refreshes the footer on the next main-actor turn.
