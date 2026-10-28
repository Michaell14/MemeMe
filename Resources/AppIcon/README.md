# App icon

`../AppIcon.icns` is what the app uses (Info.plist `CFBundleIconFile`, copied by `scripts/build-app.sh`).

- `AppIcon.svg`: the master, drawn for 128 px and up (1024 × 1024 canvas, the tile 824 × 824 at 100,100 per Apple's macOS grid).
- `AppIcon-64.svg`, `AppIcon-32.svg`, `AppIcon-16.svg`: hand-tuned small sizes (upright face, features on whole pixels, no peel at 16 px).
- `AppIcon-1024.png`: the master rendered.

Each size in the `.icns` is rendered from its own SVG (no resampling): 16, 32, 64, 128, 256, 512, 1024 px (and the @2x slots).
