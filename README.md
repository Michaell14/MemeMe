# MemeMe

A tiny macOS menu-bar app for reaction images. In any chat, press **⌥M**, type or make a face, and pick a reaction. It is copied to the clipboard and you are back in the chat. Paste it with ⌘V. MemeMe never pastes or sends anything for you.

- **Search first, your face to refine.** The panel opens on a search field with your recent picks under it. Type to search, or press **⌘F** and hold an expression: results follow it. Click your brows, eyes or mouth to lean the search on that part, or grab the face itself to refine it further (push a feature, resize what counts, draw on it). Results come from memes you already have on your Mac, stickers you made, and (optionally) GIPHY and the classic memes; the source menu beside the search field shows **All Sources** or one of them.
- **One commit.** ↵, ⌘1–⌘9, or a click copies the result and closes the panel. **Actions (⌘K)** copy a link or Markdown, add to Favorites, find more like it, or show it in Finder.
- **Small.** Swift and Apple frameworks only, no third-party packages, no bundled ML models. The camera runs only while face search is on.

Requires macOS 14 (Sonoma) or later, on Apple silicon or Intel.

## Get the app

Download `MemeMe.dmg` from the website or from the [latest release](https://github.com/Michaell14/MemeMe/releases/latest). Open it and, in the window that appears, drag MemeMe onto the Applications folder.

Releases are signed with a Developer ID and notarized by Apple, so there is nothing to allow in System Settings: on the first launch macOS asks once whether to open an app downloaded from the internet, and MemeMe asks for the camera.

Builds that are not releases (CI artifacts from branches and pull requests, local builds) and releases from before Developer ID signing are signed ad hoc and not notarized, so Gatekeeper blocks their first launch:

- **macOS 15:** open the app once, then go to **System Settings → Privacy & Security** and click **Open Anyway**.
- **macOS 14:** Control-click the app in Finder, choose **Open**, then confirm.
- Or remove the quarantine flag from Terminal: `xattr -dr com.apple.quarantine /Applications/MemeMe.app`

After that, MemeMe offers new versions itself (see [Releases and updates](#releases-and-updates)).

### From CI

Every push and pull request builds the app on GitHub Actions, including the ones that are not released.

1. Open the repository's **Actions** tab, then the latest successful **CI** run.
2. Download the **MemeMe-app** artifact and unzip it (GitHub wraps it in a zip). You get `MemeMe.dmg`.
3. Open it and drag MemeMe into Applications. Release runs build the signed, notarized DMG; the others are signed ad hoc, so Gatekeeper asks as above.

### Build it yourself

You need Xcode 16 or later (the Swift 6 toolchain; the package uses the Swift 5 language mode). CI builds with Xcode 26.3, whose macOS 26 SDK has Apple's on-device model (FoundationModels) for naming poses; built with Xcode 16, the app leaves it out and names poses by its own rules only. The framework is weak-linked, so the app still runs on macOS 14 and 15, and CI fails a build that links it strongly.

```sh
swift build                       # debug build of everything
swift test                        # unit tests
GIPHY_API_KEY=your-key ./scripts/build-app.sh
./scripts/build-dmg.sh            # optional: build/MemeMe.dmg
open build/MemeMe.app
```

`scripts/build-app.sh` builds a release binary (universal when possible; builds with an update feed must be universal and fail otherwise), assembles `build/MemeMe.app` with `Resources/Info.plist`, writes the version, the update feed and the GIPHY key into the bundle and signs it, ad hoc unless told otherwise. `scripts/build-dmg.sh` packs the app and an Applications link into `build/MemeMe.dmg`. Opening it shows the usual install window: MemeMe on the left, an arrow, Applications on the right. [dmgbuild](https://github.com/dmgbuild/dmgbuild) writes that layout; the script installs it, pinned by hash (`scripts/dmgbuild-requirements.txt`), into `build/.dmgbuild-venv`. It needs Python 3.10 or later (`python3`, or set `PYTHON`); without one the DMG is built without the layout. The window is `scripts/dmg-settings.py` and its background is `Resources/DMG/background.html`; after changing the HTML, render the PNGs again with `node scripts/render-dmg-background.cjs` (needs Playwright) and commit them. Ad-hoc builds use the version that says how to get past Gatekeeper. The build script reads these environment variables, all optional:

- `GIPHY_API_KEY`: without it the app is built with an empty key.
- `APP_VERSION`: the marketing version, `CFBundleShortVersionString`. Defaults to the `VERSION` file.
- `APP_BUILD`: the build number, `CFBundleVersion`. Defaults to the commit count (`git rev-list --count HEAD`).
- `UPDATE_FEED_URL`: the `latest.json` the app checks for updates. Empty by default, so local builds never check. CI sets `https://github.com/Michaell14/MemeMe/releases/latest/download/latest.json`.
- `CODESIGN_IDENTITY`: `-` (the default) signs ad hoc, which is all a local build needs. A Developer ID Application identity from your keychain (its name or SHA-1) signs with the hardened runtime, a secure timestamp and `Resources/MemeMe.entitlements` (camera access); `build-dmg.sh` then signs the DMG too. `scripts/notarize.sh <file> [<path to staple>…]` notarizes and staples, with an App Store Connect API key in `NOTARY_KEY_PATH`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`.

Run the app from the bundle rather than with `swift run`: camera access and Open at Login depend on the bundle's Info.plist and identity.

## Releases and updates

Every change to the app on the default branch is released automatically. When `Sources`, `Resources`, `Package.swift`, `VERSION` or the build scripts changed since the last `v*` tag, CI signs and notarizes the build, then publishes GitHub Release `v<version>-<build>` (for example `v1.0-57`) with `MemeMe.dmg` and `latest.json`, the update feed, and marks it latest. The release notes are the subjects of the commits that changed the app.

- **Version numbers.** The marketing version is the `VERSION` file; bump it (say to `1.1`) for a new marketing version. The build number is the commit count, so every release has a higher one. The app shows both, as in **1.0 (57)**, and compares builds only.
- **Forcing a release.** **Actions → CI → Run workflow** on the default branch releases the current commit even when the app didn't change. A commit that already has a release keeps it unchanged; rebuilding needs a new commit, which gets a new build number.
- **Trying it locally.** `DRY_RUN=1 ./scripts/publish-release.sh build/MemeMe.dmg 1.0 57 14.0` writes `latest.json` and `release-notes.md` next to the DMG and publishes nothing.
- **In the app.** Release builds check `latest.json` 20 seconds after launch and then every 6 hours. When a newer build is out, the menu-bar icon gets a dot, the menu starts with **Update to MemeMe 1.0 (58)…** and the panel shows a line with **Update**. One click downloads the DMG, checks its size, SHA-256 and signature, replaces the app and restarts it. A Developer ID build only installs updates signed with a Developer ID of the same team; an ad-hoc copy checks only that the update is intact, so it can move to the signed build. **Check for Updates…** in the menu checks right away.
- **Permissions after an update.** Developer ID builds keep the camera and folder permissions across updates. The first update from an ad-hoc build to a signed one changes the app's identity, so macOS asks once more.
- **Signing.** Release builds are signed with the Developer ID Application certificate of team `XG6X9X3J6V` (hardened runtime, secure timestamp, the camera entitlement). CI notarizes the app with `notarytool` and staples it, packs the DMG, then signs, notarizes and staples the DMG, and checks both with `spctl` and `stapler`. Other builds are signed ad hoc and use no secrets. A release run with a missing secret fails before building, and nothing is published.
- **Secrets** (Settings → Secrets and variables → Actions):
  - `DEVELOPER_ID_P12`: the certificate "Developer ID Application: Michael Li (XG6X9X3J6V)" with its private key, exported from Keychain Access as a .p12, base64-encoded (`base64 -i Certificates.p12 | pbcopy`).
  - `DEVELOPER_ID_P12_PASSWORD`: the password chosen when exporting the .p12.
  - `NOTARY_KEY`: an App Store Connect API team key, `AuthKey_<id>.p8`, base64-encoded (`base64 -i AuthKey_<id>.p8 | pbcopy`).
  - `NOTARY_KEY_ID`: that key's ID.
  - `NOTARY_ISSUER_ID`: the issuer ID shown with the team keys (App Store Connect → Users and Access → Integrations).
  - `GIPHY_API_KEY`: the GIPHY key built into releases (see [GIPHY API key](#giphy-api-key)).
- **Certificate expiry.** The certificate expires on 2027-02-01. Releases signed before then stay valid (the signatures are timestamped), but CI can't sign new ones. Before then, create a new Developer ID Application certificate for the same team, export it with its private key as a .p12 and replace `DEVELOPER_ID_P12` and `DEVELOPER_ID_P12_PASSWORD`. Same team, so the updater and macOS permissions accept the new builds.

## Website

`site/index.html` is the one-page website, published as a claude.ai artifact. Its download button links to https://github.com/Michaell14/MemeMe/releases/latest/download/MemeMe.dmg, which always serves the newest release, so the download updates itself. Republish the page only when its text changes.

`./scripts/build-site.sh` writes a standalone copy to `build/site/index.html` that any static host can serve.

## Using it

| | |
|---|---|
| ⌥M | Open or close the panel (in any app, no permission needed) |
| ⌘F, or **Search with your face** at the bottom left | Turns the camera on (again turns it off). Then make a face: hold it for about 0.3 s; a different face needs about 0.6 s (the ring fills), or 0.3 s if you relax your face in between. Small changes count: stick your tongue out, wink, raise one eyebrow, purse your lips, smirk or roll your eyes, and the search goes by "tongue out", "wink", "raised eyebrow", "duck face", "smirk" or "eye roll". The same word caught again shows the next GIFs and classic memes |
| Strike a pose | Arms up, a T-pose, a flex, a dab, hands on hips, arms crossed, one arm up, a wave (palm open to the camera), a bow, hands on your head, a facepalm, a shrug, clapping, a thumbs up, peace, pointing: memes with that pose come first, GIPHY and the classic memes are searched for it, and the word beside the notch names the pose. Any other finger pattern (horns, hang loose, finger guns) counts as a hand sign too, except while a hand rests in front of you holding a phone or a mug. A pose with no word of its own (one arm flexed, horns, a hand on your chin) is named in a few words on your Mac ("flexing", "rock on", "thinking") and searched by them: by Apple's on-device model on macOS 26 with Apple Intelligence on (sparkles beside the word), else by MemeMe's own rules. Step back so your arms (and hips) are in view, and hold each pose for a second |
| Click your brows, eyes or mouth | Lean the search on that part: it counts most, and the search's word is read from it. Again goes back to the whole face |
| Space | Use the current face now, even a neutral one (only while the search field is empty) |
| ⌥S, ⇧Space or ✂ Clip me (while face search is on) | Clip your reaction as a sticker: tap for a still one, hold for a moving one of up to 3 s. You are cut out on your Mac (Apple's subject lifting), saved to My Stickers and copied at once, ready to paste; **Rename** or **Undo** on the notice, and chips to file it in your groups |
| ↵, ⌘1–⌘9, click | Copy the focused, numbered or clicked result and close (⌘1–⌘9: the tiles in order, row by row) |
| Arrow keys | Move the focus through the grid |
| ⌘K | Actions for the selected result: Copy, Copy Link (⇧⌘C), Copy Markdown (⌥⌘C), Add to Favorites (⌘S), More Like This (⌘M), a sticker's Groups (check one to file it there, or New Group…), Show in Finder (⇧⌘R), Open on GIPHY (⌘O), Delete Sticker (⌘⌫) |
| ⌘P, or the source button | Where results come from: All Sources, Favorites, On My Mac, My Stickers, GIPHY GIFs, GIPHY Stickers, Classic Memes |
| Typing | Search by words: text in images, labels, file names, sources, friends' names. Filter words: `mine`, `gif`, `sticker`, a friend's name. GIPHY's GIFs and the classic memes follow the words too ("sad", "guy looking back") |
| ⌘V or drop an image on the panel | Search with that image. It is not saved unless you click **Keep it** |
| Tab / Shift-Tab | The next / previous source (the panel opens on All Sources) |
| ⌘S, or ☆ on a tile you point at | Add one of your things to Favorites (again takes it out). GIPHY's GIFs and the classic memes can't be kept |
| My Stickers' chips | **All** (a row per group, then Ungrouped, each with See all ›), one group, **Ungrouped**, or **+** for a new group. Name groups of stickers (Reactions, Work, Sam & Jo…); a sticker can be in several. Right-click a group for Rename… or Delete Group (its stickers stay; Undo) |
| ⌘⌫ (search field empty), or right-click a sticker → Delete Sticker… | Delete one of your stickers from My Stickers, file and all (it asks first) |
| Right-click one of your memes | More like this; Esc goes back to your face |
| ⌘E, the sliders button or a click on the mirror | Edit the face the camera caught. Your brows, eyes and mouth glow by how much each counts. Drag a round dot to push a feature further (a brow, an eyelid, a pupil, a mouth corner, the lower lip, or the dot above the head to tilt it). Drag a ring's square out or in, pinch on a part, or use − and +, to change how much that part counts (0 ignores it). Your memes re-rank as you go and GIPHY follows once you let go. ⌘Z undoes, Reset goes back to the caught face, Esc goes back to your face |
| Esc | First closes a menu, then clears text, image or more-like, then turns face search off; then it closes |
| ⌥S, or ✂ in the panel (face search off) | Cut a sticker out of anything on your screen: click a subject, or draw around it (draw over another to add it, or over one you took to take it out), name it, tick the groups it goes in, then **Save** it to My Stickers or **Copy** it. Apple's subject lifting finds it, on your Mac |
| Drag a tile into a chat | Drops it into the message box and closes the panel; the clipboard is left alone |

**The menu-bar icon** has the settings: folders to collect from, pausing collection, Web Discover, the GIPHY key, what to do with photos of people, grouping friends' faces, forgetting your resting face, Open at Login, and showing the library in Finder.

**Drop images on the menu-bar icon** to keep them: files, images from a browser, or photos straight from Photos or Mail. Photos of people (not animated, little text, faces at least 6 % of the image height) become die-cut friend stickers. Everything else is kept as a meme. A popover reports what happened, with Undo.

## Permissions and privacy

- **Camera.** On only while face search is on (⌘F), and it stops when the panel closes. For the search, frames are analyzed on your Mac with Apple's Vision framework and then discarded. Nothing is uploaded. **Clip me** is the exception you ask for: the picture or clip you take is cut out on your Mac and kept as a sticker with your memes in `~/Library/Application Support/MemeMe/Stickers` (the camera's own frames are never written to disk), and its copy for pasting goes to a temporary file in `~/Library/Caches/MemeMe/Clipboard`, deleted within the hour once it is no longer on the clipboard. **Undo** on the "Saved" notice removes the sticker; later, delete its file from that folder (menu → Show Library in Finder) and MemeMe forgets it the next time the panel opens. MemeMe turns off macOS's gesture Reactions for itself by default (on macOS 14.4 and later), so a thumbs up or peace sign doesn't add balloons or fireworks to your search or your captures. Apart from that, MemeMe keeps only your "resting face": a handful of numbers (no image) that it learns from calm frames, so it can tell how much your face moved. **Forget My Resting Face** in the menu resets it.
- **Folders.** After **Find my memes** (or from the menu), MemeMe indexes images in Downloads, Desktop and your screenshot folder. macOS asks once per folder. Files are never copied or moved: the index stores features, a compact image fingerprint and the text found in each image (about 4 KB per meme). Personal photos and chat screenshots are sorted out and keep no face data or text. Only images you hand in yourself (dropped on the icon, or **Keep it**) are copied, into `~/Library/Application Support/MemeMe/Kept`.
- **Screen Recording.** Asked for the first time you cut a sticker from the screen (⌥S). The screenshot is taken only then, read on your Mac, never written to disk or sent, and gone when the cut closes; only the sticker you save is kept, in `~/Library/Application Support/MemeMe/Stickers`.
- **No Accessibility access, ever.** MemeMe only writes to the clipboard. You paste.
- **Network.** Only with Web Discover on:
  - **GIPHY** (with a key set): the one mood word for your face (for example "shocked reaction" or "tongue out") goes to GIPHY, sometimes a moment before you finish making the face. For a pose with no word of its own, 1–3 words naming it go instead (for example "flexing" or "rock on"), made on your Mac by MemeMe's own rules or by Apple's on-device model; the description of your arms, hands and face that the model reads never leaves your Mac, and neither does any frame. What you type in the search field goes too, once you pause typing, without filter words (`mine`, `gif`, `sticker`) or the names of your people. GIPHY's results show together, in GIPHY's order, and are kept in memory for 10 minutes. Their images load from GIPHY with ordinary web caching; a GIF you copy or drag is downloaded to a temporary file that is deleted within the hour. Nothing from GIPHY goes into your library.
  - **Imgflip** (no key): once a day MemeMe fetches Imgflip's public list of popular meme templates (the request carries nothing about you) and keeps it in `~/Library/Caches/MemeMe/Templates`. Which templates fit your face, your pose or your words is worked out on your Mac, so none of them is sent to Imgflip; the images of the templates picked then load from Imgflip (with ordinary web caching), so Imgflip sees which ones were shown; one you copy or drag goes to a temporary file deleted within the hour.
- **Update checks.** Release builds fetch `latest.json` from GitHub Releases every 6 hours. The request carries nothing about you or your library. The new DMG is downloaded only after you click **Update**.
- **Friend stickers.** Grouping stickers by person is opt-in. Face matching compares a sticker's face only with stickers you made, and the data never leaves your Mac.
- **Where data lives.** `~/Library/Application Support/MemeMe` (index, settings, kept images, stickers) and `~/Library/Caches/MemeMe`. Delete both to start over.
- **Signatures.** macOS ties the camera and folder permissions to the app's signature. Releases are signed with a Developer ID, so permissions carry over to new versions. An ad-hoc build (local builds, CI test builds, releases from before Developer ID signing) has a different signature every time, so macOS may ask again.

## GIPHY API key

Web Discover adds classic memes (Distracted Boyfriend, Drake, Surprised Pikachu…) from Imgflip's list of popular templates, and GIPHY reaction GIFs and stickers for the face you make (or the words you type), to All Sources and their own sources, credited "Powered by" with GIPHY's logo. It is on by default. The classic memes need no key; GIPHY's GIFs need an API key, and the menu item then reads **Web Discover (GIPHY): No API Key** (it still turns Web Discover, classic memes included, on and off).

1. Create an app at [developers.giphy.com](https://developers.giphy.com) (choose **API**) and copy its API key. A new key is a beta key: 100 calls per hour. MemeMe stays under 90 per rolling hour on each Mac and reuses a mood's results for 10 minutes, but GIPHY counts calls per key, so every copy of a release shares the built-in key's limit. That's fine for you and a few friends; before sharing MemeMe widely, use **Upgrade to Production** on the key in GIPHY's dashboard.
2. Choose one way to provide it:
   - **Build time:** `GIPHY_API_KEY=your-key ./scripts/build-app.sh` writes it into the bundle's Info.plist (`GiphyAPIKey`).
   - **CI:** add a repository secret named `GIPHY_API_KEY` (Settings → Secrets and variables → Actions). The workflow passes it to the build script. Release runs fail without it; other builds without the secret, such as pull requests from forks, get an empty key.
   - **At run time:** menu-bar icon → **Set GIPHY API Key…**. This overrides the built-in key; leave it empty to go back to the built-in one.

GIPHY's attribution is built in: "Powered by" with GIPHY's logo shows under the tiles while GIPHY's GIFs do (`Resources/GIPHY/GIPHYLogo.png`, white lettering on transparent; `scripts/build-app.sh` copies it into the app).

MemeMe follows GIPHY's integration rules: results in their own row, in GIPHY's order, unfiltered, never mixed with your memes and never stored.

Turn Web Discover off from the menu to keep MemeMe offline, apart from the update check.

## Project layout

```
Package.swift                 SwiftPM manifest: MemeMeCore (library), MemeMeApp (executable "MemeMe"), tests
Sources/MemeMeCore/           Foundation-only logic, also builds on Linux
  FaceFeatures, Baseline        face features and the learned resting face
  FaceCues, FaceShapeMeasure    the face's details (tongue out, wink, one eyebrow, duck face, smirk, eye roll) from its landmarks
  PeakHoldTracker               turns camera frames into a stable query ("no shutter")
  FeatureWeights, Ranker        scoring for face, text, image, more-like and recent searches
  EarlyMoodTrigger, TileRows     when a held face's mood is clear (early GIPHY search); keyboard focus across the grid
  PickerSource, FaceLean        the sources (All Sources, Favorites, On My Mac, …), what kind a thing is, All Sources' first row; leaning on a part of the face
  Mood, MemeTemplateCatalog     face → mood word for GIPHY; the classic memes for a mood, words or a described pose
  PoseDescription               a pose with no word of its own in words: facts for the on-device model, a phrase by rule
  Classifier, LibraryItem,      library model, meme/maybe/skipped sorting, JSON store
  LibraryStore, RecentStore,
  Person, AppSettings, VectorMath
  Update                        the update feed (latest.json) and when to offer an update
Sources/MemeMeApp/            the macOS app (AppKit + SwiftUI)
  App/                          main.swift, AppDelegate, AppModel (orchestration), HotKey (Carbon),
                                StatusItemController (menu, drop target, popover), StickerPopoverModel, LoginItem
  Camera/                       AVFoundation capture and the mirrored preview
  Vision/                       face landmarks → features, image analysis, thumbnails, naming poses with Apple's on-device model (PoseNamer)
  Library/                      folder watching and indexing
  Web/                          GIPHY search and media for GIPHY's GIFs and stickers
  Stickers/                     subject lifting into die-cut stickers, friend grouping
  System/                       clipboard, Low Power / network conditions
  UI/                           the search panel (search bar, source menu, grid, camera column, actions, bottom bar), footer, setup card, HUD, sticker popover
  Update/                       update checks, download and verification, one-click install
Tests/MemeMeCoreTests/        XCTest suite for the core
VERSION                       the marketing version; the build number is the commit count
Resources/Info.plist          bundle Info.plist (LSUIElement, usage strings, GiphyAPIKey, MemeMeUpdateFeedURL)
Resources/MemeMe.entitlements the camera entitlement for Developer ID builds (hardened runtime)
Resources/DMG/                the DMG window background: background.html and the PNGs rendered from it
scripts/build-app.sh          builds and signs build/MemeMe.app (version, update feed, GIPHY key; ad hoc or Developer ID)
scripts/build-dmg.sh          packs it into build/MemeMe.dmg with the drag-to-Applications window (signed too for Developer ID builds)
scripts/dmg-settings.py       the DMG window layout (dmgbuild settings)
scripts/dmgbuild-requirements.txt  dmgbuild, pinned by hash
scripts/render-dmg-background.cjs  renders Resources/DMG/background.html to the window backgrounds
scripts/notarize.sh           notarizes a file with notarytool and staples the ticket
scripts/publish-release.sh    publishes a GitHub Release with MemeMe.dmg and latest.json
scripts/build-site.sh         standalone copy of the website in build/site/
site/index.html               the website
.github/workflows/ci.yml      CI (Xcode 26.3): build, check FoundationModels is weak-linked, test, package the DMG; signs, notarizes and releases from the default branch
docs/                         DESIGN.md (product spec) and ARCHITECTURE.md (code contract)
```

## Limitations

- **Friend grouping is not face recognition.** It compares Vision's generic image feature prints of face crops. That is not an identity model, so the thresholds are conservative, and MemeMe asks ("Jordan?") when it is unsure.
- **Expressions are approximate.** Features come from Vision's 2D face landmarks; strong lighting, glasses or a turned head make them noisier. Moods are a coarse set of words. A tongue is found by its color under the lips, so gray or colored light (or lipstick close to it) can hide it.
- **Pose names are read from words, not the picture.** Apple's on-device model names a pose from a description of your arms, hands and face, and only on macOS 26 with Apple Intelligence on (an Apple silicon Mac); elsewhere MemeMe's own rules name it, and a pose they don't know is "strike a pose". Showing the model the picture needs the macOS 27 SDK, a possible follow-up once CI has Xcode 27.
- **KLIPY is not wired up yet.** The provider protocol is ready, but its API shape is unverified, so GIPHY is the only web source.
- **The shortcut is fixed to ⌥M in v1.** If another app already holds it, the first-run card says so.
- **Out of scope for v1:** auto-paste, a full library window, Photos library access, importing Messages history.
