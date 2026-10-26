# MemeMe

A tiny macOS menu-bar app for reaction images. In any chat, press **⌃⌘M**, make a face, and pick a reaction. It is copied to the clipboard and you are back in the chat. Paste it with ⌘V. MemeMe never pastes or sends anything for you.

- **Your face is the search box.** Hold an expression for a moment and results follow it: memes you already have on your Mac, friend stickers you made, and (optionally) GIPHY reactions for the mood your face shows.
- **One commit.** ↵, a number key 1–9, or a click copies the result and closes the panel.
- **Small.** Swift and Apple frameworks only, no third-party packages, no bundled ML models. The camera runs only while the panel is open.

Requires macOS 14 (Sonoma) or later, on Apple silicon or Intel.

## Get the app

### From CI

Every push builds the app on GitHub Actions.

1. Open the repository's **Actions** tab, then the latest successful **CI** run.
2. Download the **MemeMe-app** artifact and unzip it (GitHub wraps it in a second zip). You get `MemeMe.app`.
3. Move `MemeMe.app` to `/Applications`.

The CI build is signed ad hoc, not with a Developer ID, and it is not notarized, so Gatekeeper blocks the first launch:

- **macOS 15:** open the app once, then go to **System Settings → Privacy & Security** and click **Open Anyway**.
- **macOS 14:** Control-click the app in Finder, choose **Open**, then confirm.
- Or remove the quarantine flag from Terminal: `xattr -dr com.apple.quarantine /Applications/MemeMe.app`

### Build it yourself

You need Xcode 16 (the Swift 6 toolchain; the package uses the Swift 5 language mode).

```sh
swift build                       # debug build of everything
swift test                        # MemeMeCore unit tests
GIPHY_API_KEY=your-key ./scripts/build-app.sh
open build/MemeMe.app
```

`scripts/build-app.sh` builds a release binary (universal when possible), assembles `build/MemeMe.app` with `Resources/Info.plist`, writes the GIPHY key into the bundle, signs it ad hoc and zips it as `build/MemeMe.zip`. Without `GIPHY_API_KEY` the app is built with an empty key.

Run the app from the bundle rather than with `swift run`: camera access and Open at Login depend on the bundle's Info.plist and identity.

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
- **Friend stickers.** Grouping stickers by person is opt-in. Face matching compares a sticker's face only with stickers you made, and the data never leaves your Mac.
- **Where data lives.** `~/Library/Application Support/MemeMe` (index, settings, kept images, stickers) and `~/Library/Caches/MemeMe`. Delete both to start over.
- **Ad-hoc signatures.** macOS ties the camera permission to the app's signature, and an ad-hoc signature changes with every build. After updating to a new build, macOS may ask for camera access again.

## GIPHY API key

Web Discover finds reaction GIFs on GIPHY when your library has nothing good. It is on by default, but it does nothing without an API key.

1. Create an app at [developers.giphy.com](https://developers.giphy.com) and copy its API key. Beta keys allow 100 calls per hour; MemeMe stays under 90 per rolling hour and caches results.
2. Choose one way to provide it:
   - **Build time:** `GIPHY_API_KEY=your-key ./scripts/build-app.sh` writes it into the bundle's Info.plist (`GiphyAPIKey`).
   - **CI:** add a repository secret named `GIPHY_API_KEY` (Settings → Secrets and variables → Actions). The workflow passes it to the build script. Builds without the secret, such as pull requests from forks, get an empty key.
   - **At run time:** menu-bar icon → **Set GIPHY API Key…**. This overrides the built-in key; leave it empty to go back to the built-in one.

Turn Web Discover off from the menu to keep MemeMe fully offline.

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
Tests/MemeMeCoreTests/        XCTest suite for the core
Resources/Info.plist          bundle Info.plist (LSUIElement, usage strings, GiphyAPIKey placeholder)
scripts/build-app.sh          builds, signs and zips build/MemeMe.app
.github/workflows/ci.yml      macOS 15 CI: build, test, package, upload the MemeMe-app artifact
docs/                         DESIGN.md (product spec) and ARCHITECTURE.md (code contract)
```

## Limitations

- **Friend grouping is not face recognition.** It compares Vision's generic image feature prints of face crops. That is not an identity model, so the thresholds are conservative, and MemeMe asks ("Jordan?") when it is unsure.
- **Expressions are approximate.** Features come from Vision's 2D face landmarks; strong lighting, glasses or a turned head make them noisier. Moods are a coarse set of words.
- **KLIPY is not wired up yet.** The provider protocol is ready, but its API shape is unverified, so GIPHY is the only web source.
- **The shortcut is fixed to ⌃⌘M in v1.** If another app already holds it, the first-run card says so.
- **Not notarized.** See [From CI](#from-ci) for opening the ad-hoc signed build.
- **Out of scope for v1:** auto-paste, a full library window, Photos library access, importing Messages history.
