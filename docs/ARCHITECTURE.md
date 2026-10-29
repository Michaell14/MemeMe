# MemeMe — architecture & code contract

This file is the contract between source files. **Signatures below are binding**: implement them exactly (names, labels, types, optionality, `async`/`throws`, actor isolation). You may add private helpers and extra `private`/`fileprivate` members freely. If you need a cross-file change, do not edit another owner's file; report it.

Read `docs/DESIGN.md` for behavior and exact UI strings.

## Build setup

- Swift Package (`Package.swift`, tools 5.9, **Swift 5 language mode**), `platforms: [.macOS(.v14)]`. No third-party dependencies.
- Targets:
  - `MemeMeCore` — library, **Foundation only** (no AppKit/Vision/Accelerate/CryptoKit; CoreGraphics only for `CGPoint` in `FaceShapeMeasure`, imported under `#if canImport(CoreGraphics)` so Linux takes Foundation's). Must also compile on Linux. Everything is `public`.
  - `MemeMeApp` — executable (product name `MemeMe`). AppKit + SwiftUI + AVFoundation + Vision + CoreImage + ImageIO + CryptoKit + Carbon + ServiceManagement + UniformTypeIdentifiers + Network. Types are `internal`.
  - `MemeMeCoreTests` — XCTest for the core.
  - `MemeMeAppTests` — XCTest for the app target (`@testable import MemeMeApp`): GIPHY decoding via a URLProtocol stub, GIPHY search against a stub GIPHY (GIPHY's order kept, 24 asked for, pages, nothing written to disk, copies, early search, refusals), ImageAnalyzer on generated images, the seven features in the face's leveled frame and reading a frame's pixels (FaceFeatureExtractor), clipboard naming, keep/undo, sticker eligibility, headless AppModel text search.
- `scripts/build-app.sh` assembles `build/MemeMe.app` (Info.plist from `Resources/Info.plist`; `GiphyAPIKey` from `$GIPHY_API_KEY`; `CFBundleShortVersionString` from `$APP_VERSION`, default the `VERSION` file; `CFBundleVersion` from `$APP_BUILD`, default `git rev-list --count HEAD`; `MemeMeUpdateFeedURL` from `$UPDATE_FEED_URL`, default empty = updates off; `Resources/AppIcon.icns` as the app icon, `CFBundleIconFile` = AppIcon, sources in `Resources/AppIcon`) and ad-hoc signs it. `scripts/build-dmg.sh` packs it into `build/MemeMe.dmg` (the app plus an `Applications` link, UDZO) with dmgbuild (`scripts/dmg-settings.py`: a 660×400 icon-view window, the app at (170, 196), Applications at (490, 196), background from `Resources/DMG`; Python 3.10+, pinned by hash), signs it on Developer ID builds, then mounts it and checks the app's signature and the link.
- CI (`.github/workflows/ci.yml`): job `build` (`macos-15`) runs `swift build`, `swift test`, both scripts and uploads `MemeMe.dmg` as the `MemeMe-app` artifact; it also decides whether this run is a release (push or manual run on the default branch, and app files changed since the last `v*` tag, or a manual run). Job `release` (`ubuntu-latest`, `contents: write`) runs `scripts/publish-release.sh`, which publishes GitHub Release `v<version>-<build>` with `MemeMe.dmg` and `latest.json` (the update feed, see `UpdateManifest`) and marks it latest.
- Logging: `os.Logger(subsystem: "com.mememe.app", category: "<file area>")`. Never log file contents, OCR text or face data.
- Concurrency: classes that publish UI state are `@MainActor`. Heavy work (Vision, ImageIO, hashing, network decoding) runs off the main actor (`Task.detached(priority: .utility)` or a private `DispatchQueue`), results hop back with `await MainActor.run` or `@MainActor` methods. Avoid `Sendable` warnings becoming errors: no `-strict-concurrency=complete`.

## File ownership

| Owner | Files |
|---|---|
| Core | `Sources/MemeMeCore/*.swift`, `Tests/MemeMeCoreTests/*.swift` |
| Vision & camera | `Sources/MemeMeApp/Vision/FaceFeatureExtractor.swift`, `Vision/ImageAnalyzer.swift`, `Vision/ThumbnailCache.swift`, `Camera/CameraController.swift`, `Camera/CameraPreviewView.swift`, `Camera/CameraFilter.swift`, `Camera/CaptureRenderer.swift` |
| Library, web, stickers | `Sources/MemeMeApp/Library/LibraryIndexer.swift`, `Library/FolderWatcher.swift`, `Web/GIFProvider.swift`, `Web/GiphyProvider.swift`, `Web/WebDiscover.swift`, `Web/MemeTemplates.swift`, `Stickers/StickerMaker.swift`, `Stickers/FriendService.swift`, `System/Clipboard.swift`, `System/SystemConditions.swift` |
| Panel UI | `Sources/MemeMeApp/UI/PanelController.swift`, `UI/PanelView.swift`, `UI/MirrorColumn.swift`, `UI/ResultGrid.swift`, `UI/FooterView.swift`, `UI/SetupCardView.swift`, `UI/HUDController.swift`, `UI/StickerPopoverView.swift`, `UI/AnimatedImageView.swift`, `UI/CaptureView.swift`, `UI/Theme.swift` |
| App shell | `Sources/MemeMeApp/App/main.swift`, `App/AppDelegate.swift`, `App/AppModel.swift`, `App/CaptureModel.swift`, `App/HotKey.swift`, `App/StatusItemController.swift`, `App/StickerPopoverModel.swift`, `App/LoginItem.swift`, `Resources/Info.plist`, `scripts/build-app.sh`, `.github/workflows/ci.yml`, `README.md`, `.gitignore` |
| Updates | `Sources/MemeMeApp/Update/UpdateChecker.swift`, `Update/UpdateInstaller.swift`, `Tests/MemeMeAppTests/UpdateCheckerTests.swift`, `Tests/MemeMeAppTests/UpdateInstallerTests.swift` |
| Release | `VERSION`, `scripts/build-dmg.sh`, `scripts/dmg-settings.py`, `scripts/dmgbuild-requirements.txt`, `scripts/render-dmg-background.cjs`, `Resources/DMG/*`, `scripts/publish-release.sh`, `scripts/build-site.sh`, `site/index.html` |

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

public struct PoseFeatures: Codable, Hashable, Sendable {   // lenient decoding: earlier versions' poses load with descriptor nil
    public var handsRaised: Double   // 0...1 wrists at/above shoulders or near the face
    public var armsSpread: Double    // 0...1 wrist span relative to shoulder width
    public var bodyVisible: Double   // 0...1 confidence that shoulders are in frame
    public var descriptor: PoseDescriptor?          // the pose in detail; nil for items analyzed before it existed
    public init(handsRaised: Double, armsSpread: Double, bodyVisible: Double, descriptor: PoseDescriptor? = nil)
    public init(joints: BodyJoints, hand: HandShape? = nil)   // all of the above from one body
    public static let none: PoseFeatures            // all 0
    public var activity: Double { get }             // max(handsRaised, armsSpread) * bodyVisible, clamped 0...1 (the old measure)
    public var gestureStrength: Double { get }      // descriptor?.gestureStrength ?? activity
    public var showsArms: Bool { get }              // descriptor?.showsArms ?? (bodyVisible > 0)
    /// 0...1; see "Pose" below.
    public static func similarity(query: PoseFeatures?, item: PoseFeatures?) -> Double
}

public struct ExpressionSample: Codable, Hashable, Sendable {
    public var face: FaceFeatures?
    public var pose: PoseFeatures?
    public var shape: FaceShape?         // the face's details beyond the seven features (FaceCues.swift); nil without
    public var timestamp: TimeInterval   // seconds, monotonic (CACurrentMediaTime on the app side)
    public var sharpness: Double         // 0...1, 1 when unknown
    public init(face: FaceFeatures?, pose: PoseFeatures? = nil, shape: FaceShape? = nil, timestamp: TimeInterval, sharpness: Double = 1)
}
```

### FaceCues.swift

```swift
/// What the seven features don't keep: each eye and brow, the lips' shape, where the mouth and pupils sit, the tongue.
/// Leveled frame (FaceShapeMeasure), lengths in eye distances; a field is nil when it couldn't be measured.
public struct FaceShape: Codable, Hashable, Sendable {   // lenient: a field that doesn't decode is nil; nil fields are left out
    public var leftEyeOpen, rightEyeOpen: Double?   // contour area / width² (≈ 0.25 open, < 0.1 shut); Vision's left and right
    public var leftBrowGap, rightBrowGap: Double?   // brow's mean height − its eye's (≈ 0.3)
    public var lipWidth, lipHeight: Double?         // outer lips (≈ 0.8 × 0.3 at rest)
    public var lipOpening: Double?                  // inner lips' height (≈ 0 closed)
    public var lowerLip: Double?                    // inner-lip bottom − outer-lip bottom: the lower lip's thickness
    public var cornerTilt: Double?                  // the left-most outer-lip point's height − the right-most one's
    public var mouthShift: Double?                  // the middle of the outer lips' width (the face's midline is x = 0); not read as a cue (a head turned with the camera above or below the eyes moves it as much)
    public var gazeUp: Double?                      // pupils' height over the line through each eye's corners, in eye widths (+ up, ≈ 0.03 ahead)
    public var tongue: Double?                      // 0...1 share of tongue-colored samples under the lower lip; nil when lips and skin can't be told apart
    public init(leftEyeOpen: Double? = nil, …, tongue: Double? = nil)   // every field, in this order
    static let fields: [WritableKeyPath<FaceShape, Double?>]            // internal: every field, this order
    func blended(toward target: FaceShape, amount: Double) -> FaceShape // internal: each field `amount` of the way; a missing one takes the target's
}

public struct FaceCues: Hashable, Sendable {
    public enum Cue: String, CaseIterable, Codable, Hashable, Sendable {
        case tongueOut, wink, raisedBrow, pucker, smirk, eyeRoll
        public var mood: Mood { get }               // .tongueOut, .wink, .raisedEyebrow, .duckFace, .smirk, .eyeRoll
    }
    public static let clear: Double                 // 0.5: names the mood and is an expression of its own
    public private(set) var values: [Double]        // one per Cue.allCases, each 0...1
    public static let none: FaceCues                // all 0
    public init(shape: FaceShape, rest: FaceShape?) // rest: the person's resting shape (camera); nil: fixed values (library images)
    public subscript(_ cue: Cue) -> Double { get }
    public var strongest: (cue: Cue, value: Double)? { get }   // above 0; the first in allCases on a tie
    public var clearCue: Cue? { get }               // strongest when ≥ clear
}

extension RestingBaseline {
    public func cues(of shape: FaceShape?) -> FaceCues   // FaceCues(shape:rest: restShape); .none without a shape
}
```
Cues (binding; clamp each to 0...1; r = rest, used per cue only when it has the fields that cue needs, else the fixed form):
- tongueOut: `(tongue − r.tongue − 0.12) / 0.25`, + 0.3 when `lowerLip ≥ 1.6 × r.lowerLip` (r.lowerLip > 0) and the tongue share grew ≥ 0.06 (a tongue over the lip thickens it); fixed `(tongue − 0.2) / 0.25`; 0 without `tongue`.
- wink: each eye's opening over its rest's; with the lower ≤ 0.55 and the higher ≥ 0.5 (a broad smile narrows the open eye too), `(higher − lower − 0.3) / 0.4` (squinting with both eyes isn't one); fixed `(ln(higher / max(lower, 0.005)) − 0.7) / 0.7`; 0 with both eyes at 0 (a blink) or an eye not measured.
- raisedBrow: `(|(leftBrowGap − rightBrowGap) − (r.left − r.right)| − 0.05) / 0.1`; fixed `(|left − right| − 0.07) / 0.1` (both brows up is surprise, not this).
- pucker (duck face, kissy lips; only with `lipOpening ≤ 0.12`): `(1 − lipWidth / r.lipWidth − 0.1) / 0.15`; fixed `(0.7 − lipWidth) / 0.15` when `lipHeight / lipWidth ≥ 0.4`.
- smirk (one corner up): `(|cornerTilt − r| − 0.05) / 0.1`; fixed `(|cornerTilt| − 0.07) / 0.1`.
- eyeRoll: `(gazeUp − r.gazeUp − 0.04) / 0.05`, 0 when either eye is open less than 0.8 of its rest (a squint or a frown isn't one); fixed `(gazeUp − 0.07) / 0.05`.

### FaceShapeMeasure.swift

```swift
public enum FaceShapeMeasure {
    public struct Landmarks: Equatable, Sendable {  // face-box-normalized (0...1, origin bottom-left), as Vision's normalizedPoints; [] = not found
        public var leftEye, rightEye, leftBrow, rightBrow, outerLips, innerLips, leftPupil, rightPupil: [CGPoint]
        public init(leftEye: [CGPoint] = [], …, rightPupil: [CGPoint] = [])
        func map(_ transform: (CGPoint) -> CGPoint) -> Landmarks   // internal
    }
    public struct Sample: Equatable, Sendable {     // the picture's color at one point
        public var luma: Double                     // BT.601, 0...255
        public var redness: Double                  // BT.601 Cr, 0...255 (128 gray)
        public init(luma: Double, redness: Double)
    }
    /// nil without both eyes (each its pupil's mean point, else its contour's). `color`: the pixel at a face-box-normalized point (nil outside the picture); without it, no tongue.
    public static func shape(of landmarks: Landmarks, color: ((CGPoint) -> FaceShapeMeasure.Sample?)?) -> FaceShape?
    /// Turned about the eyes' midpoint until the eye line is level, not scaled: what the seven features are measured on. Upright, or without both eyes: unchanged.
    public static func leveled(_ landmarks: Landmarks) -> Landmarks
}
```
Measuring (binding): m = the midpoint of the eyes' centers, d = their distance, θ = the eye line's angle, taken pointing to the picture's right whichever eye Vision calls left (a mirrored picture measures the same); a point p becomes `q = R(−θ)(p − m) / d` (face-box units count as square), so the eyes sit at (±0.5, 0), y up, the midline x = 0, and a tilted, far or moved face measures like an upright, near one. Eye opening = shoelace area / width² of its contour (≥ 3 points); brow gap = the brow's mean y − its eye contour's mean y; lipWidth / lipHeight / mouthShift = the outer lips' width, height and middle x; cornerTilt = y of the outer lips' left-most point − the right-most one's; lipOpening = the inner lips' height; lowerLip = inner-lip min y − outer-lip min y; gazeUp = the mean over eyes with a pupil of the pupil's mean y over the line through its eye contour's left-most and right-most points (at the pupil's x) / that eye's width (the lids don't move the corners, so heavy lids and frowns don't read as looking up). Tongue: skin = the median redness and luma of 6 × 6 samples in each of two 0.2 × 0.2 cheek patches centered at (±0.55, −0.75); lips = the median redness of a 16 × 8 grid over the outer lips' box, kept where inside the outer contour and outside the inner one; C = lips − skin (nil when < 5: gray or odd light); the band 0.02 under the outer lips' bottom, 0.45 deep, ± 0.3 × lipWidth around their middle, on a 12 × 8 grid: `tongue` = the share of its samples (inside the picture) with redness ≥ skin + 0.6 C and luma ≥ 0.45 × the skin's (a dark open mouth isn't a tongue). Samples are taken at face-box points (leveled points turned back), so the picture's tilt doesn't matter.

### BodyPose.swift

```swift
public enum BodyJoint: String, CaseIterable, Sendable { case nose, leftEye, rightEye, leftEar, rightEar, neck, leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist, root, leftHip, rightHip }   // no legs
public enum HandJoint: String, CaseIterable, Sendable { case wrist, thumbCMC, thumbMP, thumbIP, thumbTip, indexMCP, …, littleTip }   // Vision's 21
public struct JointReading: Hashable, Sendable { x, y, confidence }   // Vision-normalized, origin bottom-left
public struct PosePoint: Hashable, Sendable { x, y }                  // aspect-corrected: x × width / height, y as Vision's
public struct PoseBox: Hashable, Sendable {                           // aspect-corrected rectangle
    public init(normalizedX:y:width:height:imageWidth:imageHeight:)
    public func grown(by fraction: Double) -> PoseBox
    public func contains(_ point: PosePoint) -> Bool
}
public struct BodyJoints: Hashable, Sendable {
    public init(readings: [BodyJoint: JointReading], imageWidth: Double, imageHeight: Double)   // drops joints < 0.3 confidence
    public init(points: [BodyJoint: PosePoint], shortSide: Double = 1, shoulderConfidence: Double = 1)
    public subscript(joint: BodyJoint) -> PosePoint? { get }
    public static func primary(of bodies: [BodyJoints], faceBox: PoseBox?) -> BodyJoints?   // head in the face box grown 30 %, else surest shoulders
    public func ownHands(_ hands: [HandJoints]) -> [HandJoints]   // hand wrist within 0.6 shoulder widths of a body wrist (all without wrists)
    public func widthInImage(aspect: Double) -> Double?   // max(shoulder gap, 2.6 × ear gap) / aspect: share of the image's width; nil without either
}
public struct HandJoints: Hashable, Sendable { init(readings:imageWidth:imageHeight:); init(points:) }
public struct HandShape: Codable, Hashable, Sendable {
    public var thumbsUp, point, openPalm, fist, peace: Double   // 0...1
    public init?(_ hand: HandJoints, faceBox: PoseBox? = nil)   // nil without the wrist or with fewer than 2 fingers; an index or thumb tip inside faceBox is no pointing / thumbs-up sign, an index or middle tip in it no peace sign
    public var signStrength: Double { get }         // max(thumbsUp, point, peace)
    public static func strongest(_ shapes: [HandShape]) -> HandShape?   // per-sign max
}
public enum BodyShape: String, CaseIterable, Sendable { case dab, bolt, flex, ohNo, armsCrossed, tPose, handsOnHips, pickMe, hello, bow }
public struct PoseDescriptor: Codable, Hashable, Sendable {
    public enum Dimension: Int, CaseIterable { leftLift, leftOut, leftHead, leftElbowLift, leftElbowBend, rightLift, …, rightElbowBend, wristGap, shoulderTilt, headRise, leftCross, rightCross, leftElbowOut, rightElbowOut, torsoLength, leftForearmRise, rightForearmRise }
    public private(set) var values: [Double?]      // 20, each 0...1 (3 decimals), nil = a joint it needs wasn't seen; only ever appended to (fewer read as nil)
    public var hand: HandShape?
    public init?(_ joints: BodyJoints, hand: HandShape? = nil)   // nil without both shoulders or a neck, or a body < 2 % of the short side
    public var mirrored: PoseDescriptor { get }    // left and right numbers swapped
    public var showsArms: Bool { get }             // a wrist, an elbow or a hand sign was seen
    public var bodyShape: BodyShape? { get }       // a shape with its own word, from the body alone
    public static let shapeStrength: Double        // 0.6
    public var gestureStrength: Double { get }
    public var gestureDirection: [Double] { get }  // 9 numbers for the tracker (0 at rest): 6 for the arms (an unseen arm next to a seen one reads as resting unless its upper arm is near vertical), then thumbs up, pointing, peace (each from 0.7)
    public static func compare(_ a: PoseDescriptor, _ b: PoseDescriptor) -> (similarity: Double, coverage: Double)
}
```
Pose (binding):
- Body frame: origin O = shoulder midpoint (else the neck); x along the shoulder line (oriented left to right in the image, so the tilt is taken out either way the person faces); unit S = shoulder distance, at least 0.8 × the head's estimate (2.6 × ear distance, else 6 × eye distance, else 3 × nose-to-ear distance seen from the side) and at least 0.7 × the longer upper arm. The shoulder line gives the tilt (and `shoulderTilt`) only when it is at least 0.5 S long; a body turned to the side keeps roll 0. Head H = mean of nose, eyes, ears. Points p' = rotate(p − O) / S.
- Per arm (wrist w', elbow e', shoulder s'): `lift = (w'.y + 1.5) / 3.5`, `out = |w'.x| / 2.5`, `head = |w' − H'| / 2`, `elbowLift` = upper-arm angle from straight down / 180°, `elbowBend` = 1 − elbow angle / 180°, `cross = (0.5 − sign(s'.x) × w'.x) / 2` (0 at its own shoulder, 0.25 at the middle, 0.5 at the other shoulder; only when the shoulder line is reliable), `elbowOut = |e'.x| / 2.5`, `forearmRise = 0.5 + (w'.y − e'.y) / 2` (0.5 level, more with the wrist above the elbow). `wristGap = |wL − wR| / S / 3`, `shoulderTilt = |roll| / 30°`, `headRise = H'.y / 1.5`, `torsoLength = |hips'| / 2` (hips' = the middle of both hips, else the root; about 0.675 standing). All clamped to 0...1.
- bodyShape (first match; a missing number never matches; "low" = lift ≤ 0.4, or without a wrist an elbowLift < 0.4 or none): dab = one arm up and out (lift ≥ 0.6, out ≥ 0.4, bend ≤ 0.25, cross ≤ 0.05) and the other across the face (cross ≥ 0.35, lift ≥ 0.5, head ≤ 0.5); bolt = one arm up and out and the other drawn back (bend ≥ 0.3, lift 0.3...0.6, cross ≤ 0.3); flex = both elbowLift 0.36...0.66, bend ≥ 0.38, lift ≥ 0.5, head ≥ 0.36; ohNo = both head ≤ 0.35, lift ≥ 0.5 and ≥ the head's lift + 0.07, not both out ≥ 0.09; armsCrossed = both cross ≥ 0.27, bend ≥ 0.3, lift ≤ 0.45 and ≥ 0.12 (without a torso ≥ 0.21 and forearmRise ≥ 0.52); tPose = both lift 0.3...0.6, out ≥ 0.55, bend ≤ 0.2, elbowLift 0.38...0.65 (when seen); handsOnHips = torso ≥ 0.5 and akimbo (elbowOut − out ≥ 0.1, lift ≤ 0.32, elbowLift ≥ 0.15) on both arms, or one (elbowLift ≥ 0.17) with the other low; pickMe = one lift ≥ 0.75, bend ≤ 0.35, head ≥ 0.35 (when seen), the other low; hello = one lift 0.5...0.8, head 0.3...0.75, out ≥ 0.2, elbowLift ≤ 0.6, bend ≥ 0.25, the other low, an open palm when a hand was read; bow = torso ≤ 0.45 and headRise ≤ 0.25.
- Hand: a finger is straight when |tip − wrist| / |PIP − wrist| ≥ 1.2 (ramp from 0.95) and curled when ≤ 0.8 (ramp to 1.05). thumbsUp = min(others curled, thumb tip−IP within ~35° of up, thumb tip above the other fingers by 0.1–0.35 palms); point = index straight, 3 others curled; peace = index and middle straight, ring and little curled; openPalm / fist = all straight / curled.
- gestureStrength: max(armStrength, 0.6 when there is a bodyShape), and a hand sign ≥ 0.7 raises it to the sign's strength. armStrength: the weighted RMS distance from arms hanging at the sides (lift .03, out .2, head 1, elbowLift .05, elbowBend .1, gap .37; weights 1, .5, 1, .5, .25, .5) over the numbers seen, skipping an elbowLift whose wrist wasn't seen unless it is ≥ `elbowOnlyUp` (0.88, near vertical: hands out of the top of the frame, not clasped behind the head), `clamp((rms − 0.1) / 0.3)`, where each arm's squared distances are scaled by (1 − its rest factor) (1 when its wrist is low, in front and away from the head: lift ≤ 0.3, out ≤ 0.2, head ≥ 0.45 — a forearm on a desk, a mug or phone at the chest — falling to 0 over 0.08 / 0.06 / 0.1 beyond, so it never jumps; the wrist gap by the larger of the two). `forearmRest` (the smallest rest factor of the wrists seen) also keeps resting hands from reading as clapping.
- compare: weights per number lift 2, out 1, head 2, elbowLift 1, elbowBend 1, gap 1.5, tilt .5, headRise .5, cross 1, elbowOut .5, torso .5, forearmRise .5 (hand signs 1 each when both have a hand; the torso, like the hand, only when both have it); per number `max(0, 1 − |Δ| / 0.25)`. similarity = over numbers both have; coverage = their weight / the weight of numbers either has.
- `PoseFeatures.similarity(query:item:)`, g = gesture strength: the item's arms not seen → `1 − 0.7·g_query`; the query without a descriptor → level = `1 − |g_query − g_item|`; else, with t = clamp((max(g_query, g_item) − 0.1) / 0.3) (0 while both rest), `(1 − t) × level + t × X`, where X is unknown for an item measured the old way, else the better of the item as-is and mirrored of `coverage × similarity × (0.5 + 0.5·level) + (1 − coverage) × level`.

### Baseline.swift

```swift
public struct RestingBaseline: Codable, Equatable, Sendable {   // lenient decoding: settings from before restShape load with it nil
    public private(set) var neutral: FaceFeatures
    public private(set) var sampleCount: Int
    /// The resting shape the face's cues are read against (`cues(of:)`, FaceCues.swift); nil until a calm frame brought one.
    public private(set) var restShape: FaceShape?
    public init(neutral: FaceFeatures = .populationNeutral, sampleCount: Int = 0, restShape: FaceShape? = nil)
    /// Updates an EMA from calm frames: a frame is calm when intensity(of:) < (sampleCount < 30 ? 0.25 : 0.08).
    /// alpha = sampleCount < 30 ? 0.2 : 0.05 for the seven numbers and each field of the resting shape, or 0.01
    /// (`cueAlpha`) when one of `shape`'s cues reaches 0.2 (`calmCueLimit`): a held tongue or pucker is barely learned
    /// as the rest, while a rest that no longer fits (the camera moved) still catches up instead of locking. The first
    /// shape is taken as it is; a field it lacks is taken, one the frame lacks stays. Increments sampleCount for calm
    /// frames only.
    public mutating func observe(_ face: FaceFeatures, shape: FaceShape? = nil)
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
    /// m = max deviation; if m < 0.05 → all 1, else 1 + 2 * d / m per region. pose = min(0.6, 0.05 + 0.55 * poseStrength)
    public static func automatic(deviation: [FaceRegion: Double], poseStrength: Double) -> FeatureWeights
    /// Pinned regions get weight 6.
    public func pinning(_ pins: Set<FaceRegion>) -> FeatureWeights
}
```

### PeakHoldTracker.swift

```swift
public struct PeakHoldConfig: Sendable {
    public var holdDuration: TimeInterval = 0.3        // the first query, a stronger version of it, anything new once re-armed
    public var newExpressionHold: TimeInterval = 1.0   // a new expression with a clear gesture (and a shape held up by its floor, always)
    public var newFaceHold: TimeInterval = 0.6         // a new expression of the face alone (another face, a cue on the held one)
    public var rearmAfterCalm: TimeInterval = 0.4      // a calm face this long re-arms the tracker until the next query
    public var strongerRatio: Double = 1.15
    public var sameDirectionCosine: Double = 0.85
    public var minimumIntensity: Double = 0.12
    public var bufferWindow: TimeInterval = 0.5
    public var minimumGestureWithoutFace: Double = 0.5
    public var gestureGrace: TimeInterval = 0.3
    public var newPoseSimilarity: Double = 0.6
    public init()
}

public final class PeakHoldTracker {
    public var baseline: RestingBaseline
    public let config: PeakHoldConfig
    public private(set) var query: ExpressionSample?
    public private(set) var queryIntensity: Double          // 0 when no query
    public private(set) var holdProgress: Double            // 0...1 toward replacing the query
    public private(set) var candidateIsNewExpression: Bool
    public private(set) var candidate: ExpressionSample?    // the best frame of the run being held; nil when none
    public private(set) var lastSample: ExpressionSample?
    public private(set) var lastFaceTimestamp: TimeInterval? // timestamp of the last sample that had a face
    public private(set) var lastSeenTimestamp: TimeInterval? // … a face, or a gesture ≥ minimumGestureWithoutFace standing in for one
    public init(baseline: RestingBaseline = RestingBaseline(), config: PeakHoldConfig = PeakHoldConfig())
    /// Feed every analyzed frame. Returns true when `query` changed.
    @discardableResult public func ingest(_ sample: ExpressionSample) -> Bool
    /// Space: makes the last sample with a face (or a gesture hiding it) the query, even if neutral. Returns true if it changed the query.
    @discardableResult public func snap() -> Bool
    /// Drops the expression being held toward the query (keeps the query and the baseline); the capture view opening. A calm
    /// face before the gap doesn't count toward re-arming.
    public func clearHold()
    /// Clears the query, the candidate and the re-arming (keeps the baseline).
    public func reset()
}
```

Algorithm (binding):
- `ingest`: set `lastSample`. No face and a gesture strength below `minimumGestureWithoutFace` (0.5) → clear the candidate, `holdProgress = 0`, return false (a facepalm hides the face: its gesture carries on). Grace: a run whose first frame was a clear gesture (strength ≥ 0.4) instead skips such a frame (and one under `minimumIntensity`, and one outside its cone without its shape) while it is within `gestureGrace` (0.3 s) of the last frame it took, keeping the run, candidate and progress; face runs get none. Frames with a face feed `baseline.observe(face, shape: sample.shape)` (it learns from the calm ones) after the frame was judged against the baseline as it was.
- The face's cues: `baseline.cues(of: sample.shape)` (FaceCues.swift; all 0 without a shape). Effective intensity `e = max(baseline.intensity(of: face) (0 without), 0.8 × gesture strength when it is ≥ 0.4 (else 0), 0.8 × the strongest cue when it is ≥ 0.3 (else 0))`: half-raised arms with a neutral face are not an expression; a tongue out, a wink or a smirk is, though the seven numbers barely move. Direction vector = `signedDeviation(of: face)` (7 zeros without) + `0.5 × gestureStrength × descriptor.gestureDirection` (a pose without a descriptor: `[activity, 0, 0, 0, 0, 0, 0, 0, 0]`) + `0.8 ×` the six cues (zeros without a shape or a face), 22 values, normalized. A different hand sign with the arm where it was is therefore a different expression, and a cue added to a held face points elsewhere. Each frame keeps its clear cue (`FaceCues.clearCue`).
- Calm and re-arming: a frame with a face and `e < minimumIntensity` (no expression, cue or clear gesture) is calm. Calm frames for `rearmAfterCalm` (0.4 s, from the first calm frame's timestamp) re-arm the tracker until the next query (setting the query, `snap` and `reset` disarm it; `clearHold` and `reset` restart the calm). Any other frame, one without a face included, ends the calm streak, not the re-arming. Relaxing between two faces says the second one is meant; talking never stays calm for 0.4 s between sounds.
- A sample is a candidate if `e >= minimumIntensity`; otherwise clear the candidate, return false.
- The candidate is a run of consecutive candidate samples that keep the run's first sample's clear cue (the same one, or none while that one still shows at ≥ 0.3: `keepsCue`; another cue starts a run of its own, so one frame of it never names a face held without it) and whose direction cosine with the run's first sample is ≥ `sameDirectionCosine`, or whose `bodyShape` one of the run's samples has, with a face that agrees with the run's first sample's (both calm, below `minimumIntensity` with the cues' intensity, or unseen; or both moved the same way, the seven deviations and the cues × 0.8 at cosine ≥ `sameDirectionCosine`): a far face flickering swings the direction of a shape held up by its 0.6 floor; a sample outside that starts a new run, which takes the samples skipped by the grace just before it that point its way and keep its cue (cosine ≥ `sameDirectionCosine`; a sample under a gate drops them) and is timed from the first of those, if any: a face flickering between two looks gets no head start. Within a run keep the samples within `bufferWindow` of the newest; the best is the highest `e * sharpness` (the newest winning ties) among the samples with the run's pose word (`gestureMood` when the strength is ≥ 0.4): the word most of them have (the newest's on a tie) when three or more have it (the body is read every other frame, so one reading fills two) or the newest does; else among those without a word. So a noisy reading neither takes a held pose's word away nor gives one to a pose without, and arms caught rising into a celebration take its word as soon as it shows.
- Required hold: no query → `holdDuration`. Same direction as the query (cosine ≥ `sameDirectionCosine`, or the query's `bodyShape` with faces that agree as above) → `holdDuration`, and only if `bestE >= queryIntensity * strongerRatio` (otherwise `holdProgress = 0`, no replacement; relaxing in between changes nothing). Different direction, a new gesture word, a new cue or a new pose → a new expression, `candidateIsNewExpression = true`, held for `holdDuration` (0.3 s) once re-armed, else `newExpressionHold` (1 s) when the best sample's gesture strength is ≥ 0.4 (arms on their way to a pose pass through others), else `newFaceHold` (0.6 s). A new cue: the best sample has a clear cue (≥ `FaceCues.clear`) other than the query's as read when it became the query (nil included): on a strong face a cue moves the direction and the intensity too little to tell, so a tongue out or a wink on a held smile is new; the query's own cue, even stronger, is the same expression, and a cue fading below clear isn't a new one (one hovering around 0.5 would start search after search). A new pose: both the best sample and the query are clear gestures with descriptors, not the same shape, and the better of `compare(query, best)` and `compare(query, best.mirrored)` (a comparison covering < 0.6 counts as alike) is < `newPoseSimilarity`: strong poses all reach intensity 0.8 and many point the same way. A best sample held up only by its shape's floor (armStrength < 0.4, no hand sign, the face weaker) needs at least `newExpressionHold`, re-armed or not: hands in pockets read as hands on hips for a frame or two now and then. A new gesture word: the best frame has a clear gesture (strength ≥ 0.4, so forearms on armrests reading as a shrug don't count) whose `MoodClassifier.gestureMood` differs from the query's as read when it became the query (nil included). Strong gestures all reach intensity 0.8 and several share a direction (clapping, face in hands, mind blown), and a face is usually held before the arms arrive, so neither strength nor direction would let a hand caught on its way to the face, or a shrug after a held smile, replace the query. A run is the same expression again only when it points the query's way (or holds the query's shape with faces that agree), brings no new gesture word, no new cue and no new pose: then it is cleared unless 15 % stronger.
- `holdProgress = min(1, (newest.timestamp - run.start) / required)`. When it reaches 1: `query = best`, `queryIntensity = bestE` (its gesture word, clear cue and shape kept with it), clear the run and the re-arming, `holdProgress = 0`, `candidateIsNewExpression = false`, return true.
- `candidate` is the run's best sample while it is held toward the query; clearing the candidate (and the query being set) makes it nil.

### PoseBadge.swift

```swift
public enum PoseBadge: Equatable, Sendable {      // the pose behind the search: picks the readout's source and the catch flash
    case word(Mood), pose
    public static func of(_ sample: ExpressionSample, baseline: RestingBaseline) -> PoseBadge?   // nil below strength 0.4; else gestureMood's word, else .pose
    public var label: String { get }               // the mood's label, or "your pose"
}
public struct StandingBackDetector: Sendable {    // the hint's "Reading your pose"
    public private(set) var isStandingBack: Bool
    @discardableResult public mutating func observe(bodyWidth: Double?, at timestamp: TimeInterval) -> Bool
    public mutating func reset()
}
```
StandingBackDetector: on after 1.5 s with a body narrower than 0.2 of the image (`BodyJoints.widthInImage`); off after 1 s at 0.25 or wider, or 1.5 s without a body; in between nothing changes. The hint uses it only once the face is missing ("Reading your pose" instead of "Can’t see your face").

### EarlyMoodTrigger.swift

```swift
public struct EarlyMoodTrigger: Sendable {
    public var settleTime: TimeInterval              // 0.2
    public init(settleTime: TimeInterval = 0.2)
    /// Feed the candidate's mood (nil: nothing held) every frame. Returns the mood once it has read the same for settleTime, once per streak.
    public mutating func observe(_ candidateMood: Mood?, at timestamp: TimeInterval) -> Mood?
    public mutating func reset()
}
```
`.reaction` never fires. AppModel feeds it the mood of `tracker.candidate` (with its shape, so a tongue out reads as "tongue out") and calls `web.warm` with what it returns, so a mood's GIPHY search starts before the hold completes (0.3 s, 0.6 s for a new face, 1 s for a new gesture).

### Mood.swift

```swift
public enum Mood: String, CaseIterable, Codable, Hashable, Sendable {
    case shocked, screaming, laughing, happy, smug, sideEye, crying, sad, angry, confused, unimpressed, nervous, excited, reaction
    case celebrate, facepalm, mindBlown, shrug, thumbsUp, pointing, clapping   // body language
    case tPose, flex, dab, handsOnHips, armsCrossed, pickMe, hello, ohNo, peace, bow
    case tongueOut, wink, raisedEyebrow, duckFace, smirk, eyeRoll                  // face details (FaceCues)
    /// GIPHY query: one short tag-like phrase. "shocked reaction" (the face's other moods: label + " reaction"), "side eye", "unimpressed", "reaction"; body language: the label ("mind blown", "thumbs up"), except "t pose", "peace sign", "bowing"; face details: the label ("tongue out", "wink", "raised eyebrow", "duck face", "smirk", "eye roll"), GIPHY's own tags for them
    public var searchQuery: String { get }
    /// Human word, e.g. "shocked", "side eye"
    public var label: String { get }
}

public enum MoodClassifier {
    /// Rules in this order (d = signed deviation from baseline.neutral; o = face.mouthOpenness; s = face.smile - 0.5):
    /// 1. pose.descriptor, gestureStrength ≥ 0.4 (Ranker.gestureWithoutFace), with body language that has its own word → gestureMood
    /// 2. face nil → .reaction
    /// 2b. a clear face cue (`baseline.cues(of: shape).clearCue`: against the resting shape; fixed values without one) → its word (`FaceCues.Cue.mood`)
    /// 3. poses without a descriptor only: pose.handsRaised ≥ 0.5 && o ≥ 0.35 → .screaming;  pose.activity ≥ 0.5 && s > 0.08 → .excited
    /// 4. o ≥ 0.45 && s ≤ 0.05 && (d.eye ≥ 0.1 || d.brow ≥ 0.1) → o ≥ 0.7 ? .screaming : .shocked
    /// 5. o ≥ 0.2 && s > 0.08 → .laughing
    /// 6. d.eye ≥ 0.15 && d.brow ≥ 0.12 → .shocked
    /// 7. face.gazeSide ≥ 0.45 → .sideEye
    /// 8. s > 0.12 → d.eye < -0.12 ? .smug : .happy
    /// 9. s < -0.1 → d.brow > 0.05 ? .crying : .sad
    /// 10. d.brow > 0.12 && s < 0 → .nervous
    /// 11. d.brow < -0.12 → .angry
    /// 12. face.headTilt ≥ 0.35 → .confused
    /// 13. else → .unimpressed
    public static func mood(for face: FaceFeatures?, pose: PoseFeatures?, shape: FaceShape? = nil, baseline: RestingBaseline) -> Mood
    /// Each rule needs the joints it reads; in this order (shape = pose.bodyShape):
    /// 1. hand: thumbsUp ≥ 0.7 → .thumbsUp; peace ≥ 0.7 → .peace; point ≥ 0.7 → .pointing
    /// 2. shape dab → .dab; flex → .flex; bolt → .celebrate
    /// 3. both arms up (lift ≥ 0.7, or ≥ 0.65 with out ≥ 0.45, with head ≥ 0.35; or no wrist and elbowLift ≥ 0.88) → o ≥ 0.35 && s ≤ 0.05 ? .screaming : .celebrate
    /// 4. both hands beside the head (head ≤ 0.35, lift ≥ 0.5, out ≥ 0.09) → o ≥ 0.45 ? .screaming : .mindBlown
    /// 5. shape ohNo → o ≥ 0.45 ? .screaming : .ohNo
    /// 6. a hand on the face (head ≤ 0.22, ≤ 0.3 without a face; lift ≥ 0.5; not elbowLift ≥ 0.42 with cross ≥ 0.35, nor elbowLift ≥ 0.7: hands clasped behind the head), face nil or d.eye ≤ −0.25, o < 0.35, s ≤ 0.05 → .facepalm
    /// 7. wristGap ≤ 0.12, both lifts 0.3...0.75 with head > 0.3, forearmRest < 0.5, and open hands when read (openPalm ≥ 0.5) → .clapping
    /// 8. shape armsCrossed, tPose, handsOnHips, pickMe, hello, bow → that word
    /// 9. both elbowBend ≥ 0.3, out ≥ 0.3, lift 0.1...0.5 → .shrug
    /// 10. both out ≥ 0.45 and lift ≥ 0.35, s > 0.08 → .excited
    public static func gestureMood(_ pose: PoseDescriptor, face: FaceFeatures?, baseline: RestingBaseline) -> Mood?
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
    public var faceShape: FaceShape?      // the face's details (FaceCues.swift), read against fixed values; nil without a face or before faces were measured this way
    public var faceRevision: Int          // 0: face measured in the picture's axes; currentFaceRevision (1) since: the seven features in the face's leveled frame, with its faceShape
    public var pose: PoseFeatures?
    public var poseRevision: Int          // 0: pose not described in detail yet; 1 arms and hands; 2 also the wrists across, elbows out and torso; currentPoseRevision (3) since: also the forearms' rise, no peace sign on the face
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
    public init(id: UUID = UUID(), fileURL: URL, displayName: String, kind: ItemKind, tier: ItemTier = .meme, source: String, sourceDetail: String? = nil, addedAt: Date = Date(), fileModifiedAt: Date? = nil, fileSize: Int64 = 0, contentHash: String, isSticker: Bool = false, isAnimated: Bool = false, face: FaceFeatures? = nil, pose: PoseFeatures? = nil, poseRevision: Int = 0, intensity: Double = 0, featurePrint: [Float]? = nil, featurePrintRevision: Int = 0, text: String = "", labels: [String] = [], personID: UUID? = nil, faceEmbedding: [Float]? = nil, remoteURL: URL? = nil, previewURL: URL? = nil, attribution: String? = nil, timesSent: Int = 0, lastSentAt: Date? = nil, faceShape: FaceShape? = nil, faceRevision: Int = 0)
    public static let currentPoseRevision: Int      // 3
    public static let currentFaceRevision: Int      // 1
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
`LibraryItem` implements `init(from:)` with `decodeIfPresent` + defaults for every non-essential key so older JSON keeps loading (`faceShape` nil, `faceRevision` 0 when missing or damaged). `faceShape` is written only when present, `faceRevision` always.

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
    public var personIDs: Set<UUID>      // terms equal (case-insensitive) to a person's name, or its possessive ("sam's"), are removed from terms and become filters
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
- **expressionScore**: target `t = sample.face.map { baseline.intensity(of: $0) } ?? 0.3`. If `item.face` and `sample.face` exist: `qDev = baseline.signedDeviation(of: sample.face)`, `iDev = item.face.vector - populationNeutral.vector`; per region `sim_r = max(0, 1 - meanAbsDiff(qDev[idx_r], iDev[idx_r]) / 0.5)`; `featureSim = Σ w_r·sim_r / Σ w_r`; `poseSim = PoseFeatures.similarity(query: sample.pose, item: item.pose)`; `faceScore = (1 - w.pose)·featureSim + w.pose·poseSim`; `fit = 1 - |item.intensity - t|`; `score = 0.7·faceScore + 0.3·fit`. When the query shows a clear cue (`baseline.cues(of: sample.shape).clearCue`, against the resting shape) of strength u: `v = 0.45·u`, `cueSim = FaceCues(shape: item.faceShape, rest: nil)[cue]` (0.5, unknown, without a `faceShape` or when it lacks what the cue is read from: `FaceShape.measures(_:)`), `faceScore = (1 - w.pose)·(1 - v)·featureSim + w.pose·poseSim + (1 - w.pose)·v·cueSim`: a face the seven numbers can't tell from a plain one finds the memes that show it. Without a clear cue the score is exactly as without a shape. Without item or sample face: when the sample's gesture strength is ≥ `Ranker.gestureWithoutFace` (0.4) and the item's arms were measured (a descriptor that shows arms), the same with featureSim 0.5 (a facepalm hides the face; the pose carries the match); else `score = 0.25 + 0.3·fit`. Then `+0.02` if `isOwn`, `+0.01·min(timesSent,5)/5`, `-0.01` if `kind == .web`, and with a clear cue `+0.05` when the item's name, text or labels (lowercased) contain one of the cue's words (`Ranker.mentions(_:in:)`: tongue, blep; wink; eyebrow; duck face, duckface, kiss, pout; smirk; eye roll, eyeroll, rolling eyes), in every branch.
- **expression** results: items with `tier == .meme` only; sort by score desc; keep at most 2 `kind == .friend` items within the first `limit` (extras are dropped from the window); return `limit`.
- **text**: parse with `TextQuery.parse`. Pool: `tier` meme or maybe, matching filters; every term must be a substring of `lowercased(displayName + " " + text + " " + labels.joined(" ") + " " + source + " " + (sourceDetail ?? "") + " " + person name)`. Order inside groups: by `expressionScore` when `face` is non-nil, else newest first (`fileModifiedAt ?? addedAt`). Groups and `section`: own items grouped by `monthKey` (newest month first), then `.pack` ("Packs"), then `.web` ("From GIPHY"). If fewer than 3 hits, append matching `skipped` items with section "From your photos". Return up to `limit`.
- **image**: meme tier; `fp = featurePrint != nil && item.featurePrint != nil ? (cosine + 1) / 2 : 0.5`; `fs = face sim with uniform weights using populationNeutral for both (0.5 when either is nil)`; `score = 0.7·fp + 0.3·fs`, then the same own/web adjustments.
- **moreLike(L)**: exclude `L.id`; `score = 0.6·fp + 0.3·fs + 0.1·(1 - |item.intensity - L.intensity|)` (fp/fs as above, comparing to L).
- **recent(app)**: items whose ids appear in `recents` (in that order, meme or maybe tier), then fill up to `limit` with own meme-tier items by `lastSentAt` desc, then `addedAt` desc. Score 1.

### TileGrid.swift

```swift
public struct TileGrid: Equatable, Sendable {
    public init(columns: Int, ownRows: Int, ownCount: Int, giphyCount: Int, templateCount: Int = 0)   // counts clamped to the grid / one row
    public var webStart: Int { get }                 // columns × ownRows: the first web slot, however many memes there are
    public var templateStart: Int { get }            // webStart: the classic memes row's first slot
    public var giphyStart: Int { get }               // templateStart + columns: the GIPHY row's first slot
    public var firstSlot: Int? { get }               // top to bottom: the first meme, else the first classic meme, else the first GIF
    public enum Section: Equatable, Sendable { case own, giphy, template }
    public func section(of slot: Int) -> Section
    public func isFilled(_ slot: Int) -> Bool
    public func move(from slot: Int, dx: Int, dy: Int) -> Int?   // arrow keys: along the row, or to the nearest row with tiles (column kept when it can)
}
```
Keyboard focus over the panel's three rows: your memes (`ownRows` rows of 6: 1, or 0 with none), the classic memes row below them and the GIPHY row at the bottom. Each row fills from the left; empty rows are skipped.

### MemeTemplateCatalog.swift

```swift
public struct TemplateRef: Equatable, Sendable { public let id: String; public let name: String }   // Imgflip's id and name
public enum MemeTemplateCatalog {
    public struct Entry: Sendable { names: [String]; id: String?; moods: [Mood]; words: [String] }
    public static let entries: [Entry]               // ~80 famous templates, most famous first
    /// The templates for `mood` (entries whose first mood it is, then entries listing it later; each in table order), then the most popular others; `.reaction` = the most popular.
    public static func pick(for mood: Mood, from templates: [TemplateRef], limit: Int) -> [Int]
    /// The `page`th group of `limit` from the same full order (page 0 = the pick above; a negative page is 0), wrapping around: start = (page mod n) × limit mod n over the n ordered templates; with limit ≥ n every page is all of them.
    public static func pick(for mood: Mood, from templates: [TemplateRef], limit: Int, page: Int) -> [Int]
    /// Templates matching typed terms, best first; none when nothing matches.
    public static func pick(forTerms terms: [String], from templates: [TemplateRef], limit: Int) -> [Int]
}
```
Imgflip's list has no tags, so this table says what each famous template is for. An entry matches a listed template by Imgflip id, else by name (lowercased, letters and digits only: "Gru's Plan" = "grusplan"). Typed terms (split into words of 2+ letters) score per template: +3 for a word of its name starting with a term, else +2 for one of its search words; +2 when the typed text contains one of its multi-word phrases ("looking back"); +3 when its first mood is one the words name, +2 for a later mood. Moods are named by single words (`moodWords`: "sad", "lol" → laughing, "mad" → angry, "omg" → shocked, "smug", "flex", "dab", "tpose", "bow", "hello", "peace", "tongue", "blep", "mlem" → tongue out, "wink", "eyebrow", "duckface", "kissy", "pout" → duck face, "smirk" → smirk (not smug), "eyeroll"…) and by phrases (`multiWordMoods`: "side eye", "mind blown", "thumbs up", "t pose", "arms crossed", "hands on hips", "oh no", "pick me", "tongue out", "raised eyebrow", "duck face", "kissy face", "eye roll", "rolling eyes", "rolled eyes"), matched over all the typed words, one-letter ones too ("t-pose"), from the start of a word ("side eyeing"), except "oh no" and "pick me", which end on a whole word ("oh nothing", "pick memes" don't count). A matched phrase's words aren't scored as terms, so they don't pull in every name starting with them ("oh no" isn't Y U No, "eye roll" isn't Roll Safe, "duck face" isn't Picard Facepalm, "tongue out" isn't Ight Imma Head Out). The face details' moods have templates of their own (for example tongue out: Mocking Spongebob, Doge; wink: Roll Safe, Leonardo Dicaprio Cheers; raised eyebrow: The Rock Eyebrow Raise, Futurama Fry, Third World Skeptical Kid; duck face: Kermit Sipping Tea, Tuxedo Winnie The Pooh; smirk: Creepy Condescending Wonka, Disaster Girl, Evil Kermit; eye roll: Grumpy Cat, Disappointed Black Guy, Kombucha Girl), listed after each entry's earlier moods so the older moods' picks don't change. Ties keep Imgflip's (popularity) order.

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
    public var legacySentDirectory: URL { get }       // rootURL/Sent (never created): where earlier versions kept sent GIPHY stills
    @discardableResult public func removeSavedWebItems() -> Int        // removes kind .web / "giphy:" items (files, recents), then Sent unless still used
    public func idsWithMissingFiles() -> Set<UUID>                      // items whose file under rootURL (Kept, Stickers) is gone; a prefix test per item
    @discardableResult public func removeItemsWithMissingFiles() -> Int // removes those, with their recents
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
    typealias ColorReader = (CGPoint) -> FaceShapeMeasure.Sample?
    /// nil when the observation has no landmarks.
    static func features(from face: VNFaceObservation) -> FaceFeatures?   // features(from: landmarks(of: face), roll: face.roll)
    /// The seven features from the contours turned level (`FaceShapeMeasure.leveled`); nil without eyes and lips.
    static func features(from landmarks: FaceShapeMeasure.Landmarks, roll: Double) -> FaceFeatures?
    static func landmarks(of face: VNFaceObservation) -> FaceShapeMeasure.Landmarks?   // nil without landmarks
    /// The face's FaceShape in a camera frame, the tongue read from its 32BGRA pixels (another format: no tongue).
    static func shape(from face: VNFaceObservation, pixelBuffer: CVPixelBuffer) -> FaceShape?
    /// The face's FaceShape in an image, the tongue read from `pixels` (nil: no tongue).
    static func shape(from face: VNFaceObservation, pixels: RGBAPixels?) -> FaceShape?
    /// `body` gets the frame's colors at face-box points of `box` (nil for a format other than non-planar 32BGRA); the buffer is locked read-only meanwhile.
    static func withColors<T>(of pixelBuffer: CVPixelBuffer, box: CGRect, _ body: (ColorReader?) -> T) -> T
    /// The body that goes with the face (`BodyJoints.primary`), with the strongest sign of its own hands; nil without a body.
    static func pose(bodies: [VNHumanBodyPoseObservation], hands: [VNHumanHandPoseObservation] = [], faceBox: CGRect?, imageWidth: Int, imageHeight: Int) -> PoseFeatures?
    static func primaryBody(_ bodies: [VNHumanBodyPoseObservation], faceBox: CGRect?, imageWidth: Int, imageHeight: Int) -> BodyJoints?
    static func handJoints(_ hands: [VNHumanHandPoseObservation], imageWidth: Int, imageHeight: Int) -> [HandJoints]
    /// Vision-normalized image rects (origin bottom-left) for .eyes (union of both eyes) and .mouth (outer lips), padded 25 %; .brows (union of brows).
    static func regionRects(from face: VNFaceObservation) -> [FaceRegion: CGRect]
}
struct PixelSampler { … func sample(at point: CGPoint) -> FaceShapeMeasure.Sample? }   // 8-bit four-channel rows top-down; nil outside the picture
struct RGBAPixels: Sendable {                      // an image drawn once into sRGB RGBA8 (premultiplied), ≤ 512 px on its longer side
    static let maximumSide: Int                    // 512
    let width: Int, height: Int, bytes: [UInt8]    // rows top-down
    init?(image: CGImage, maximumSide: Int = RGBAPixels.maximumSide)
    func withColors<T>(box: CGRect, _ body: (FaceFeatureExtractor.ColorReader?) -> T) -> T
}
```
Mapping (landmark `normalizedPoints` are relative to the face bounding box, origin bottom-left). The seven features are measured on the contours turned about the eyes' midpoint until the eye line is level (`FaceShapeMeasure.leveled`, not scaled), so a tilted head doesn't read as an open mouth or raised brows; an upright face measures as before:
- eye ratio = (maxY − minY) / (maxX − minX) per eye, averaged → `eyeOpenness = clamp((ratio − 0.05) / 0.5)`.
- brow gap = mean(y of both brows) − mean(y of both eyes) → `browRaise = clamp((gap − 0.02) / 0.2)`.
- `mouthOpenness = clamp(innerLipsHeight / 0.25)`; `mouthWidth = clamp((outerLipsWidth − 0.2) / 0.5)`.
- smile: corners = leftmost and rightmost outer-lip points; `s = (mean corner y − mean outer-lip y) / max(width, 0.01)`; `smile = clamp(0.5 + 2.5·s)`.
- `headTilt = clamp(|roll| / (π/4))` (`face.roll?.doubleValue ?? 0`).
- gaze: per eye `(pupil.x − eyeCenter.x) / eyeWidth`, averaged → `gazeSide = clamp(|offset| · 3)`; 0.1 when pupils are missing.
- colors (PixelSampler, for the tongue): a face-box point p of the Vision-normalized box b is pixel x = (b.minX + p.x·b.width)·W, y = (b.minY + p.y·b.height)·H, row = H − 1 − ⌊y⌋ (rows lie top-down in memory); outside the picture → nil. luma = 0.299 R + 0.587 G + 0.114 B, Cr = 128 + 0.5 R − 0.4187 G − 0.0813 B (BT.601).
- pose: Vision's joints become `BodyJoints` / `HandJoints` (confidence ≥ 0.3, x corrected by the image's aspect) and `PoseFeatures(joints:hand:)` measures them (BodyPose.swift). `bodyVisible` = mean shoulder confidence (0 if missing). `handsRaised` = max over wrists of (wrist above the shoulder line → 1, within 0.6·shoulderWidth of the nose → 0.8, else 0). `armsSpread = clamp((|lw.x − rw.x| / shoulderWidth − 1) / 1.5)`.

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
    var faceShape: FaceShape?      // the same face's details, the tongue read from the frame drawn by RGBAPixels
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
    static func load(url: URL, maxPixelSize: Int = 2048) -> LoadedImage?   // ImageIO; nil if not an image or > 25 MB
    /// Synchronous; never call on the main thread. For animated images analyzes up to 3 frames and keeps the most intense.
    static func analyze(url: URL, includeText: Bool = true) throws -> ImageAnalysis
    static func analyze(_ image: LoadedImage, includeText: Bool = true) throws -> ImageAnalysis
    static func featurePrint(of cgImage: CGImage) throws -> [Float]
    /// Pose alone (frames decoded to 1024 px), for the indexer's pose pass: the clearest gesture of up to 3 frames.
    static func analyzePose(url: URL) -> PoseReading   // .unreadable or .read(PoseFeatures?)
    /// The face alone, for the indexer's face pass: the same frames and choice as `analyze` (a face beats none, the most intense wins), without feature print, labels, text or pose.
    static func analyzeFace(url: URL) -> FaceReading   // .unreadable (the file or its first frame can't be read) or .read(face:shape:intensity:)
    static func sha256Hex(_ data: Data) -> String
    /// kMDItemWhereFroms host, e.g. "reddit.com", if any.
    static func downloadedFromHost(url: URL) -> String?
}
```
Requests per frame: `VNDetectFaceLandmarksRequest` (the largest face's features, and its `FaceShape` with the frame drawn by `RGBAPixels` when it has a face), `VNDetectHumanBodyPoseRequest` (the body whose head is in the largest face's box), `VNDetectHumanHandPoseRequest` (up to 4 hands, only when a wrist was seen); no pose for frames under 128 px on the short side. The pose kept is that of the frame with the clearest gesture when it is ≥ 0.3 and clearer than the chosen frame's; per image once: `VNGenerateImageFeaturePrintRequest`, `VNClassifyImageRequest` (top labels with confidence ≥ 0.3, at most 8), `VNRecognizeTextRequest` (`.fast`, no language correction, joined, ≤ 200 chars) when `includeText`. Intensity uses `RestingBaseline()` (population neutral).

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
    private(set) var bodyWidth: Double?           // the last body's BodyJoints.widthInImage, set before each onSample; nil without one or in the capture view
    var isInUseByAnotherApplication: Bool { get } // the device start() would use
    var hasUsableCamera: Bool { get }             // false when no connected, unsuspended camera exists
    func refreshAuthorization()
    func requestAccess() async -> Bool
    func start()   // no-op unless authorized; lazily configures (front/default camera, .vga640x480 or .medium preset, BGRA output, alwaysDiscardsLateVideoFrames); startRunning on a private serial queue
    func stop()    // stopRunning on the private queue; clears faceVisible and regionRects; a pending still gets nil
    // Capture view (CaptureRenderer on the frame queue)
    var onCapturePreview: ((CGImage) -> Void)?    // every rendered frame while the capture view is open, on the main actor
    func setCaptureView(active: Bool, filter: CameraFilter)
    func captureStill() async -> CGImage?         // the next rendered frame; nil when none comes within 1 s
    func beginClip()                              // up to 12.5 frames a second, 320 px, at most 3 s
    func endClip() async -> CapturedClip?
    func cancelClip()
}
```
Frames: `AVCaptureVideoDataOutputSampleBufferDelegate` on a private queue. Every frame first goes to `CaptureRenderer.render` (a no-op unless the capture view is open or a capture runs); Vision is then throttled to 10 fps; per frame `VNDetectFaceLandmarksRequest`, then on even frames `VNDetectHumanBodyPoseRequest` (the body whose head is in the face's box) and on odd frames, while that body shows a wrist, `VNDetectHumanHandPoseRequest` (2 hands; the body's own hands' strongest sign), so at most 2 requests a frame; `VNImageRequestHandler(cvPixelBuffer:orientation: .up)`, image size from the pixel buffer. A frame with face features also gets the face's `FaceShape` (`FaceFeatureExtractor.shape(from:pixelBuffer:)`: the same observation and the same 32BGRA buffer, no further request) as the sample's `shape`. While the capture view is open no body or hand pose is read, and the face's `FaceGeometry` (plus its intensity, for the clip's best frame) goes to the renderer. Sample timestamp `CACurrentMediaTime()`; sharpness `1`.

### Camera/CameraFilter.swift and Camera/CaptureRenderer.swift

```swift
struct FaceGeometry: Equatable, Sendable {          // Vision-normalized, unmirrored buffer
    var firstEye, secondEye, mouth: CGPoint; var mouthOpen: CGFloat   // pupils, else eye contour centers; lipGap of the inner lips (face-box units)
    var nose: CGPoint? = nil                                          // center of the nose landmarks, else of the nose crest
    static func geometry(from face: VNFaceObservation) -> FaceGeometry?
    static func lipGap(_ points: [CGPoint], firstEye: CGPoint, secondEye: CGPoint) -> CGFloat   // spread across the eye line, so a tilted head doesn't open a closed mouth
}
struct FaceAnchors: Equatable, Sendable {           // pixels of the mirrored centered square, origin bottom-left
    var leftEye, rightEye, mouth, nose: CGPoint; var mouthOpen: CGFloat   // leftEye = the one on the left of the picture
    init(leftEye: CGPoint, rightEye: CGPoint, mouth: CGPoint, mouthOpen: CGFloat, nose: CGPoint? = nil)   // nil nose: estimatedNose
    init(geometry: FaceGeometry, imageWidth: CGFloat, imageHeight: CGFloat)   // x' = side − (x·w − (w − side)/2), y' = y·h − (h − side)/2
    static func estimatedNose(leftEye: CGPoint, rightEye: CGPoint, mouth: CGPoint) -> CGPoint   // 55 % of the way from between the eyes to the mouth
    var eyeDistance: CGFloat { get }; var angle: CGFloat { get }; var eyeMidpoint: CGPoint { get }
    var mouthOpenness: CGFloat { get }   // 0 up to mouthOpen 0.06, 1 from 0.18
    func above(_ point: CGPoint, by distance: CGFloat) -> CGPoint
    func offset(_ point: CGPoint, right: CGFloat, up: CGFloat) -> CGPoint   // along the eye line and the face's up direction
    func blended(toward target: FaceAnchors, amount: CGFloat) -> FaceAnchors
}
enum CameraFilter: String, CaseIterable, Identifiable, Sendable {
    case none, noir, comic, pixel, deepFried
    case dog, cat, bunny, rainbow, flowerCrown, hearts, shades, devil, angel, crown, bugEyes, clown, mustache, pig
    var title: String { get }        // "None", "Noir", "Comic", "8-bit", "Deep fried", "Dog", "Cat", "Bunny", "Rainbow", "Flowers", "Heart eyes", "Deal with it", "Devil", "Angel", "Crown", "Bug eyes", "Clown", "Mustache", "Pig"
    var followsFace: Bool { get }    // every case from dog on: unchanged without a face
    func apply(to image: CIImage, face: FaceAnchors?, time: TimeInterval) -> CIImage   // cropped to image.extent
}
struct CapturedClip { let frames: [CGImage]; let frameDelay: Double; let bestFrame: CGImage? }   // frameDelay = CaptureRenderer.frameDelay(…): the average gap of the kept frames, in 1/100 s, ≥ 0.02
final class CaptureRenderer {        // confined to the camera's frame queue
    static let clipFrameDelay: Double            // 0.08
    static let clipSide: Int                     // 320
    static let maximumClipDuration: TimeInterval // 3
    var isActive: Bool; var filter: CameraFilter; var onPreview: ((CGImage) -> Void)?
    static func mirroredSquare(_ frame: CIImage, width: CGFloat, height: CGFloat) -> CIImage
}
enum CaptureEncoder {
    static func png(_ image: CGImage) -> Data?
    static func gif(_ frames: [CGImage], frameDelay: Double) -> Data?   // loops forever; delay and unclamped delay per frame
}
```
Filters (Core Image, `CIFilterBuiltins`): noir = photoEffectNoir + vignette (intensity 1, radius 2); comic = comicEffect; 8-bit = pixellate (scale side / 40) + colorPosterize (6); deep fried = colorControls (saturation 2.6, contrast 1.5, brightness 0.04) + sharpenLuminance (2) + unsharpMask (2.5, 1.5); bug eyes = bumpDistortion on each eye (radius 0.75·d, scale 0.55) and the mouth when open > 0.12 (0.9·d, 0.4); shades = pixel-art glasses (24 × 6 cells, nearest sampling) 2.4·d wide on the eyes; hearts = a heart 0.9·d wide on each eye, pulsing ±8 % at 2 Hz; crown = 2.3·d wide, 1.75·d above the eyes (d = eye distance, all turned with the eye line). Snapchat-style ones, placed with `offset` from the eye midpoint (right ±, up) or on the nose and mouth: dog = floppy ears 1.15·d wide hung from (±0.68·d, 1.55·d), a nose 0.82·d wide, and while `mouthOpenness > 0` a tongue 0.7·d wide hung from the mouth, its height × (0.4 + 0.6·openness); cat = pointed ears 0.95·d at (±0.72·d, 1.45·d), whiskers from beside the nose, a pink nose; bunny = upright ears 0.7·d at (±0.4·d, 1.5·d) leaning out 0.22 rad, buck teeth 62 % from nose to mouth, a pink nose; rainbow = only while the mouth is open: a widening striped stream 1.8·d wide hung from the mouth, its length × (0.45 + 0.55·openness), swaying ±0.05 rad at 1.1 Hz and stretching ±6 % at 2.5 Hz; flowers = a crown of 9 flowers with leaves 2.8·d wide, 1.13·d above the eyes; devil = horns 0.72·d at (±0.55·d, 1.45·d); angel = a glowing halo 1.9·d wide 2·d above the eyes, bobbing ±0.07·d at 0.8 Hz; clown = a red ball nose 0.72·d and blush 0.75·d at (±0.78·d, −0.62·d); mustache = 1.35·d wide, 42 % from nose to mouth; pig = pink pointed ears 0.8·d and a snout 0.62·d on the nose. One-sided drawings are made for the left of the face and mirrored for the right. The drawings are made once with Core Graphics (`FilterSprites`).
Rendering: `CIImage(cvPixelBuffer:)` → centered square → mirrored → filter → `CIContext.createCGImage` (RGBA8, sRGB) at the square's size (480 at VGA); face anchors move halfway to each new reading per frame and are dropped 0.5 s after the last face. A still is the next rendered frame; a clip keeps a frame when 0.08 s (− 0.01) have passed since the last kept one, scaled to 320 px, for at most 3 s, and remembers the full-size frame whose analyzed face was most intense (starting from the latest frame, so a clip ended before its first frame still has one).

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
    func keep(urls: [URL], source: String) async -> IndexBatch   // first forgets kept files deleted in Finder, so a reused name ("pasted.png") can't revive one
    @discardableResult func removeItemsWithMissingFiles() -> Int // store.idsWithMissingFiles → removed like vanished files (duplicates requeued), saved, onLibraryChanged
    func undo(_ batch: IndexBatch)
    func pauseCollecting(for interval: TimeInterval)
    func resumeCollecting()
    func clearPendingSummary()
}
```
Scanning: top-level files only; skip hidden files, non-images (UTType conforming to `.image`), files > 25 MB, files already indexed with the same path + modification date + size. Analyze at most 2 at a time at utility priority; pause while `SystemConditions.shouldDeferBackgroundWork`. Item fields: `kind .mine`, `tier` from `MemeTierClassifier`, `source` = folder display name ("Downloads", "Desktop", "Screenshots" for the screenshot folder, else the folder name), `sourceDetail` = "from <host>" via `downloadedFromHost`. Skipped-tier items keep only path, hash, dates, facts-derived tier (no face, fingerprint, text, labels). Save the store at most every 5 s while indexing and at the end. New items get `poseRevision = LibraryItem.currentPoseRevision`, and (unless skipped) `faceShape` and `faceRevision = LibraryItem.currentFaceRevision`; kept items too.

Pose pass: when no scan is queued (after a scan, on start, after a pause ends), items with `kind .mine`, a tier other than `.skipped` and `poseRevision` below the current one are read again with `ImageAnalyzer.analyzePose(url:)`, one at a time at background priority, waiting while `shouldDeferBackgroundWork`, stopping for a scan or a pause (the scan's end starts it again). Only `pose` and `poseRevision` change (an unreadable file keeps its old pose, so it isn't retried every launch); the store is saved at most once a minute and at the end, and no library change is announced (the next search reads the new poses).

Face pass (`static func needsFaceRefresh(_ item: LibraryItem) -> Bool`: `kind .mine` or `.friend`, a tier other than `.skipped`, `faceRevision` below `LibraryItem.currentFaceRevision`): after the pose pass, never beside it or a scan (it stops for either, and for a pause; the scan's or the pose pass's end starts it again), items are read again with `ImageAnalyzer.analyzeFace(url:)` (frames at 2048 px, like a fresh index), one at a time at background priority, waiting while `shouldDeferBackgroundWork`. `face`, `faceShape` and `intensity` take the new reading (`applyingFaceReading`: a sticker keeps the face measured on its source photo, its file being a cut-out, and no item trades a face for none; those take only a shape that was read) and `faceRevision` becomes current (an unreadable file keeps its old face and still moves to the current revision); saved like the pose pass, no library change announced.

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
/// What the GIPHY row asks for (also the classic memes row's query).
enum WebQuery: Hashable, Sendable {
    case mood(Mood)
    case words(String)                               // typed terms: lowercased, single-spaced, ≤ 50 characters
    static func words(from terms: [String]) -> WebQuery?   // nil with fewer than 3 letters or digits
    var searchTerms: String { get }                  // mood.searchQuery, or the words
    var label: String { get }                        // mood.label, or the words
}

@MainActor final class WebDiscover: ObservableObject {
    enum Status { case off, noKey, keyRejected, limitReached, ready }
    static let resultLifetime: TimeInterval          // 10 min
    @Published private(set) var isFetching: Bool
    init(store: LibraryStore)
    init(store: LibraryStore, cacheRoot: URL?, configuration: URLSessionConfiguration? = nil)   // tests: temp folder, stubbed network
    var hasAPIKey: Bool { get }
    var status: Status { get }                       // for the menu; .ready = a search can start now
    /// GIPHY's results for the query from the last 10 minutes, in GIPHY's order; nil when there are none.
    func cachedGIFs(for query: WebQuery) -> [WebGIF]?
    /// Cached at once, else the running or a new search; nil when nothing can be searched or it failed. The search outlives the caller.
    func gifs(for query: WebQuery) async -> [WebGIF]?
    func isSearching(_ query: WebQuery) -> Bool
    /// Starts the query's search unless fresh or running (the early search while a face is held).
    func warm(_ query: WebQuery)
    /// The `page`th group of `size` (page 0 the first `size`; start = (page mod n) × size mod n, wrapping around; a negative page is 0; with ≤ size GIFs every page is all of them): the GIPHY row's page.
    static func page(_ page: Int, of gifs: [WebGIF], size: Int) -> [WebGIF]
    // Each also takes a Mood (= .mood(mood)).
    func cachedStill(for gif: WebGIF) -> NSImage?
    func still(for gif: WebGIF) async -> NSImage?    // fixed_width_small_still through the HTTP cache
    func preview(for gif: WebGIF) async -> NSImage?  // fixed_width_small (animated) through the HTTP cache
    /// The full GIF as a file in Web/files to copy or drag; nil after 8 s (the download continues).
    func prepareForCopy(_ gif: WebGIF) async -> URL?
    func prefetchForCopy(_ gifs: [WebGIF])           // first three, into the HTTP cache only (no file)
    func pruneCache()                                // copy files older than 1 h, and earlier versions' <mood>.json files
}
```
Compliance with GIPHY's integration rules: results are shown in GIPHY's order, unfiltered, never mixed with the user's memes, never written to disk. Results, running searches and failures are kept per `WebQuery`. A search: the GIPHY search for `query.searchTerms` (a mood's one short phrase, or the typed words) with `limit=24` (`WebFetcher.resultLimit`: four rows' worth, so the same mood caught again shows other GIFs without another search; GIPHY counts searches, not results) and `offset=0` (tried once more after a dropped connection, timeout or 5xx, if the hourly limit allows; the retry counts) on an API session without caching; results kept in memory for `resultLifetime`. Media (stills, previews, full GIFs) come from a second session with a `URLCache` (16 MB memory, 64 MB disk in Web/HTTP, `.useProtocolCachePolicy`) and `httpMaximumConnectionsPerHost` 8; decoded stills stay in an `NSCache` (200). Full GIFs are written to Web/files only to be copied or dragged, and deleted after an hour. 429 pauses all searches for 10 min; 401/403 makes that key wait 10 min (`status` says which). API key: `store.settings.giphyAPIKey` (non-empty) ?? `Bundle.main.object(forInfoDictionaryKey: "GiphyAPIKey") as? String` (non-empty and not starting with "$("). Rate guard: at most 90 network searches per rolling hour (timestamps persisted in Web/rate.json).

`WebGIF` (GIFProvider.swift) also carries `creator: String?` from the result's `user` (display name, else username).

### Web/MemeTemplates.swift

```swift
struct MemeTemplate: Codable, Hashable, Sendable { let id: String; let name: String; let url: URL; let width: Int; let height: Int; var ref: TemplateRef }
@MainActor final class MemeTemplates {
    static let listLifetime: TimeInterval            // 24 h
    static let fileLifetime: TimeInterval            // 1 h
    init(store: LibraryStore, cacheRoot: URL?, configuration: URLSessionConfiguration? = nil)   // nil = ~/Library/Caches/MemeMe/Templates
    var isEnabled: Bool { get }                      // settings.webDiscoverEnabled
    var cachedList: [MemeTemplate]? { get }          // memory, else templates.json in the cache folder (any age); nil when off
    func templates() async -> [MemeTemplate]?        // the list from the last day, else a fetch (an older list if Imgflip doesn't answer; retried after 60 s)
    func cachedImage(for template: MemeTemplate) -> NSImage?
    func image(for template: MemeTemplate) async -> NSImage?        // downsampled to 320 px, through the HTTP cache
    func prepareForCopy(_ template: MemeTemplate) async -> URL?     // files/<id>.<ext>; nil after 8 s (the download continues)
    func prefetchForCopy(_ template: MemeTemplate)
    func pruneCache()                                // copy files older than an hour
    nonisolated static func parseList(_ data: Data) -> [MemeTemplate]?   // Imgflip's order; https only; each id once
}
```
`GET https://api.imgflip.com/get_memes` (no key; `{"success": true, "data": {"memes": [{"id", "name", "url", "width", "height"}]}}`), at most once a day, written to Templates/templates.json. Images load through one session with a `URLCache` (8 MB memory, 64 MB disk in Templates/HTTP); decoded tiles stay in an `NSCache` (120). Off (no requests, nil list) with Web Discover.

### Stickers/StickerMaker.swift

```swift
struct StickerCut {
    let pngURL: URL
    let faceEmbedding: [Float]     // feature print of the face crop (box expanded 20 %)
    let face: FaceFeatures?
    let faceShape: FaceShape?      // the face's details, the tongue read from the source photo (drawn once per call by RGBAPixels)
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
`func makeOwnSticker(fromCapture url: URL) async throws -> (item: LibraryItem, isNew: Bool)?`: "Save as sticker" for a capture. Analyzes the PNG (no text), cuts out the largest face with `StickerMaker.makeStickers` (no sticker policy, eligibility or grouping) and adds `kind .mine`, `tier .meme`, `isSticker true`, `source "Camera"`, `displayName` "You — " + mood label (face, its shape and pose), `poseRevision`, `faceShape` and `faceRevision` current; nil when nothing could be cut; an identical sticker already kept is returned instead, with `isNew false`.
`func removeOwnSticker(id: UUID)`: Undo for it: `store.remove(ids:)` (deletes the PNG under rootURL) and save.

Sticker items: `kind .friend`, `isSticker true`, `source "Friend sticker"`, `sourceDetail` = source file name, `displayName` = person name (or "New face") + " — " + mood label of its face (and `faceShape`: "New face — tongue out"), `faceShape` from the cut, `faceRevision` current, `tier .meme`. Matching only runs when `groupFaces == true`: `.confident` → set `personID` and add the embedding; `.likely` → leave `personID` nil until `confirm`; `.newFace` → create an unnamed `Person` with the embedding and assign it.

### System/Clipboard.swift

```swift
enum Clipboard {
    /// Writes a pasteable representation of `fileURL` for `item`; returns the pasteboard changeCount after writing.
    @MainActor @discardableResult static func copy(fileURL: URL, item: LibraryItem) throws -> Int
    /// A capture's bytes (GIF or PNG) as `fileName`, written the same way; returns the temp file.
    @MainActor @discardableResult static func copy(data: Data, fileName: String) throws -> URL
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
    static let panelWidth: CGFloat          // 736: 16 + mirror 120 + 16 + 6 × 88 + 5 × 8 + 16
    static let background: Color            // #1E1F24
    static let surface: Color               // #26282E
    static let border: Color                // #3A3C44
    static let text: Color                  // #ECECEF
    static let mutedText: Color             // #A9ACB5
    static let accent: Color                // #7AA2FF
    static let amber: Color                 // #F5C451
    static let green: Color                 // #5FD38D
    static let columns: Int                 // 6
    static let rows: Int                    // 1
    static var resultLimit: Int { get }     // columns * rows
}
```

### UI/PanelController.swift

```swift
@MainActor final class PanelController: NSObject {
    init(model: AppModel)
    var isVisible: Bool { get }
    func toggle()
    func show()   // captures NSWorkspace.shared.frontmostApplication before showing; calls model.panelWillShow; non-activating NSPanel; top-center under the menu bar
    func hide()                         // orders out, calls model.panelDidHide, reactivates the previous app if it is no longer frontmost
}
```
NSPanel subclass: `styleMask [.borderless, .nonactivatingPanel]`, `canBecomeKey true`, `canBecomeMain false`, `isFloatingPanel true`, `level .floating`, `collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]`, `hidesOnDeactivate false`, `backgroundColor .clear`, `hasShadow true`; `sharingType` stays at the default, so screenshots and screen recordings include it. Hosting: `NSHostingView(rootView: PanelView(model:))`, sized to fit (width `Theme.panelWidth`, 736). While visible: a local key-down and key-up monitor (keys in DESIGN.md: Esc, ↵/Enter, digits 1–9 as typed on the active keyboard layout, arrows, Space with empty query, Tab / Shift-Tab, ⌘V) and a global mouse-down monitor (outside click → hide). `model.onRequestClose = { [weak self] in self?.hide() }`.

Key handling:
- Esc → `if !model.handleEscape() { hide() }`
- ↵ / Enter → `model.commitFocused()`
- digits 1–9 as typed on the active keyboard layout (main row or keypad; Shift allowed, no ⌘/⌃/⌥; 0 is swallowed) → `model.commitNumbered(index: n - 1)` (your memes only)
- ←/→ → `model.moveFocus(dx: ∓1, dy: 0)` only when `model.queryText` is empty; ↑/↓ → `model.moveFocus(dx: 0, dy: ∓1)`
- Space with empty query → `model.snap()`; ⇧Space with empty query → `model.openCapture()` when `model.canOpenCapture`
- In the capture view (`model.isCaptureOpen`): Esc → `model.handleEscape()` (cancels a capture in progress, else closes the view); Space down (not a repeat) → `model.capture.press(from: .space)`, Space up (whatever the modifiers) → `model.capture.release(from: .space)`; ↵ / Enter down → `press(from: .key)`, up → `release(from: .key)` (like Space, so the panel never closes while the key is down); ←/→ → `model.capture.cycleFilter(by: ∓1)`; other keys without ⌘/⌃/⌥ are swallowed
- Tab → `model.moreLikeFocused()`; Shift-Tab → `model.backToFace()`
- ⌘V → consume only if `model.pasteFromClipboard()` returns true
- everything else passes through to the focused search field.

### UI/PanelView.swift and subviews

```swift
struct PanelView: View { @ObservedObject var model: AppModel }                       // compact layout per DESIGN.md
struct MirrorColumn: View { init(model: AppModel) }                                  // mirror (CameraPreviewView / silhouette / image / drop well), readout or hint, Find my memes
struct ResultGrid: View { @ObservedObject var model: AppModel }                      // your memes: ownRows × 6 LazyVGrid of ResultTile; nothing with none
struct TemplateRow: View { @ObservedObject var model: AppModel }                     // the middle row: RowHeader "Classic memes" / "from Imgflip", 6 templates shown whole (aspect fit)
struct GiphyRow: View { @ObservedObject var model: AppModel }                        // the bottom row: RowHeader "GIFs" / PoweredByGiphyMark, 6 GIPHY tiles in GIPHY's order
struct RowHeader<Trailing: View>: View { init(_ title: String, @ViewBuilder trailing: () -> Trailing) }   // 16 px: 11 pt semibold name, attribution on the right
struct PoweredByGiphyMark: View                                                      // "Powered by" + GIPHY's logo
struct ResultTile: View { let result: RankedResult; let number: Int?; let isFocused: Bool; let isNew: Bool; @ObservedObject var model: AppModel }
struct FooterView: View { @ObservedObject var model: AppModel }                     // only while footer != .hidden: indexing, added, update
struct SetupCardView: View { @ObservedObject var model: AppModel }
struct AnimatedImageView: NSViewRepresentable { init(url: URL); init(image: NSImage) }   // NSImageView with animates = true
struct CaptureView: View { init(model: AppModel) }                                   // replaces the strip while model.isCaptureOpen
```
- `PanelView` shows `CaptureView` instead of the strip and footer while `model.isCaptureOpen`; drops are ignored there and the search field gets the focus back when it closes.
- `MirrorColumn` puts a 26 px camera button (SF Symbol `camera.fill`, 55 % black circle) at the mirror's bottom right while `model.canOpenCapture`.
- `CaptureView`: a 300 × 300 stage (`CapturePreview`, an `NSView` whose layer contents are set straight from `camera.onCapturePreview`, aspect fill) with a white flash on each photo, a coral progress ring while recording and the shutter (a `DragGesture(minimumDistance: 0)`: press → `capture.press(from: .mouse)`, release → `capture.release(from: .mouse)`); beside it the title, the status line, the filter chips (4 columns) and "Back to memes"; the legend below.
- The search field is a SwiftUI `TextField` bound to `$model.queryText`, focused on appear (`@FocusState`), plain style.
- Drops on the whole panel: `.onDrop(of: [.fileURL, .image], …)` → `model.search(withImageAt:)`.
- Tiles: `.onHover { if $0 { model.hover(index:) } }`, `.onTapGesture { model.commit(index:) }`, `.onDrag { model.dragItemProvider(index:) ?? NSItemProvider() }`, with slots from `TileGrid` (GIPHY tiles: `model.giphySlot(offset)`, classic memes: `model.templateSlot(offset)`).
- Your memes' thumbnails via `ThumbnailCache.shared`; the focused GIF tile shows `AnimatedImageView(url:)`. GIPHY tiles load `model.web.still(for:)` and, while focused, `AnimatedImageView(image: await model.web.preview(for:))`.
- `TemplateRow` shows while `model.showsTemplateRow`, `GiphyRow` while `model.showsGiphyRow`. The GIFs header's right side is `PoweredByGiphyMark` ("Powered by" + `Bundle.main.image(forResource: "GIPHYLogo")`, Resources/GIPHY/GIPHYLogo.png, copied by build-app.sh, else the words "Powered by GIPHY"); the classic memes' is "from Imgflip". Classic memes' tiles load `model.templates.image(for:)`.
- The right column: search field, NamingRow, then 12 px apart `ResultGrid` (while `model.ownRows > 0`, else an 88 px "Your memes will show here" well), `TemplateRow` and `GiphyRow`. While a drag is over the panel (`isDropTargeted`, unless `model.isDraggingTile`) a dashed accent `DropCard` covers them ("Drop to search with it"). A tile's own drag (`TileDragEvents.dragDidBegin`) sets `isDraggingTile` until the button is up (300 ms longer when let go over the panel, so its own drop is ignored) or the panel hides; `handleDrop` refuses drops meanwhile.
- `MirrorColumn` shows `model.readout` (word 17 pt semibold, then a symbol and "your face" / "your pose" / "your face and pose"; 45 % while `holdProgress ≥ 0.05`) instead of the hint, and, while `model.ownRows == 0`, "Look in Documents…" (text mode, Documents not watched) or "Find my memes" (`model.offersFindMyMemes`: no folders collected, not indexing). A green ring flashes on the mirror when `model.poseCatches` changes.

### UI/HUDController.swift

```swift
@MainActor final class HUDController {
    static let shared: HUDController
    /// Pill at the top center of the main screen for 1.6 s (or until replaced). Optional 28 px thumbnail.
    /// With an action: a button, clicks taken without activating MemeMe (first mouse), 5 s and while hovered.
    func show(_ message: String, thumbnail: URL? = nil, action: HUDAction? = nil)
    func dismiss()
}
struct HUDAction { let title: String; let perform: @MainActor () -> Void }
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
    /// The value of the "TeamIdentifier=" line (a line of its own) in `codesign -dv --verbose=2` output; nil when
    /// the line is missing, says "not set" (ad-hoc) or isn't a Team ID (^[A-Z0-9]{10}$).
    static func parseTeamIdentifier(fromCodesignOutput output: String) -> String?
    /// nil unless `team` matches ^[A-Z0-9]{10}$ (nothing else reaches the requirement text); else
    /// `=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate
    /// leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "<team>"` (one line):
    /// signed with a Developer ID Application certificate of that team.
    static func developerIDRequirement(team: String) -> String?
    /// Runs `codesign -dv --verbose=2 <app>` off the main actor and parses its output (stderr included) with
    /// `parseTeamIdentifier(fromCodesignOutput:)`; nil on any failure, for ad-hoc and for unsigned code.
    static func teamIdentifier(ofAppAt url: URL) async -> String?
    /// Checks the downloaded DMG itself (CI signs MemeMe.dmg with the same Developer ID) before it is mounted or
    /// shown in Finder: `codesign --verify --strict -R developerIDRequirement(team:) <dmg>`, off the main actor.
    /// Any exit status other than 0, or a `requiredTeam` that isn't a Team ID: `.signatureInvalid`.
    static func verifyDMGSignature(_ dmg: URL, requiredTeam: String) async throws
    /// Mounts the DMG read-only (hdiutil attach -nobrowse -readonly -noautoopen -mountpoint), finds the .app
    /// (MemeMe.app first), validates it, checks `codesign --verify --deep --strict` and, when `requiredTeam` is
    /// set, also `codesign --verify --deep --strict -R developerIDRequirement(team:)` (exit status other than 0,
    /// or `requiredTeam` isn't a Team ID: `.signatureInvalid`), copies it with `ditto` to
    /// `stagedURL(for:build:)`, and always detaches. Runs the tools off the main actor.
    func stage(dmg: URL, manifest: UpdateManifest, currentApp: URL, bundleIdentifier: String,
               requiredTeam: String? = nil) async throws -> URL
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
    /// When the running app is signed with a Team ID, the update must be too: the team is looked up once
    /// (`UpdateInstaller.teamIdentifier(ofAppAt: Bundle.main.bundleURL)`, when the first install starts, never on
    /// the main thread) and awaited right after the download. With a team, `UpdateInstaller.verifyDMGSignature`
    /// runs before anything mounts or opens the DMG (a failure deletes it and shows "The update didn't check out",
    /// never Finder), then the team goes to `stage(…requiredTeam:)` for the app inside; without one (ad-hoc,
    /// local builds) it's nil and only the integrity checks run.
    func installAvailableUpdate()
    /// Runs when an install starts, from every Update path; AppModel closes the panel here.
    var willInstall: (@MainActor () -> Void)?
}
```

### App/StatusItemController.swift (updates)

- Observes `model.updates.$available`: the icon is `face.smiling` with a small dot when an update is available (one template image, so it follows the menu bar's color).
- Menu: with an update, the first item is "Update to MemeMe <displayVersion>…" (→ `model.installUpdate()`), or "Updating MemeMe…" disabled while `phase` is `.downloading`/`.installing`, then a separator. When `model.updates.isEnabled`, a section before Quit: "Check for Updates…" (→ `model.updates.checkFromMenu()`) and a disabled "Version <installedDisplayVersion>".

### App/CaptureModel.swift

```swift
enum CapturePhase: Equatable { case idle, pressing, recording(progress: Double), saving }
struct CaptureResult { let data: Data; let isGIF: Bool; let stickerFrame: CGImage? }
@MainActor final class CaptureModel: ObservableObject {
    @Published private(set) var filter: CameraFilter
    @Published private(set) var phase: CapturePhase
    @Published private(set) var flashCount: Int        // bumped per photo
    @Published private(set) var failed: Bool
    @Published private(set) var awaitingRelease: Bool  // a clip stopped at 3 s waits for the shutter to be let go ("Let go to copy it.")
    var onCaptured: ((CaptureResult) -> Void)?
    static let holdThreshold: TimeInterval             // 0.35
    static let minimumClipFrames: Int                  // 4
    init(camera: CameraController)
    var isBusy: Bool { get }
    func select(_ filter: CameraFilter); func cycleFilter(by step: Int)
    func activate(); func deactivate()                 // the view opened (filter None) / closed
    @discardableResult func press(from input: ShutterInput) -> Bool   // enum ShutterInput { case mouse, space, key }; false when refused
    func release(from input: ShutterInput)              // only the input that pressed can release
    func cancel()
}
```
A press held 0.35 s starts a clip (`camera.beginClip`); the release (or 3 s) ends it. A release before that takes a photo (`camera.captureStill`, PNG). A clip under 4 frames becomes a photo of its best frame (or of the next frame). A clip stopped at 3 s while the shutter is still down is handed over on release, so the panel stays (swallowing Space's key repeats) until then. Encoding runs detached at user-initiated priority; `cancel` (Esc, close) drops a capture in flight.

### App/AppModel.swift

```swift
enum PanelMode: Equatable { case prompt, warming, live, text, image, moreLike, cameraOff, cameraBusy }
enum HintAction: Equatable { case clearPins, backToFace, keepImage, turnOnCamera, useCamera }
struct PanelHint: Equatable { var title: String; var subtitle: String?; var actionTitle: String?; var action: HintAction? }
enum FooterState: Equatable { case hidden, indexing(count: Int), added(IndexBatch), update(UpdateManifest) }
struct NamingCandidate: Identifiable, Equatable { let personID: UUID; let stickerCount: Int; let sample: LibraryItem?; var id: UUID { personID } }
struct NamingPrompt: Equatable { var name: String; var candidates: [NamingCandidate] }
enum DropOutcome { case kept(IndexBatch), stickers(StickerBatch), nothing }

@MainActor final class AppModel: ObservableObject {
    @Published var queryText: String
    @Published private(set) var mode: PanelMode
    @Published private(set) var results: [RankedResult]        // ≤ Theme.resultLimit
    @Published private(set) var newResultIDs: Set<UUID>         // amber ring for 600 ms
    @Published private(set) var ownRows: Int                     // rows of your memes: 1, or 0 (none, nothing drawn); enough for what is shown
    @Published var focusedIndex: Int                             // a TileGrid slot: your memes, then the classic memes row, then the GIPHY row
    @Published private(set) var giphyResults: [WebGIF]           // ≤ Theme.columns, GIPHY's order: the current page of what GIPHY gave (WebDiscover.page)
    @Published private(set) var giphyQuery: WebQuery?            // the face's mood, or typed words
    @Published private(set) var isGiphyLoading: Bool
    @Published private(set) var giphyUnavailable: Bool
    @Published private(set) var showsGiphyRow: Bool              // Web Discover on and a key (set when the panel opens)
    @Published private(set) var templateResults: [MemeTemplate]  // ≤ Theme.columns
    @Published private(set) var templateQuery: WebQuery?
    @Published private(set) var isTemplatesLoading: Bool
    @Published private(set) var templatesUnavailable: Bool       // no list at all
    @Published private(set) var showsTemplateRow: Bool           // Web Discover on (set when the panel opens)
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
    @Published private(set) var heldPose: PoseBadge?     // PoseBadge.of(tracker.query) for a face search, nil otherwise
    @Published private(set) var readout: MoodReadout?     // the face search's word (mood label) and source (.face / .pose / .faceAndPose) while live; nil with pins, or for a word from the face (.face or .faceAndPose) while the face is missing
    @Published private(set) var poseCatches: Int         // +1 when a new query (or Space) brings a heldPose other than the one before: the mirror's green flash
    @Published private(set) var hotKeyAvailable: Bool
    @Published private(set) var isPanelVisible: Bool
    @Published var isDraggingTile: Bool                  // a tile is being dragged out (set by PanelController): the panel ignores its own drop
    @Published private(set) var isCaptureOpen: Bool

    let store: LibraryStore
    let camera: CameraController
    let capture: CaptureModel
    let indexer: LibraryIndexer
    let web: WebDiscover
    let templates: MemeTemplates                     // cache: webCacheRoot's sibling "Templates" in tests
    let friends: FriendService
    let updates: UpdateChecker                       // UpdateChecker(bundle: .main); disabled in tests (no feed URL)

    var onRequestClose: (() -> Void)?

    init(store: LibraryStore)
    init(store: LibraryStore, webCacheRoot: URL?)   // tests pass a temp cache folder; both remove saved GIPHY picks and items whose kept file is gone (store.removeSavedWebItems, removeItemsWithMissingFiles)
    var requestsCameraAccessOnShow: Bool             // default true; tests turn it off
    func start()                                     // after launch: SystemConditions.startMonitoring(), indexer.startWatching(), a cleanup every 10 min (web.pruneCache(), templates.pruneCache(), Clipboard.removeStaleCopies()), updates.start()
    func setHotKeyAvailable(_ available: Bool)

    // Panel lifecycle
    func panelWillShow(previousApp: NSRunningApplication?)   // dismisses a HUD still showing and forgets kept files deleted in Finder (indexer.removeItemsWithMissingFiles) first
    func panelDidHide()

    // Input (indices are TileGrid slots)
    var focusedPick: Pick? { get }                   // enum Pick { case meme(LibraryItem), gif(WebGIF), template(MemeTemplate) }
    var canMoreLikeFocused: Bool { get }             // only for your memes
    func giphySlot(_ offset: Int) -> Int
    func templateSlot(_ offset: Int) -> Int
    static func pickTemplates(for query: WebQuery, from list: [MemeTemplate], page: Int = 0) -> [MemeTemplate]   // MemeTemplateCatalog, ≤ Theme.columns; a mood's `page`th group (pick(for:from:limit:page:)), typed words have no pages
    func commit(index: Int)
    func commitFocused()
    func commitNumbered(index: Int)                  // 1–9: your memes only
    func moveFocus(dx: Int, dy: Int)
    func hover(index: Int)
    func togglePin(_ region: FaceRegion)
    func handleEscape() -> Bool                      // in the capture view: cancels a capture in progress, else closes the view
    func snap()
    // Send yourself
    var canOpenCapture: Bool { get }                 // mode == .live, no setup card, camera running
    func openCapture()                               // commitToken += 1 (a pick still downloading is dropped), isCaptureOpen = true, capture.activate(), tracker.clearHold(); the search pauses
    func closeCapture()                              // capture.deactivate(); in live mode the face-missing clock restarts (liveSince = now); also on hide and on a new session
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
    var offersFindMyMemes: Bool { get }              // no watched folders and not indexing
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
- `panelWillShow`: remember previous app + bundle id; reset query state; mode = `.cameraBusy` if `camera.isInUseByAnotherApplication`, `.prompt` if authorization is `.notDetermined`, `.cameraOff` if denied/restricted, else `.warming` (start camera); results = recent for that app (or the newest own memes); with none at all, or when no face can be read (`.cameraOff`, `.cameraBusy`, `.prompt`), the GIPHY row shows `.mood(.reaction)` and the classic memes row the most popular templates; footer per rules; on first run (`!settings.hasCompletedFirstRun`) request camera access 0.6 s after show (activate the app just for the prompt).
- `camera.onSample` → `tracker.ingest`; the mood of `tracker.candidate` (the expression being held; `MoodClassifier.mood(for:pose:shape:baseline:)` with the sample's shape, as for the query) goes through `EarlyMoodTrigger` (same mood for 0.2 s) → `web.warm(mood)`; publish `holdProgress`; on query change: mood → weights (`automatic(...).pinning(pins)`) → your memes ranked at once (`store.items` without `.web`); the GIPHY row shows `web.cachedGIFs(for: .mood(mood))` at once, else placeholders until `await web.gifs(for:)` (its own task and generation), and the classic memes row `pickTemplates(for: .mood(mood), …)` from `templates.cachedList` at once, else after `await templates.templates()` (its own task and generation). Paging: the tracker catching a new query (or Space snapping one) runs the search with `newQuery`; when the mood is the one already showing, the rows turn instead of staying put: `giphyPage += 1` (when GIPHY's results are in and more than `Theme.columns`; `giphyFound` keeps everything GIPHY gave for `giphyQuery`) and `templatePage += 1` (moods only, from the kept list). A new mood, or the rows being cleared when the panel opens, starts both at page 0; re-showing the same face (pins, Esc, library changes, back to the face) leaves them as they are. Image and more-like searches leave both rows alone. `normalizeFocus` keeps the focus on a tile: until the user moves it, `startSlot` (`TileGrid.firstSlot`, top to bottom: the first meme, else the first classic meme, else the first GIF; the classic memes row's first slot while nothing has come) for Recent and the face, and nothing for a typed, image or more-like search that finds no meme (with no row of memes drawn, the first web tile). After the user moves it, a focus whose tile went moves to the last tile of its row (its start while the row loads), a meme's focus whose row went to the first web tile, and a focus in a web row whose source went off to the first tile. The search's word goes to the readout (`MoodReadout`: `.pose` for a pose word or a pose without one and no face, `.faceAndPose` for a pose without one over a face, else `.face`; none for "reaction" without a pose). `newResultIDs` for ids not shown before (cleared after 600 ms). The row's first GIF and a focused GIF prefetch their full GIF. No face for 1.5 s → hint "Can’t see your face". `camera.bodyWidth` feeds a `StandingBackDetector`; while it says standing back, that hint is "Reading your pose" instead.
- Text changes (debounced 80 ms) → text mode; camera stops if typing began within 1 s of show, otherwise `showsFaceToken = true`; naming prompt when `TextQuery.possibleName` is set, no results, and `friends.unnamedPeople` is non-empty. The typed terms (`TextQuery.parse(…).terms`: no filter words or people's names) → `WebQuery.words(from:)`: the classic memes row shows its templates at once; the GIPHY row shows GIPHY's results once typing has paused 0.6 s (any edit restarts the wait; at once when cached; while the naming prompt shows, nothing when `possibleName` isn't `MemeTemplateCatalog.isMemeWord` (mood words, mood labels, the table's search words, minus names such as "jordan" or "kermit"); a nil query leaves both rows alone). Until the user moves the focus, `normalizeFocus` keeps it on `startSlot` as rows fill in, so with no memes the first classic meme takes it (the first GIF when there are no classic memes). Empty text → back to live (restart camera if it was stopped); leaving typed words clears a GIPHY row showing them and puts the classic memes back to the popular ones.
- `commit`: resolve file (a GIPHY GIF → `await web.prepareForCopy`, a classic meme → `await templates.prepareForCopy`, HUD "Copying…" if it takes > 150 ms); `Clipboard.copy` (a GIPHY GIF as "reaction.gif", a classic meme as "reaction.png": kind `.web`, source "Imgflip", hash "imgflip:<id>"); for your memes only: increment `timesSent`, set `lastSentAt`, `recents.record` (GIPHY GIFs are never kept or listed as recent); first run → `showSetupCard = true` and `hasCompletedFirstRun = true` (panel stays open); otherwise close and HUD "Copied “<title>” · ⌘V — not sent" with the copied file as thumbnail. ↵ is ignored within 300 ms of the last text edit.
- A capture (`capture.onCaptured`): `commitToken += 1`; `Clipboard.copy(data:fileName:)` as "reaction.gif" / "reaction.png"; the sticker source is that PNG (photo) or the clip's best frame written as `capture.png` in a fresh clipboard folder; close the capture view and the panel; HUD "Copied your photo · ⌘V — not sent" (or GIF) with the copy as thumbnail and the action "Save as sticker" → HUD "Making your sticker…", `friends.makeOwnSticker(fromCapture:)`, then "Saved “<name>” as a sticker" with the action "Undo" (`friends.removeOwnSticker`, then "Sticker removed"), "Already one of your stickers" when it was kept before (both skipped when the panel was reopened meanwhile: they would cover it), or "Couldn’t find you in that one." (shown regardless). Captures are not recorded as sent and don't count as the first pick.
- Persist the store (debounced 2 s) after changes; persist `tracker.baseline` into settings on hide.
- Footer priority: `.indexing` > `.added` (panel visible) > `.update(manifest)` (when `updates.available` is set, `updates.phase` is `.idle` or `.checking` and `UpdatePolicy.shouldOfferInPanel(manifest, skippedBuild: settings.skippedUpdateBuild)`) > `.hidden` (no footer at all). AppModel subscribes to `updates.objectWillChange` like it does to the indexer and refreshes the footer on the next main-actor turn.
