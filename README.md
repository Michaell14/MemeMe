# MemeMe

A tiny macOS menu-bar app for reaction images. In any chat, press **⌃⌘M**, make a face, and pick a reaction. It is copied to the clipboard and you are back in the chat. Paste it with ⌘V. MemeMe never pastes or sends anything for you.

- **Your face is the search box.** Hold an expression for a moment and results follow it: memes you already have on your Mac, friend stickers you made, and (optionally) GIPHY reactions for the mood your face shows.
- **One commit.** ↵, a number key 1–9, or a click copies the result and closes the panel.
- **Small.** Swift and Apple frameworks only, no third-party packages, no bundled ML models. The camera runs only while the panel is open.

Requires macOS 14 (Sonoma) or later, on Apple silicon or Intel.

## Get the app

Download `MemeMe.dmg` from the website or from the [latest release](https://github.com/Michaell14/MemeMe/releases/latest). Open it and, in the window that appears, drag MemeMe onto the Applications folder.

Until releases are notarized (see [Signing and notarization](#signing-and-notarization)), the app is signed ad hoc, so Gatekeeper blocks the first launch with "Apple could not verify “MemeMe” is free of malware":

- **macOS 15:** open the app once, then go to **System Settings → Privacy & Security** and click **Open Anyway**.
- **macOS 14:** Control-click the app in Finder, choose **Open**, then confirm.
- Or remove the quarantine flag from Terminal: `xattr -dr com.apple.quarantine /Applications/MemeMe.app`

After that, MemeMe offers new versions itself (see [Releases and updates](#releases-and-updates)).

### From CI

Every push and pull request builds the app on GitHub Actions, including the ones that are not released.

1. Open the repository's **Actions** tab, then the latest successful **CI** run.
2. Download the **MemeMe-app** artifact and unzip it (GitHub wraps it in a zip). You get `MemeMe.dmg`.
3. Open it and drag MemeMe into Applications. Gatekeeper asks as above.

### Build it yourself

You need Xcode 16 (the Swift 6 toolchain; the package uses the Swift 5 language mode).

```sh
swift build                       # debug build of everything
swift test                        # unit tests
GIPHY_API_KEY=your-key ./scripts/build-app.sh
./scripts/build-dmg.sh            # optional: build/MemeMe.dmg
open build/MemeMe.app
```

`scripts/build-app.sh` builds a release binary (universal when possible; builds with an update feed must be universal and fail otherwise), assembles `build/MemeMe.app` with `Resources/Info.plist`, writes the version, the update feed and the GIPHY key into the bundle and signs it (ad hoc unless `CODESIGN_IDENTITY` is set). The build script reads these environment variables, all optional:

- `GIPHY_API_KEY`: without it the app is built with an empty key.
- `APP_VERSION`: the marketing version, `CFBundleShortVersionString`. Defaults to the `VERSION` file.
- `APP_BUILD`: the build number, `CFBundleVersion`. Defaults to the commit count (`git rev-list --count HEAD`).
- `UPDATE_FEED_URL`: the `latest.json` the app checks for updates. Empty by default, so local builds never check. CI sets `https://github.com/Michaell14/MemeMe/releases/latest/download/latest.json`.
- `CODESIGN_IDENTITY`: a Developer ID to sign with (see [Signing and notarization](#signing-and-notarization)).

`scripts/build-dmg.sh` packs the app and an Applications link into `build/MemeMe.dmg`. Opening it shows the usual install window: MemeMe on the left, an arrow, Applications on the right. [dmgbuild](https://github.com/dmgbuild/dmgbuild) writes that layout; the script installs it, pinned by hash (`scripts/dmgbuild-requirements.txt`), into `build/.dmgbuild-venv`. It needs Python 3.10 or later (`python3`, or set `PYTHON`); without one the DMG is built without the layout. The window is `scripts/dmg-settings.py` and its background is `Resources/DMG/background.html`. After changing the HTML, render the PNGs again with `node scripts/render-dmg-background.cjs` (needs Playwright) and commit them. Builds that are not notarized use the version that says how to get past Gatekeeper.

Run the app from the bundle rather than with `swift run`: camera access and Open at Login depend on the bundle's Info.plist and identity.

## Releases and updates

Every change to the app on the default branch is released automatically. When `Sources`, `Resources`, `Package.swift`, `VERSION` or the build scripts changed since the last `v*` tag, CI publishes GitHub Release `v<version>-<build>` (for example `v1.0-57`) with `MemeMe.dmg` and `latest.json`, the update feed, and marks it latest. The release notes are the subjects of the commits that changed the app.

- **Version numbers.** The marketing version is the `VERSION` file; bump it (say to `1.1`) for a new marketing version. The build number is the commit count, so every release has a higher one. The app shows both, as in **1.0 (57)**, and compares builds only.
- **Forcing a release.** **Actions → CI → Run workflow** on the default branch releases the current commit even when the app didn't change. A commit that already has a release keeps it unchanged; rebuilding needs a new commit, which gets a new build number.
- **Trying it locally.** `DRY_RUN=1 ./scripts/publish-release.sh build/MemeMe.dmg 1.0 57 14.0` writes `latest.json` and `release-notes.md` next to the DMG and publishes nothing.
- **In the app.** Release builds check `latest.json` 20 seconds after launch and then every 6 hours. When a newer build is out, the menu-bar icon gets a dot, the menu starts with **Update to MemeMe 1.0 (58)…** and the panel shows a line with **Update**. One click downloads the DMG, checks its size, SHA-256 and signature, replaces the app and restarts it. **Check for Updates…** in the menu checks right away.
- **Permissions after an update.** Ad-hoc builds get a new signature every time, so macOS may ask again for camera and folder access after an update. A Developer ID signature avoids that.

## Signing and notarization

Only an app signed with a Developer ID and notarized by Apple opens without the "Apple could not verify" dialog. That needs a paid [Apple Developer Program](https://developer.apple.com/programs/) membership. CI signs and notarizes as soon as these repository secrets exist (**Settings → Secrets and variables → Actions**); without them it builds as before, ad hoc and not notarized.

1. Create a **Developer ID Application** certificate (Xcode → Settings → Accounts → Manage Certificates, or developer.apple.com → Certificates). In Keychain Access, export it with its private key as a `.p12` with a password.
2. Add the secrets:
   - `MACOS_CERTIFICATE`: the `.p12` in base64 (`base64 -i DeveloperID.p12 | pbcopy`).
   - `MACOS_CERTIFICATE_PASSWORD`: the `.p12`'s password.
   - `APPLE_ID`: the developer account's Apple Account email.
   - `APPLE_TEAM_ID`: the 10-character Team ID (developer.apple.com → Account → Membership details).
   - `APPLE_APP_PASSWORD`: an app-specific password from account.apple.com → Sign-In and Security → App-Specific Passwords.
3. Push. CI signs the app with the hardened runtime (`Resources/MemeMe.entitlements` keeps camera access), signs the DMG, notarizes it with `notarytool` (usually a few minutes; the limit is 30), staples the ticket and checks it with `spctl`. The DMG window then drops the Open Anyway hint, and so do the release notes. Remove the Gatekeeper step from the website (`site/index.html`) and from [Get the app](#get-the-app) once a notarized release is out.

Half a set fails the build: the Apple ID secrets need the certificate. Locally, set `CODESIGN_IDENTITY` (the identity's name or SHA-1, from `security find-identity -v -p codesigning`) for both scripts, and `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_APP_PASSWORD` for `scripts/build-dmg.sh`.

The in-app updater accepts the signed builds, so existing users move over with a normal update. macOS asks for camera and folder access once more after that update, and then keeps it across later ones.

## Website

`site/index.html` is the one-page website, published as a claude.ai artifact. Its download button links to https://github.com/Michaell14/MemeMe/releases/latest/download/MemeMe.dmg, which always serves the newest release, so the download updates itself. Republish the page only when its text changes.

`./scripts/build-site.sh` writes a standalone copy to `build/site/index.html` that any static host can serve.

## Using it

| | |
|---|---|
| ⌃⌘M | Open or close the panel (in any app, no permission needed) |
| Make a face | Hold it for about 0.3 s; a different face needs about 1 s (the ring fills) |
| Space | Use the current face now, even a neutral one (only while the search field is empty) |
| ↵, 1–9, click | Copy the focused, numbered or clicked result and close |
| Arrow keys | Move the focus |
| Typing | Search by words: text in images, labels, file names, sources, friends' names. Filter words: `mine`, `gif`, `sticker`, a friend's name |
| ⌘V or drop an image on the panel | Search with that image. It is not saved unless you click **Keep it** |
| Tab / Shift-Tab | More like the focused result / back to your face |
| Click your eyes or mouth in the mirror | Focus the search on that part of the face |
| Esc | First clears text, focus, image or more-like; a second Esc closes |
| Drag a tile into a chat | Drops it into the message box and closes the panel; the clipboard is left alone |

**The menu-bar icon** has the settings: folders to collect from, pausing collection, Web Discover, the GIPHY key, what to do with photos of people, grouping friends' faces, forgetting your resting face, Open at Login, and showing the library in Finder.

**Drop images on the menu-bar icon** to keep them: files, images from a browser, or photos straight from Photos or Mail. Photos of people (not animated, little text, faces at least 6 % of the image height) become die-cut friend stickers. Everything else is kept as a meme. A popover reports what happened, with Undo.

## Permissions and privacy

- **Camera.** On only while the panel is open, and it stops when the panel closes. Frames are analyzed on your Mac with Apple's Vision framework and then discarded. Nothing is recorded or uploaded. The only thing MemeMe keeps is your "resting face": a handful of numbers (no image) that it learns from calm frames, so it can tell how much your face moved. **Forget My Resting Face** in the menu resets it.
- **Folders.** After **Find my memes** (or from the menu), MemeMe indexes images in Downloads, Desktop and your screenshot folder. macOS asks once per folder. Files are never copied or moved: the index stores features, a compact image fingerprint and the text found in each image (about 4 KB per meme). Personal photos and chat screenshots are sorted out and keep no face data or text. Only images you hand in yourself (dropped on the icon, or **Keep it**) are copied, into `~/Library/Application Support/MemeMe/Kept`.
- **No Accessibility access, ever.** MemeMe only writes to the clipboard. You paste.
- **Network.** Only with Web Discover on and a GIPHY key set: the one mood word for your face (for example "shocked reaction") goes to GIPHY. Small stills come back, are analyzed on your Mac and cached for 24 hours in `~/Library/Caches/MemeMe/Web` (capped at 50 MB). Popular moods are prefetched only on unmetered networks and not in Low Power Mode.
- **Update checks.** Release builds fetch `latest.json` from GitHub Releases every 6 hours. The request carries nothing about you or your library. The new DMG is downloaded only after you click **Update**.
- **Friend stickers.** Grouping stickers by person is opt-in. Face matching compares a sticker's face only with stickers you made, and the data never leaves your Mac.
- **Where data lives.** `~/Library/Application Support/MemeMe` (index, settings, kept images, stickers) and `~/Library/Caches/MemeMe`. Delete both to start over.
- **Ad-hoc signatures.** macOS ties the camera and folder permissions to the app's signature, and an ad-hoc signature changes with every build. After updating to a new ad-hoc build, macOS may ask for access again; Developer ID builds keep it.

## GIPHY API key

Web Discover finds reaction GIFs on GIPHY when your library has nothing good. It is on by default, but it does nothing without an API key.

1. Create an app at [developers.giphy.com](https://developers.giphy.com) and copy its API key. Beta keys allow 100 calls per hour; MemeMe stays under 90 per rolling hour and caches results.
2. Choose one way to provide it:
   - **Build time:** `GIPHY_API_KEY=your-key ./scripts/build-app.sh` writes it into the bundle's Info.plist (`GiphyAPIKey`).
   - **CI:** add a repository secret named `GIPHY_API_KEY` (Settings → Secrets and variables → Actions). The workflow passes it to the build script. Builds without the secret, such as pull requests from forks, get an empty key.
   - **At run time:** menu-bar icon → **Set GIPHY API Key…**. This overrides the built-in key; leave it empty to go back to the built-in one.

Turn Web Discover off from the menu to keep MemeMe offline, apart from the update check.

## Project layout

```
Package.swift                 SwiftPM manifest: MemeMeCore (library), MemeMeApp (executable "MemeMe"), tests
Sources/MemeMeCore/           Foundation-only logic, also builds on Linux
  FaceFeatures, Baseline        face features and the learned resting face
  PeakHoldTracker               turns camera frames into a stable query ("no shutter")
  FeatureWeights, Ranker        scoring for face, text, image, more-like and recent searches
  ResultMerger                  merges late web results without moving the focused tile
  Mood                          face → mood word for GIPHY
  Classifier, LibraryItem,      library model, meme/maybe/skipped sorting, JSON store
  LibraryStore, RecentStore,
  Person, AppSettings, VectorMath
  Update                        the update feed (latest.json) and when to offer an update
Sources/MemeMeApp/            the macOS app (AppKit + SwiftUI)
  App/                          main.swift, AppDelegate, AppModel (orchestration), HotKey (Carbon),
                                StatusItemController (menu, drop target, popover), StickerPopoverModel, LoginItem
  Camera/                       AVFoundation capture and the mirrored preview
  Vision/                       face landmarks → features, image analysis, thumbnails
  Library/                      folder watching and indexing
  Web/                          GIPHY provider and the mood cache
  Stickers/                     subject lifting into die-cut stickers, friend grouping
  System/                       clipboard, Low Power / network conditions
  UI/                           panel, mirror, result grid, footer, setup card, HUD, sticker popover
  Update/                       update checks, download and verification, one-click install
Tests/MemeMeCoreTests/        XCTest suite for the core
VERSION                       the marketing version; the build number is the commit count
Resources/Info.plist          bundle Info.plist (LSUIElement, usage strings, GiphyAPIKey, MemeMeUpdateFeedURL)
Resources/MemeMe.entitlements the camera entitlement for Developer ID builds (hardened runtime)
Resources/DMG/                the DMG window background: background.html and the PNGs rendered from it
scripts/build-app.sh          builds and signs build/MemeMe.app (version, update feed, GIPHY key)
scripts/build-dmg.sh          packs it into build/MemeMe.dmg; signs and notarizes it with a Developer ID
scripts/dmg-settings.py       the DMG window layout (dmgbuild settings)
scripts/dmgbuild-requirements.txt  dmgbuild, pinned by hash
scripts/render-dmg-background.cjs  renders Resources/DMG/background.html to PNGs
scripts/publish-release.sh    publishes a GitHub Release with MemeMe.dmg and latest.json
scripts/build-site.sh         standalone copy of the website in build/site/
site/index.html               the website
.github/workflows/ci.yml      CI: build, test, package the DMG; releases from the default branch
docs/                         DESIGN.md (product spec) and ARCHITECTURE.md (code contract)
```

## Limitations

- **Friend grouping is not face recognition.** It compares Vision's generic image feature prints of face crops. That is not an identity model, so the thresholds are conservative, and MemeMe asks ("Jordan?") when it is unsure.
- **Expressions are approximate.** Features come from Vision's 2D face landmarks; strong lighting, glasses or a turned head make them noisier. Moods are a coarse set of words.
- **KLIPY is not wired up yet.** The provider protocol is ready, but its API shape is unverified, so GIPHY is the only web source.
- **The shortcut is fixed to ⌃⌘M in v1.** If another app already holds it, the first-run card says so.
- **Not notarized** until the signing secrets are set up (see [Signing and notarization](#signing-and-notarization)). See [Get the app](#get-the-app) for opening the ad-hoc signed build.
- **Out of scope for v1:** auto-paste, a full library window, Photos library access, importing Messages history.
