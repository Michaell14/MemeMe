# MemeMe — product & interaction spec (v1)

MemeMe is a macOS 14+ menu-bar app. You press ⌃⌘M in any chat, make a face, and pick a reaction; it is copied and you are back in the chat. The design goal is **as little friction as possible**, and the app must stay **tiny and lightweight**.

The canvas with every screen lives at https://claude.ai/artifact/T9nxHbX2DHg5ChhWdT8Tqf. The chosen layout is the **compact strip, 2 rows** ("Compact · Reply" and "Compact · all states" boards).

## Principles

1. **Your face is the search box.** The search needs no shutter, mode toggles or filters, and shows no weights or sliders. (Sending yourself, below, is a separate view with its own shutter and filters.)
2. **One commit.** ↵, a number key 1–9, or a click copies the result, closes the panel and leaves you in the chat. MemeMe never pastes or sends for you (no Accessibility permission, ever).
3. **Undo instead of confirm.** Automatic actions (keeping files, making stickers, filing friends) report what they did and offer Undo.
4. **Never move what the user is about to click.** Your memes never change under you while you look; GIPHY's results arrive in their own row and never reshuffle yours.
5. **Tiny.** Swift + Apple frameworks only, no third-party packages, no bundled ML models, camera only while the panel is open, an index instead of copies of the user's files.

## The panel (compact strip)

- 640 px wide, about 280 px tall (about 380 px with the GIPHY row, about 480 px with the classic memes row too), a non-activating floating panel centered horizontally at the top of the screen with the menu bar, 8 px below the menu bar (right under the built-in camera). The chat app stays the active app and keeps its draft and caret.
- Dark surface: background `#1E1F24`, 1 px border `#3A3C44`, radius 14, shadow. Text `#ECECEF`, muted text `#A9ACB5`, accent `#7AA2FF`, focus-highlight amber `#F5C451`, success green `#5FD38D`. Font: system (SF Pro).
- Padding 16. Layout: left column 120 px wide, right column fills the rest, 16 px gap; a footer below only while there is something to act on.
  - **Left column:** the mirror (live camera, mirrored, 120×120, radius 18, 3 px ring: accent when live, grey otherwise; while live, a 26 px camera button at its bottom right opens Send yourself). Under it the hint: title 13 pt semibold, subtitle 11 pt muted, optional small capsule action button.
  - **Right column:** search field (36 px tall, radius 9, background `#26282E`, magnifier icon, placeholder "Type, or drop / ⌘V an image", ⌃⌘M keycaps at the right). Under it your memes: **5 columns × 2 rows** (1 row when you have five or fewer memes; with none, a single dashed line "Drop memes here, or find the ones on this Mac" instead of empty tiles, with a small [Find my memes] capsule on the right while no folders are collected), square tiles, 8 px gaps, radius 10. The row count follows how many memes you have, not what a search found, so the panel keeps its height while you search. Under them, when Web Discover is on and has a key, the **GIPHY row**, and when Web Discover is on, the **classic memes row** (see Web discover).
  - **Footer:** only while there is something to act on: memes being collected, the memes just added, or an update (see Library, Updates): a 1 px separator, then that one line. Otherwise there is no footer: no focus line or key legend (the keys are in the README).
- **Tiles:** thumbnail (first frame, aspect-fill). Number badge 1–9 top-left (dark 72% chip). Own items: 9 px accent dot top-right. Friend stickers: 11 px amber ring top-right. GIFs: "GIF" micro-badge bottom-left. The focused tile has a 2 px accent ring (with a 2 px gap). Tiles that just arrived get a 2 px amber ring for 600 ms. Only the focused tile animates if it is a GIF.
- No percentages, weights, sliders, scope filters or mode toggles are ever shown in the search.

### Panel states and hint copy (exact strings)

| State | Mirror | Hint title | Hint subtitle | Action |
|---|---|---|---|---|
| prompt (first run, camera not decided) | silhouette | Make a face. | That’s the search. There’s no button to press. | — |
| warming (camera starting) | silhouette | Starting camera… | Your recent picks are ready below. | — |
| live | live camera | Make a face or a pose. Results follow it. | — | — |
| live, an expression being held | live + ring filling | (same: the words never change while the camera reads you) | (same) | — |
| live, no face for 1.5 s (clears once the face is back for 1 s) | live camera | Can’t see your face | Try more light, or just type. | — |
| live, pins set | live, pinned region glows amber | Focusing on your mouth (or “your eyes”, “your eyes and mouth”) | — | Clear |
| text | silhouette (camera stopped) or dimmed live when a face token is kept | Searching by words | The camera is off while you type. | — |
| image (dropped / ⌘V) | the image | Searching with your image | It isn’t saved unless you keep it. | Keep it / Kept · Undo |
| moreLike | the chosen result | More like “OMG” | — | Back to your face |
| cameraOff (denied, or no usable camera — then no action button) | dashed drop well | No camera | Drop, paste or type instead. | Turn on camera |
| cameraBusy (camera in use by a call) | silhouette | Your camera is in use | Type or drop instead, or use it anyway. | Use camera |

Section label above the grid is not shown in the compact layout; the hint carries the context.

### Recent

On open, before a face is captured, the grid shows **Recent in this app** (per frontmost app bundle id), newest first; tile 1 is the last item sent from this app, so ⌃⌘M then ↵ repeats a reaction. If there is no history, the newest own memes; if the library is empty, the GIPHY row shows GIPHY's "reaction" results so the first run is never empty.

## Capturing the face (no shutter for the search)

- The camera starts on show and stops on hide (within 1 s). About 10 analyzed frames per second.
- **Peak-hold:** a face held for 0.3 s becomes the query (the sharpest/most intense frame from the last 0.5 s). Relaxing or talking does nothing.
- A **stronger version of the same expression** (≥ 15 % more intense, same direction) replaces the query after 0.3 s. A **different expression** must be held for **1 s** (the ring around the mirror fills).
- **Space** (with an empty search field) snaps the current face immediately, even a neutral one (deadpan, unimpressed).
- Feature weights are inferred, never shown: regions that moved most from the user's own resting face count most (1×–3×). The resting face is learned silently from calm frames (about 20 numbers, never an image) and can be reset from the menu.
- **Pins:** clicking the eyes or mouth on the mirror pins that region (counts most; amber glow). Clicking again unpins; "Clear" or the first Esc clears pins. Hovering the mirror shows dashed outlines on the clickable regions.
- **Pose:** your arms, elbows and hands count. A clear gesture (both arms up, hands on your head, a hand over your face, hands together, a shrug, a thumbs up, pointing) counts for most of the match, finds memes with the same pose (mirrored ones too), and picks its own GIPHY word ("celebrate", "mind blown", "facepalm", "clapping", "shrug", "thumbs up", "pointing"); a plain face leaves the pose a small say. A hand covering your face still counts as being seen. Memes indexed by earlier versions have their pose read again in the background. No slider.
- **More like this** (Tab): uses the focused result as the query. "Back to your face" (or Shift-Tab, or Esc) returns.

## Send yourself (photo or GIF of you)

- The camera button on the mirror, or **⇧Space** with an empty search field (while the camera reads you), replaces the panel's contents with the capture view; **Esc** (or "Back to memes") returns. The search pauses meanwhile.
- **Capture view:** a 300 × 300 mirrored picture of you (radius 18, accent ring) with a round white shutter at its bottom; beside it "Send yourself", a status line and the filters as chips (3 columns); under both a separator and the legend "space or click: photo · hold: GIF · ← → filter · esc back".
- **Tap** the shutter (click, Space or ↵) for a photo (the picture flashes white). **Hold** it (longer than 0.35 s) to record a GIF: the ring fills in coral, the shutter turns into a stop square, and recording ends when you let go or after 3 s (up to 12.5 frames a second, 10 from a 30 fps camera, played at real speed; 320 px). Held past 3 s, the GIF is copied when you let go.
- The capture is exactly what the picture shows (mirrored, filtered), square: a photo is 480 px at the camera's VGA. It is copied like any pick (`reaction.png` as PNG data plus a file, or `reaction.gif` with GIF data), the panel closes, and the HUD says **"Copied your photo · ⌘V — not sent"** (or GIF) with a **Save as sticker** button for 5 s (longer while the pointer is over it). Captures are never kept otherwise.
- **Save as sticker:** your face (the photo, or the GIF's frame with the strongest expression) is cut out as a die-cut sticker and kept as one of your own memes ("You — happy", source "Camera"): it shows up in face searches and under "sticker" and "mine". The HUD confirms ("Saved “You — happy” as a sticker", with **Undo**) or says "Couldn’t find you in that one."
- **Filters** (← → or a click; None each time the view opens): None, Noir, Comic, 8-bit, Deep fried, and on your face Deal with it (pixel shades), Heart eyes, Bug eyes, Crown. Face filters follow your face about 10 times a second; drawn with Core Graphics, no bundled art. The search always reads the unfiltered camera.

## Typing, dropping, pasting

- Any letter types into the search field (it has focus when the panel opens). Digits never type: 1–9 always pick. Space types only once there is text.
- Typing stops the camera if it starts within 1 s of opening; otherwise the held face stays as a removable token "+ your face ×" that orders the text results ("+ your pose ×" when a clear gesture hid the face).
- Text search covers OCR text, Vision labels, file names, sources and friend names. Filters by word: "mine", "gif", "sticker", a friend's name. Own items, grouped by month (newest first). The GIPHY row follows the words once typing pauses for 0.6 s (at once when GIPHY answered them in the last 10 minutes; at least 3 letters or digits; while the panel asks “Is one of these Sam?”, nothing for a word that isn't ordinary meme vocabulary: a mood word, a mood's name or a classic meme's search word still goes): GIPHY's results for the typed words without filter words or your people's names (possessives too: "sam's"), in GIPHY's order and unfiltered; the header shows the words. The classic memes row follows them at once (matched on the Mac). Clearing the words brings back the face's results (or the popular classic memes). If nothing matches and the word looks like a name, the panel asks **“Is one of these Sam?”** with up to 3 unnamed faces; clicking one names that person.
- If too few results, the last tile is "Not here? Look in Documents…" which adds a watched folder (one macOS prompt).
- **Drop or ⌘V an image onto the panel = search with it only** (never saved silently). "Keep it" saves it. ⌘V is treated as an image query only when the pasteboard holds an image that MemeMe did not put there itself.

## Committing

- ↵ (focused tile), 1–9, or click: copy, record as sent (per app), close the panel, show a HUD for 1.6 s at the top: **“Copied “Shocked cat” · ⌘V — not sent”**.
- Within 300 ms after the last keystroke in the search field, ↵ is ignored (so ↵ meant to "run the search" doesn't commit).
- Drag a tile straight into the chat's message box: the clipboard is left alone; the panel closes on a successful drop.
- Clipboard formats: GIFs as a file (plus `com.compuserve.gif` data) so Discord and iMessage keep them animated; stills as PNG data plus a file. File names never leak names: own items keep their file name, everything else is `reaction.gif`, `reaction.png` or `sticker.png`.
- GIPHY GIFs: the full GIF (GIPHY "downsized", ≤ 2 MB) is downloaded ahead, into the HTTP cache only, for the row's first GIF and for any GIF that gets the focus, so copying is instant; otherwise it downloads on commit with the HUD showing "Copying…". It is written to a short-lived file only when it is copied or dragged; copy, drag and clipboard files are deleted within the hour (checked every 10 minutes), except the copy still on the clipboard.

## Closing

- Esc: first clears refinements (text, pins, more-like-this, image query); second closes.
- Any click outside the panel closes it (prevents ↵ meant for the panel from reaching the chat).
- ⌃⌘M toggles.

## Library that fills itself

- **First-run "You're set" card** (shown after the first pick on first run, replacing the top row): "Copied. Paste it with ⌘V." · "Next time, in any chat: ⌃ ⌘ M · Change" · checkbox "Open at login" (checked) · button "Find memes already on this Mac" with caption "Downloads, Desktop, Screenshots · stays on this Mac". It closes on the next app switch or Esc.
- If the card was skipped: the dashed "Drop memes here" line (shown while you have no memes) carries a [Find my memes] capsule; the menu has it too. No footer line asks.
- While indexing: footer "Finding your memes… 212 · newest first". After: one line on the next open "Added 312 from Downloads, Desktop · 1,140 skipped (photos, documents) · Review · Undo".
- Watched folders: Downloads, Desktop, and the screenshot location (from `com.apple.screencapture` → `location`, default Desktop). New files become searchable in about 2 s. Top level only. Images ≤ 25 MB: PNG, JPEG, GIF, HEIC, WebP, TIFF.
- A silent classifier sorts images: **meme** (in results), **maybe** (typed search only), **skipped** (personal photos, chat/DM screenshots; only reachable as a last resort in typed search under "From your photos"). Skipped images keep no face data or text.
- The index stores ~4 KB per meme (features + a base64 Float32 image fingerprint + OCR text). User files are never copied, except images explicitly handed in (dropped on the menu-bar icon), which go to `~/Library/Application Support/MemeMe/Kept`.
- Indexing runs at utility priority, at most 2 images at once, pauses in Low Power Mode or when the thermal state is serious, and can be paused for 1 hour from the menu.

## App icon

A winking smiley die-cut sticker, its corner peeling, on an orange tile (the website's logo chip, `#FF9A5C` to a deeper orange), with two small sparkles; macOS grid (824 px tile on a 1024 canvas). The face is the website's smiley made bold: an ink pill eye, a wink, an open grin with a coral tongue. The 16, 32 and 64 px sizes are drawn upright with features on whole pixels, and the 16 px one without the peel. Sources: `Resources/AppIcon`. It shows in Finder, Launchpad, the DMG window, System Settings and notices; the menu bar keeps its template icon.

## Menu-bar icon

- Template icon (SF Symbol `face.smiling`). Clicking shows the menu.
- **Drop target:** dragging files or images onto the icon keeps them. Photos of people (not animated, little text, faces ≥ 6 % of the image height) become **stickers** (per the "Photos with people" setting, default automatic); everything else is kept as a meme. With "Ask Each Time", one alert per drop: title "Make stickers from “IMG_2207”?" (or "Make stickers from 3 photos?"), text "MemeMe cuts out each person. Everything stays on this Mac.", buttons [Make Stickers] [Keep as Photo] (plural "Keep as Photos").
- After a drop, a popover under the icon:
  - Stickers: header "Made 3 stickers" + "Undo all"; the first time ever, an inline question "Group stickers by person?" / "MemeMe matches faces only against stickers you made. Face data stays on this Mac." [Yes, group them] [Not now]; a row of die-cut stickers (checkerboard background), each with a name label: "Maya ✓" (confident match), "Jordan?" + [Yes, that’s Jordan] (likely), or "New face"; a × on each to remove (+ to restore); footer "Keep as photo only".
  - Kept memes: "Kept 23 · 4 duplicates merged" + "Undo".
  - The popover closes on outside click or after 8 s without hover.
- Menu:
  - Open MemeMe ⌃⌘M
  - — Collecting from: ✓ Downloads · ✓ Desktop · ✓ Screenshots (each toggles) · Add Folder… · Find Memes on This Mac (when nothing is watched)
  - Pause Collecting for 1 Hour (or Resume Collecting)
  - — Web Discover (GIPHY) ✓ · Set GIPHY API Key…
  - — Photos with People ▸ Make Stickers Automatically / Ask Each Time / Never
  - Group Friends’ Faces ✓ · Forget My Resting Face
  - — Open at Login ✓ · Show Library in Finder
  - — Check for Updates… · Version 1.0 (57) (disabled; both only in builds that can update, see Updates)
  - — Quit MemeMe
  - When an update is available, the menu starts with **Update to MemeMe 1.0 (58)…** and a separator (while it downloads or installs: **Updating MemeMe…**, disabled).

## Friend stickers

- Subject lifting (Vision, macOS 14) cuts each eligible person out; a white die-cut outline is added; PNG ≤ 512 px stored in `Application Support/MemeMe/Stickers`.
- Each sticker is a normal library item (kind friend) with face features, so it shows up when you make a similar face. Friend stickers win ties but at most 2 appear in a face-search grid unless the query names the friend.
- Grouping (only after consent): a face embedding (Vision image feature print of the face crop) is compared against the user's earlier stickers only. ≥ 0.90 similarity → confident ✓; ≥ 0.80 → "Name?" confirm; else a new unnamed face. Naming is lazy (typed name → "Is one of these …?"). "Forget this person" exists in the menu via Library folder in v1 is out of scope; `forget(personID:)` exists in code.
- Note for the report: Vision's generic feature print is not an identity model; thresholds are conservative and the UI asks when unsure.

## Web discover (GIPHY)

GIPHY's results are shown the way GIPHY's rules ask: in their own row, in GIPHY's order, unfiltered, never mixed with your memes, never stored, under GIPHY's mark.

- On by default when a GIPHY API key is available (Info.plist `GiphyAPIKey` baked at build time from the `GIPHY_API_KEY` env var, or set from the menu). Without a key there is no GIPHY row and the menu item reads "Web Discover (GIPHY): No API Key", still a working on/off switch: it also turns the classic memes (Imgflip) on and off, so turning it off keeps MemeMe offline apart from the update check. When GIPHY refuses searches the item says why: "Key Not Accepted" (401/403; that key waits 10 min, a new key searches at once) or "Hourly Limit Reached" (MemeMe's own limit, or a 429, which pauses all searches for 10 min).
- The face is mapped on-device to one **mood word** (shocked, screaming, laughing, happy, smug, side eye, crying, sad, angry, confused, unimpressed, nervous, excited). Of the face, only that word is sent: `GET https://api.giphy.com/v1/gifs/search?api_key=…&q=<mood> reaction&limit=10&rating=pg-13&lang=en`. Typed words go as `q=<typed words>` (see Search).
- **The GIPHY row:** under your memes, a header with "Powered by" and GIPHY's logo on the left and the mood word (or the typed words) on the right, then GIPHY's first 5 results as square tiles, in GIPHY's order. Tiles show GIPHY's small still (`fixed_width_small_still`) and play GIPHY's small preview (`fixed_width_small`) while focused. No number badges: the keys 1–9 pick your memes; arrows move into the row (↓ from your memes), the pointer and ↵ work as anywhere. "More like this" is for your memes only. Before a face the row says "Make a face for GIFs from GIPHY." (unless your library is empty or no face can be read, with no camera, camera access denied or not yet given, or the camera in use: then it shows "reaction"); while searching its tiles are placeholders; when GIPHY doesn't answer it says "GIPHY isn’t answering right now."
- **The classic memes row:** under the GIPHY row (or your memes, without a GIPHY key), a header "Classic memes · Imgflip" on the left and the mood word (or the typed words) on the right, then 5 square tiles showing each template whole (letterboxed), so a four-panel meme reads as one. Templates come from Imgflip's free list of the ~100 most popular (fetched at most once a day, kept in the cache folder, an older list used when Imgflip doesn't answer). MemeMe's own table (`MemeTemplateCatalog`) says what each famous template is for: its moods and the words people search it by ("guy looking back" → Distracted Boyfriend). A face's mood shows its templates first (those made for it, then those that also fit), then the most popular to fill the row; before a face, the most popular. Typed words show only templates that match them, by name, search words or a mood they name ("lol", "mad"), else "No classic memes for “…”." The face and the words don't leave the Mac, though the images of the templates picked load from Imgflip (so its servers see which templates were shown, as with any image). Arrows move into the row (↓ from the GIPHY row), ↵ / click copy the template (as "reaction.png"), drag drops it ("meme.jpg"). While the list loads the tiles are placeholders; with no list at all: "Imgflip isn’t answering right now."
- **Speed.** The search starts as soon as the mood is clear, before the expression is held: once the expression being held has read as the same mood for 0.2 s (`EarlyMoodTrigger`). The hold takes 0.3 s for the first expression and 1 s for a new one, so the row is usually filled the moment it completes. A mood's results are reused for 10 minutes. A search that fails on a dropped connection, a timeout or a server error is tried once more after 0.5 s (counted against the hourly limit).
- **Nothing GIPHY is stored.** Results live in memory for 10 minutes; images load from GIPHY's URLs through ordinary HTTP caching (as GIPHY's own apps do); the only files are full GIFs being copied or dragged, deleted within the hour. Sent GIPHY GIFs are not added to your library or to Recent (earlier versions did; those are removed at launch).
- Rate limit guard: at most 90 GIPHY calls per rolling hour per Mac. GIPHY counts calls per key, so every install of a build with a baked-in key shares that key's limit (100 per hour for a beta key): a public release needs a production key.
- The mark: "Powered by" (11 pt semibold, soft text) followed by GIPHY's logo, 13 pt tall: `Resources/GIPHY/GIPHYLogo.png` (white lettering and the coloured icon on transparent, for the dark panel), copied into the app by `scripts/build-app.sh`. Without the file the header reads "Powered by GIPHY" in words. VoiceOver reads "Powered by GIPHY".

## First run

1. App launches (LSUIElement, no Dock icon). On the first launch per install only, the panel opens by itself (later login launches stay quiet until ⌃⌘M), in its usual place under the menu bar, in the prompt state, with the empty state "Drop memes here, or find the ones on this Mac" and GIPHY's "reaction" results in the GIPHY row (none when offline or without a key).
2. 0.6 s later the camera permission request (the app is activated for this one prompt so the system alert is in front).
3. Make any face → results. Pick → the You're set card. ⌃⌘M is registered without any permission (Carbon hot key). If the shortcut can't be registered, the card says "⌃⌘M is taken by another app." (rebinding UI is out of scope for v1).
4. Open at login is registered via `SMAppService.mainApp` (checked by default, toggle in card and menu).

## Updates

MemeMe updates itself from GitHub Releases. Every change to the app on the default branch becomes a release (see README › Releases); the website's download link always points at the newest one.

- **Version:** `CFBundleShortVersionString` is the marketing version from the `VERSION` file (e.g. `1.0`); `CFBundleVersion` is the build number, the commit count of the default branch (e.g. `57`). Shown as **1.0 (57)**. Builds compare by build number only.
- **Feed:** `latest.json`, a release asset next to `MemeMe.dmg`, read from `https://github.com/<owner>/<repo>/releases/latest/download/latest.json` (Info.plist `MemeMeUpdateFeedURL`, written by `build-app.sh`). Builds without a feed URL (local builds, tests) never check and show no update UI.
- **When:** 20 s after launch, then every 6 hours while running, and after the Mac wakes if the last check is over an hour old. Silent: a failed check (offline, 404, bad JSON) changes nothing and shows nothing.
- **Telling the user (no system notifications, no permission prompt):**
  - The menu-bar icon gets a small dot (template image, so it follows the menu bar's color).
  - The panel footer shows one line when the panel opens, unless that build was dismissed: **“MemeMe 1.0 (58) is ready”** + muted **“ · <first release note>”** (when there is one), then **[Update]** (filled) and **[Not now]** (link). "Not now" hides the line for that build only; the dot and the menu item stay. Priority: indexing and the added-memes line win over it.
  - The menu starts with **Update to MemeMe 1.0 (58)…**.
- **Check for Updates…** (menu) runs a check right away and answers in an alert:
  - Up to date: **“You’re up to date”** / **“MemeMe 1.0 (57) is the newest version.”** [OK]
  - Available: **“MemeMe 1.0 (58) is available”** / up to 5 release notes as "• note" lines, a blank line, then **“You have 1.0 (57).”** [Update] [Later]
  - Needs a newer macOS: **“MemeMe 1.0 (58) needs macOS 15.0”** / **“Your copy keeps working. Update macOS to get the new version.”** [OK]
  - Failed: **“Couldn’t check for updates”** / **“Check your internet connection and try again.”** [OK]
- **Update (one click, from the footer, the menu item or the alert):** the panel closes; HUD **“Downloading MemeMe 1.0 (58)…”**; the DMG downloads to `~/Library/Caches/MemeMe/Updates/<build>/` and must match the manifest's size and SHA-256 and come from `github.com` or `*.githubusercontent.com` over HTTPS; when MemeMe itself is signed with a Developer ID, the DMG must also carry the same team's Developer ID signature (`codesign --verify --strict -R …`) before it is mounted or opened in Finder; it is mounted read-only; the app inside must have the same bundle id, exactly the manifest's build, and a valid code signature (`codesign --verify --deep --strict`) and, when MemeMe itself is signed with a Developer ID, the same team's Developer ID signature; it is copied next to the running app as a hidden staged bundle; HUD **“Restarting to finish the update…”**; MemeMe quits and a small detached script swaps the bundles and opens the new one. On the next launch: HUD **“Updated to MemeMe 1.0 (58)”** once.
- **When MemeMe can't replace itself** (it runs from a translocated or read-only location, or its folder isn't writable): it opens the downloaded DMG in Finder and says **“Finish updating in Finder”** / **“Drag MemeMe into your Applications folder and choose Replace, then open it again.”** [OK]. OK quits MemeMe, because Finder can't replace a running app. The same fallback covers mount, copy and relaunch failures. When MemeMe is signed with a Developer ID, Finder only ever gets a DMG that passed the team check.
- **Failures:** download failed → **“Couldn’t download the update”** / **“Check your internet connection, or download it from the website.”** [Open Download Page] [Cancel]. Verification failed (size, checksum, host, bundle id, build, or the app's or DMG's signature) → **“The update didn’t check out”** / **“MemeMe didn’t install it. Try again later, or download it from the website.”** [Open Download Page] [Cancel]; an unverified DMG is never opened. "Open Download Page" opens the release page (or the DMG URL when the manifest has no page).
- Releases are signed with a Developer ID and notarized, so updates keep camera and folder access; the first update from an older ad-hoc build asks once more.

## Out of scope for v1

Auto-paste, rebinding the shortcut, a full library window, KLIPY (protocol is ready; endpoint shape unverified), Imgflip starter set, Photos library access, Messages history import.
