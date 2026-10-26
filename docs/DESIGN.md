# MemeMe — product & interaction spec (v1)

MemeMe is a macOS 14+ menu-bar app. You press ⌃⌘M in any chat, make a face, and pick a reaction; it is copied and you are back in the chat. The design goal is **as little friction as possible**, and the app must stay **tiny and lightweight**.

The canvas with every screen lives at https://claude.ai/artifact/T9nxHbX2DHg5ChhWdT8Tqf. The chosen layout is the **compact strip, 2 rows** ("Compact · Reply" and "Compact · all states" boards).

## Principles

1. **Your face is the search box.** No shutter, no mode toggles, no filters, no visible weights or sliders.
2. **One commit.** ↵, a number key 1–9, or a click copies the result, closes the panel and leaves you in the chat. MemeMe never pastes or sends for you (no Accessibility permission, ever).
3. **Undo instead of confirm.** Automatic actions (keeping files, making stickers, filing friends) report what they did and offer Undo.
4. **Never move what the user is about to click.** Late results (web) fill in behind; they never reshuffle the focused tile.
5. **Tiny.** Swift + Apple frameworks only, no third-party packages, no bundled ML models, camera only while the panel is open, an index instead of copies of the user's files.

## The panel (compact strip)

- 640 px wide, about 330 px tall, a non-activating floating panel centered horizontally at the top of the screen with the menu bar, 8 px below the menu bar (right under the built-in camera). The chat app stays the active app and keeps its draft and caret.
- Dark surface: background `#1E1F24`, 1 px border `#3A3C44`, radius 14, shadow. Text `#ECECEF`, muted text `#A9ACB5`, accent `#7AA2FF`, focus-highlight amber `#F5C451`, success green `#5FD38D`. Font: system (SF Pro).
- Padding 16. Layout: left column 120 px wide, right column fills the rest, 16 px gap; footer below.
  - **Left column:** the mirror (live camera, mirrored, 120×120, radius 18, 3 px ring: accent when live, grey otherwise). Under it the hint: title 13 pt semibold, subtitle 11 pt muted, optional small capsule action button.
  - **Right column:** search field (36 px tall, radius 9, background `#26282E`, magnifier icon, placeholder "Type, or drop / ⌘V an image", ⌃⌘M keycaps at the right). Under it the results grid: **5 columns × 2 rows**, square tiles, 8 px gaps, radius 10.
  - **Footer:** a 1 px separator, then a focus line ("↵ copies “Shocked cat” · Downloads · Mar 2026" + a "More like this" capsule button on the right) and the legend "↵ copy · 1–9 pick · drag into chat · esc". The footer can instead show one quiet library line (see Library).
- **Tiles:** thumbnail (first frame, aspect-fill). Number badge 1–9 top-left (dark 72% chip). Own items: 9 px accent dot top-right. Friend stickers: 11 px amber ring top-right. GIFs: "GIF" micro-badge bottom-left. Web results: "via GIPHY" micro-label bottom-right. The focused tile has a 2 px accent ring (with a 2 px gap). Tiles that just arrived get a 2 px amber ring for 600 ms. Only the focused tile animates if it is a GIF.
- No percentages, weights, sliders, scope filters or mode toggles are ever shown.

### Panel states and hint copy (exact strings)

| State | Mirror | Hint title | Hint subtitle | Action |
|---|---|---|---|---|
| prompt (first run, camera not decided) | silhouette | Make a face. | That’s the search. There’s no button to press. | — |
| warming (camera starting) | silhouette | Starting camera… | Your recent picks are ready below. | — |
| live | live camera | Make a face. Results follow it. (pose active: “Matching your face and pose”) | Click your eyes or mouth to focus on them. | — |
| live, new expression being held | live + ring filling | (same) | New face? Keep holding… | — |
| live, no face for 1.5 s | live camera | Can’t see your face | Try more light, or just type. | — |
| live, pins set | live, pinned region glows amber | Focusing on your mouth (or “your eyes”, “your eyes and mouth”) | — | Clear |
| text | silhouette (camera stopped) or dimmed live when a face token is kept | Searching by words | The camera is off while you type. | — |
| image (dropped / ⌘V) | the image | Searching with your image | It isn’t saved unless you keep it. | Keep it / Kept · Undo |
| moreLike | the chosen result | More like “OMG” | — | Back to your face |
| cameraOff (denied) | dashed drop well | No camera | Drop, paste or type instead. | Turn on camera |
| cameraBusy (camera in use by a call) | silhouette | Your camera is in use | Type or drop instead, or use it anyway. | Use camera |

Section label above the grid is not shown in the compact layout; the hint carries the context.

### Recent

On open, before a face is captured, the grid shows **Recent in this app** (per frontmost app bundle id), newest first; tile 1 is the last item sent from this app, so ⌃⌘M then ↵ repeats a reaction. If there is no history, the newest own memes; if the library is empty, the GIPHY "reaction" results (cached) so the first run is never empty.

## Capturing the face (no shutter)

- The camera starts on show and stops on hide (within 1 s). About 10 analyzed frames per second.
- **Peak-hold:** a face held for 0.3 s becomes the query (the sharpest/most intense frame from the last 0.5 s). Relaxing or talking does nothing.
- A **stronger version of the same expression** (≥ 15 % more intense, same direction) replaces the query after 0.3 s. A **different expression** must be held for **1 s** (the ring fills; subtitle "New face? Keep holding…").
- **Space** (with an empty search field) snaps the current face immediately, even a neutral one (deadpan, unimpressed).
- Feature weights are inferred, never shown: regions that moved most from the user's own resting face count most (1×–3×). The resting face is learned silently from calm frames (about 20 numbers, never an image) and can be reset from the menu.
- **Pins:** clicking the eyes or mouth on the mirror pins that region (counts most; amber glow). Clicking again unpins; "Clear" or the first Esc clears pins. Hovering the mirror shows dashed outlines on the clickable regions.
- **Pose:** hands up / near the face increases how much body language counts. No slider.
- **More like this** (footer button, or Tab): uses the focused result as the query. "Back to your face" (or Shift-Tab, or Esc) returns.

## Typing, dropping, pasting

- Any letter types into the search field (it has focus when the panel opens). Digits never type: 1–9 always pick. Space types only once there is text.
- Typing stops the camera if it starts within 1 s of opening; otherwise the held face stays as a removable token "+ your face ×" that orders the text results.
- Text search covers OCR text, Vision labels, file names, sources and friend names. Filters by word: "mine", "gif", "sticker", a friend's name. Own items first, grouped by month (newest first), then web results. If nothing matches and the word looks like a name, the panel asks **“Is one of these Sam?”** with up to 3 unnamed faces; clicking one names that person.
- If too few results, the last tile is "Not here? Look in Documents…" which adds a watched folder (one macOS prompt).
- **Drop or ⌘V an image onto the panel = search with it only** (never saved silently). "Keep it" saves it. ⌘V is treated as an image query only when the pasteboard holds an image that MemeMe did not put there itself.

## Committing

- ↵ (focused tile), 1–9, or click: copy, record as sent (per app), close the panel, show a HUD for 1.6 s at the top: **“Copied “Shocked cat” · ⌘V — not sent”**.
- Within 300 ms after the last keystroke in the search field, ↵ is ignored (so ↵ meant to "run the search" doesn't commit).
- Drag a tile straight into the chat's message box: the clipboard is left alone; the panel closes on a successful drop.
- Clipboard formats: GIFs as a file (plus `com.compuserve.gif` data) so Discord and iMessage keep them animated; stills as PNG data plus a file. File names never leak names: own items keep their file name, everything else is `reaction.gif`, `reaction.png` or `sticker.png`.
- Web GIFs: the full GIF (GIPHY "downsized", ≤ 2 MB) is prefetched for the focused tile and the top two, so copying is instant; otherwise it downloads on commit with the HUD showing "Copying…".

## Closing

- Esc: first clears refinements (text, pins, more-like-this, image query); second closes.
- Any click outside the panel closes it (prevents ↵ meant for the panel from reaching the chat).
- ⌃⌘M toggles.

## Library that fills itself

- **First-run "You're set" card** (shown after the first pick on first run, replacing the top row): "Copied. Paste it with ⌘V." · "Next time, in any chat: ⌃ ⌘ M · Change" · checkbox "Open at login" (checked) · button "Find memes already on this Mac" with caption "Downloads, Desktop, Screenshots · stays on this Mac". It closes on the next app switch or Esc.
- If the card was skipped: a quiet footer line on later opens: "Search memes you already saved? Downloads · Desktop · Screenshots" [Find my memes] [Not now]; it disappears after two "Not now"s (the option stays in the menu).
- While indexing: footer "Finding your memes… 212 · newest first". After: one line on the next open "Added 312 from Downloads, Desktop · 1,140 skipped (photos, documents) · Review · Undo".
- Watched folders: Downloads, Desktop, and the screenshot location (from `com.apple.screencapture` → `location`, default Desktop). New files become searchable in about 2 s. Top level only. Images ≤ 25 MB: PNG, JPEG, GIF, HEIC, WebP, TIFF.
- A silent classifier sorts images: **meme** (in results), **maybe** (typed search only), **skipped** (personal photos, chat/DM screenshots; only reachable as a last resort in typed search under "From your photos"). Skipped images keep no face data or text.
- The index stores ~4 KB per meme (features + a base64 Float32 image fingerprint + OCR text). User files are never copied, except images explicitly handed in (dropped on the menu-bar icon), which go to `~/Library/Application Support/MemeMe/Kept`.
- Indexing runs at utility priority, at most 2 images at once, pauses in Low Power Mode or when the thermal state is serious, and can be paused for 1 hour from the menu.

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
  - — Quit MemeMe

## Friend stickers

- Subject lifting (Vision, macOS 14) cuts each eligible person out; a white die-cut outline is added; PNG ≤ 512 px stored in `Application Support/MemeMe/Stickers`.
- Each sticker is a normal library item (kind friend) with face features, so it shows up when you make a similar face. Friend stickers win ties but at most 2 appear in a face-search grid unless the query names the friend.
- Grouping (only after consent): a face embedding (Vision image feature print of the face crop) is compared against the user's earlier stickers only. ≥ 0.90 similarity → confident ✓; ≥ 0.80 → "Name?" confirm; else a new unnamed face. Naming is lazy (typed name → "Is one of these …?"). "Forget this person" exists in the menu via Library folder in v1 is out of scope; `forget(personID:)` exists in code.
- Note for the report: Vision's generic feature print is not an identity model; thresholds are conservative and the UI asks when unsure.

## Web discover (GIPHY)

- On by default when a GIPHY API key is available (Info.plist `GiphyAPIKey` baked at build time from the `GIPHY_API_KEY` env var, or set from the menu). Without a key it silently does nothing.
- The face is mapped on-device to one **mood word** (shocked, screaming, laughing, happy, smug, side eye, crying, sad, angry, confused, unimpressed, nervous, excited). Only that word is sent: `GET https://api.giphy.com/v1/gifs/search?api_key=…&q=<mood> reaction&limit=25&rating=pg-13&lang=en`.
- Small stills (`fixed_width_small_still`) are downloaded in parallel, analyzed on-device (face features, fingerprint) and ranked with the same scorer as local items, with a small penalty so own items win ties.
- Cache per mood for 24 h (`~/Library/Caches/MemeMe/Web`), LRU capped at 50 MB. The search starts as soon as the mood is clear. Popular moods are prefetched in the background on unmetered networks, not in Low Power Mode. A web round-trip longer than 1.5 s is dropped from the current grid (still cached for next time).
- Rate limit guard: at most 90 GIPHY calls per rolling hour (beta keys allow 100).
- Merging never moves the focused tile or the user's strong own matches (ResultMerger).

## First run

1. App launches (LSUIElement, no Dock icon). The panel opens by itself, centered on screen, in the prompt state, showing GIPHY "reaction" results (or an empty state "Drop memes here, or find the ones on this Mac" if offline / no key).
2. 0.6 s later the camera permission request (the app is activated for this one prompt so the system alert is in front).
3. Make any face → results. Pick → the You're set card. ⌃⌘M is registered without any permission (Carbon hot key). If the shortcut can't be registered, the card says "⌃⌘M is taken by another app." (rebinding UI is out of scope for v1).
4. Open at login is registered via `SMAppService.mainApp` (checked by default, toggle in card and menu).

## Out of scope for v1

Auto-paste, rebinding the shortcut, a full library window, KLIPY (protocol is ready; endpoint shape unverified), Imgflip starter set, Photos library access, Messages history import.
