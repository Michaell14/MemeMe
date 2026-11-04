import AppKit
import MemeMeCore
import SwiftUI

/// The drawer's two rows of tiles for the tab showing (`AppModel.layout`): 5 tiles of 104 pt per row, 8 pt apart, the
/// rows 12 pt apart. Empty slots keep their place, so the drawer never jumps as results come and go; a row with
/// nothing in it says why.
struct DrawerGrid: View {
    @ObservedObject var model: AppModel

    private let columnSpacing: CGFloat = 8
    private let rowSpacing: CGFloat = 12

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        let layout = model.layout
        VStack(alignment: .leading, spacing: rowSpacing) {
            tileRow(0, layout: layout)
            tileRow(1, layout: layout)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: model.tab.title))
    }

    private func tileRow(_ row: Int, layout: TileLayout) -> some View {
        let columns = layout.rows.columns
        let isEmpty = layout.rows.lastSlot(inRow: row) == nil
        let isLoading = layout.loading.indices.contains(row) && layout.loading[row]
        let message = layout.messages.indices.contains(row) ? layout.messages[row] : nil
        return HStack(spacing: columnSpacing) {
            ForEach(0..<columns, id: \.self) { column in
                slot(row * columns + column, inRow: row, isLoading: isLoading, layout: layout)
            }
        }
        .overlay {
            if isEmpty && !isLoading, let message {
                Text(verbatim: message)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.mutedText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 24)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func slot(_ slot: Int, inRow row: Int, isLoading: Bool, layout: TileLayout) -> some View {
        if let pick = layout.pick(at: slot) {
            PickTile(
                pick: pick,
                isFocused: model.focusedIndex == slot,
                marksType: layout.marksTypes && !layout.giphyRows.contains(row),
                model: model
            )
            .onHover { inside in
                if inside {
                    model.hover(index: slot)
                }
            }
            .onTapGesture {
                model.commit(index: slot)
            }
            .onDrag {
                // The panel controller closes the panel when the drag is released outside it.
                TileDragEvents.dragDidBegin?()
                return model.dragItemProvider(index: slot) ?? NSItemProvider()
            }
            .contextMenu {
                if case .meme = pick {
                    Button("More like this") {
                        model.hover(index: slot)
                        model.moreLikeFocused()
                    }
                }
            }
            .accessibilityAction {
                model.commit(index: slot)
            }
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface.opacity(isLoading ? 1 : 0.55))
                .frame(width: Theme.tileSize, height: Theme.tileSize)
                .accessibilityHidden(true)
        }
    }
}

/// GIPHY's attribution under the tiles while GIPHY's GIFs show: "Powered by" and GIPHY's logo from the app's
/// resources (the word "GIPHY" if it's missing).
struct PoweredByGiphyMark: View {
    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            Text("Powered by")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.mutedText)
            if let logo = PoweredByGiphyMark.logo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 12)
            } else {
                Text(verbatim: "GIPHY")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.text)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Powered by GIPHY")
    }

    /// Resources/GIPHY/GIPHYLogo.png: GIPHY's logo, white lettering on transparent for the black drawer, copied into
    /// the app by scripts/build-app.sh.
    static let logo: NSImage? = Bundle.main.image(forResource: "GIPHYLogo")
}

// MARK: - Tiles

/// One tile: one of your things, a GIF from GIPHY or a classic meme, 104 pt square. The focused tile has a 2 pt ring
/// in the signal color 2 pt out, and the ↩ chip: Return copies it. A GIF of yours carries a "GIF" tag where kinds mix.
struct PickTile: View {
    let pick: Pick
    let isFocused: Bool
    let marksType: Bool
    @ObservedObject var model: AppModel

    private let cornerRadius: CGFloat = 10

    init(pick: Pick, isFocused: Bool, marksType: Bool, model: AppModel) {
        self.pick = pick
        self.isFocused = isFocused
        self.marksType = marksType
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        content
            .frame(width: Theme.tileSize, height: Theme.tileSize)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(alignment: .bottomLeading) { gifTag }
            .overlay(alignment: .bottomTrailing) { returnChip }
            .overlay { ring }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .help(pick.title)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var content: some View {
        switch pick {
        case let .meme(item):
            OwnTileContent(item: item, isFocused: isFocused)
        case let .gif(gif):
            GiphyTileContent(gif: gif, isFocused: isFocused, model: model)
        case let .template(template):
            TemplateTileContent(template: template, model: model)
        }
    }

    @ViewBuilder
    private var gifTag: some View {
        if marksType, case let .meme(item) = pick, item.isAnimated, !item.isSticker {
            Text("GIF")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.4)
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.badgeBackground)
                )
                .padding(6)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var returnChip: some View {
        if isFocused {
            Text(verbatim: "↩")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.onAccent)
                .frame(minWidth: 22, minHeight: 20)
                .padding(.horizontal, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.accent)
                )
                .padding(6)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var ring: some View {
        if isFocused {
            RoundedRectangle(cornerRadius: cornerRadius + 3, style: .continuous)
                .stroke(Theme.accent, lineWidth: 2)
                .padding(-3)
                .allowsHitTesting(false)
        }
    }

    private var accessibilityText: String {
        let action = "Copy and go back to the chat."
        switch pick {
        case let .meme(item):
            let source: String
            switch item.kind {
            case .mine: source = item.isSticker ? "your sticker" : "from your library"
            case .friend: source = "friend sticker"
            case .pack: source = "from a pack"
            case .web: source = item.attribution ?? "via GIPHY"
            }
            let format = item.isAnimated ? ", GIF" : ""
            return "\(item.displayName), \(source)\(format). \(action)"
        case let .gif(gif):
            let creator = gif.creator.map { " by \($0)" } ?? ""
            return "\(gif.title), GIF\(creator) from GIPHY. \(action)"
        case let .template(template):
            return "\(template.name), classic meme from Imgflip. \(action)"
        }
    }
}

/// One of your things: its thumbnail filling the tile (a sticker whole, cut out on the tile), playing while focused
/// when it is a GIF.
private struct OwnTileContent: View {
    let item: LibraryItem
    let isFocused: Bool

    @State private var thumbnail: NSImage? = nil
    @State private var animatedURL: URL? = nil

    var body: some View {
        let still = thumbnail ?? ThumbnailCache.shared.cached(item.fileURL)
        ZStack {
            if let still {
                if item.isSticker {
                    Image(nsImage: still)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                } else {
                    Image(nsImage: still)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            if isFocused, let animatedURL {
                // Display-only, so the tile keeps its tap and drag gestures.
                AnimatedImageView(url: animatedURL)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: Theme.tileSize, height: Theme.tileSize)
        .clipped()
        .task(id: item.fileURL) { @MainActor in
            await loadThumbnail()
        }
        .task(id: "\(item.id.uuidString)|\(isFocused)") { @MainActor in
            await loadAnimation()
        }
    }

    @MainActor
    private func loadThumbnail() async {
        let url = item.fileURL
        if let cached = ThumbnailCache.shared.cached(url) {
            thumbnail = cached
            return
        }
        let loaded = await ThumbnailCache.shared.thumbnail(for: url, maxPixel: 256)
        if !Task.isCancelled {
            thumbnail = loaded
        }
    }

    /// Only the focused tile animates; a short delay skips tiles the pointer merely passes over.
    @MainActor
    private func loadAnimation() async {
        guard isFocused, item.isAnimated else {
            animatedURL = nil
            return
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled else { return }
        animatedURL = item.fileURL
    }
}

/// A GIF from GIPHY: its small still, playing its preview while focused.
private struct GiphyTileContent: View {
    let gif: WebGIF
    let isFocused: Bool
    @ObservedObject var model: AppModel

    @State private var still: NSImage? = nil
    @State private var animation: NSImage? = nil

    var body: some View {
        let image = still ?? model.web.cachedStill(for: gif)
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            if isFocused, let animation {
                // Display-only, so the tile keeps its tap and drag gestures.
                AnimatedImageView(image: animation)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: Theme.tileSize, height: Theme.tileSize)
        .clipped()
        .task(id: gif.stillURL) { @MainActor in
            if model.web.cachedStill(for: gif) == nil {
                let loaded = await model.web.still(for: gif)
                if !Task.isCancelled {
                    still = loaded
                }
            }
        }
        .task(id: isFocused) { @MainActor in
            // Only the focused tile animates; a short delay skips tiles the pointer merely passes over.
            guard isFocused else {
                animation = nil
                return
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let loaded = await model.web.preview(for: gif)
            if !Task.isCancelled {
                animation = loaded
            }
        }
    }
}

/// A classic meme, whole (letterboxed on the tile), so a four-panel meme still reads as one.
private struct TemplateTileContent: View {
    let template: MemeTemplate
    @ObservedObject var model: AppModel

    @State private var image: NSImage? = nil

    var body: some View {
        let shown = image ?? model.templates.cachedImage(for: template)
        ZStack {
            if let shown {
                Image(nsImage: shown)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: Theme.tileSize, height: Theme.tileSize)
        .task(id: template.url) { @MainActor in
            if model.templates.cachedImage(for: template) == nil {
                let loaded = await model.templates.image(for: template)
                if !Task.isCancelled {
                    image = loaded
                }
            }
        }
    }
}
