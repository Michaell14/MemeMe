import AppKit
import MemeMeCore
import SwiftUI

/// The grid under the search field (`AppModel.layout`): a title over it ("Recent", "Matching your face · shocked"),
/// then every pick, 5 to a row (4 beside the camera's column), each with its name and where it is from under it. It
/// scrolls; the arrow keys move the focus and the grid follows it. GIPHY's credit sits beside the title while GIPHY's
/// GIFs or stickers show. With nothing to show, it says why.
struct PickerGrid: View {
    @ObservedObject var model: AppModel

    /// "Look in Documents…" was clicked: gone at once, before the indexer reports the folder.
    @State private var documentsAdded = false

    private let headerHeight: CGFloat = 24
    /// The panel's one gutter: the title and the tiles sit this far in from the grid's scroll view, whose edges clip, so
    /// the focus ring, its glow and the hover lift always fit.
    private let gutter: CGFloat = Theme.gridPadding
    private let titleHeight: CGFloat = 16
    private let titleSpacing: CGFloat = 8

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        let layout = model.layout
        let width = gridWidth
        // The tiles sit a gutter in from the scroll view's edges, which clip: the ring, its glow and the hover lift fit.
        let size = tileSize(width: width - 2 * gutter, columns: layout.columns)
        VStack(alignment: .leading, spacing: 0) {
            header(layout)
            if layout.picks.isEmpty && !layout.isLoading {
                emptyState(layout)
            } else {
                grid(layout, size: size)
            }
        }
        .frame(width: width, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: layout.title))
    }

    /// The grid's width, gutters included: the panel's, less the camera's column while it shows.
    private var gridWidth: CGFloat {
        model.showsFaceColumn ? Theme.panelWidth - Theme.faceColumnWidth : Theme.panelWidth
    }

    private func tileSize(width: CGFloat, columns: Int) -> CGFloat {
        let count = CGFloat(max(1, columns))
        return floor((width - (count - 1) * Theme.gridSpacing) / count)
    }

    // MARK: Header

    private func header(_ layout: PickerLayout) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: layout.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.mutedText)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if showsLookInDocuments {
                Button("Look in Documents…") {
                    guard let url = documentsURL else { return }
                    documentsAdded = true
                    model.indexer.addWatchedFolders([url])
                }
                .buttonStyle(PanelLinkButtonStyle(fontSize: 11))
            } else if model.source.showsOwn && !model.hasMemes && model.offersFindMyMemes {
                Button("Find my memes") {
                    model.findMyMemes()
                }
                .buttonStyle(PanelLinkButtonStyle(fontSize: 11))
                .help("Collect the memes in Downloads, Desktop and your screenshots")
            }
            if layout.showsGiphy {
                PoweredByGiphyMark()
            }
        }
        .padding(.horizontal, gutter)
        .frame(height: headerHeight)
    }

    private var documentsURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.standardizedFileURL
    }

    private var showsLookInDocuments: Bool {
        guard model.mode == .text, model.source.showsOwn, !documentsAdded, model.results.count < Theme.columns,
              let url = documentsURL else { return false }
        return !model.indexer.isWatching(url)
    }

    // MARK: Grid

    private func grid(_ layout: PickerLayout, size: CGFloat) -> some View {
        let columns = layout.columns
        let filledRows = (layout.picks.count + columns - 1) / columns
        // While more is on its way, placeholders finish the last row and add one more.
        let rowCount = layout.isLoading ? filledRows + 1 : filledRows
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.gridRowSpacing) {
                    ForEach(0..<rowCount, id: \.self) { row in
                        HStack(alignment: .top, spacing: Theme.gridSpacing) {
                            ForEach(0..<columns, id: \.self) { column in
                                cell(row * columns + column, layout: layout, size: size)
                            }
                        }
                        .id(row)
                    }
                }
                // Room for the focus ring and the hover lift, which reach past a tile's edge.
                .padding(.horizontal, gutter)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .mask(
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 20)
                }
            )
            .onChange(of: model.focusedIndex) { _, focused in
                guard focused >= 0 else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(focused / max(1, columns))
                }
            }
            .onChange(of: layout.title) { _, _ in
                proxy.scrollTo(0, anchor: .top)
            }
        }
    }

    @ViewBuilder
    private func cell(_ slot: Int, layout: PickerLayout, size: CGFloat) -> some View {
        if let pick = layout.pick(at: slot) {
            PickerTile(pick: pick, size: size, isFocused: model.focusedIndex == slot,
                       marksType: model.source == .all || model.source == .favorites, model: model)
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
                        Button("More Like This") {
                            model.hover(index: slot)
                            model.moreLikeFocused()
                        }
                    }
                    if model.canSave(pick) {
                        Button(model.isSaved(pick) ? "Remove from Favorites" : "Add to Favorites") {
                            model.toggleSaved(pick)
                        }
                    }
                    if AppModel.link(for: pick) != nil {
                        Button("Copy Link") {
                            model.hover(index: slot)
                            model.perform(.copyLink)
                        }
                        Button(pick.isFromGiphy ? "Open on GIPHY" : "Open in Browser") {
                            model.hover(index: slot)
                            model.perform(.openInBrowser)
                        }
                    }
                }
                .accessibilityAction {
                    model.commit(index: slot)
                }
        } else if layout.isLoading {
            VStack(alignment: .leading, spacing: titleSpacing) {
                RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                    .fill(Theme.tileBackground)
                    .frame(width: size, height: size)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Theme.tileBackground)
                    .frame(width: size * 0.6, height: 8)
                    .frame(height: titleHeight)
            }
            .accessibilityHidden(true)
        } else {
            Color.clear
                .frame(width: size, height: size + titleSpacing + titleHeight)
                .accessibilityHidden(true)
        }
    }

    // MARK: Empty

    private func emptyState(_ layout: PickerLayout) -> some View {
        VStack(spacing: 10) {
            if let message = layout.message, !message.isEmpty {
                Text(verbatim: message)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.mutedText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.source.showsOwn && !model.hasMemes && model.offersFindMyMemes {
                Button("Find my memes") {
                    model.findMyMemes()
                }
                .buttonStyle(PanelCapsuleButtonStyle(fontSize: 12, foreground: Theme.text))
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// GIPHY's attribution beside the grid's title while GIPHY's GIFs show: "Powered by" and GIPHY's logo from the app's
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

    /// Resources/GIPHY/GIPHYLogo.png: GIPHY's logo, white lettering on transparent, copied into the app by
    /// scripts/build-app.sh.
    static let logo: NSImage? = Bundle.main.image(forResource: "GIPHYLogo")
}

// MARK: - Tiles

/// One result: its picture in a square (a sticker whole, cut out; a classic meme whole, letterboxed), its name under
/// it beside a small badge saying where it is from. The focused one has a 2 pt ring in the signal color 2 pt out and
/// plays when it is a GIF. One of your things you starred carries a star; pointing at one of yours shows ☆ in its
/// place, which stars it.
struct PickerTile: View {
    let pick: Pick
    let size: CGFloat
    let isFocused: Bool
    /// Kinds mix (All Sources, Favorites): GIFs of yours carry a "GIF" tag.
    let marksType: Bool
    @ObservedObject var model: AppModel

    @State private var isHovered = false

    private let cornerRadius: CGFloat = Theme.tileRadius

    init(pick: Pick, size: CGFloat, isFocused: Bool, marksType: Bool, model: AppModel) {
        self.pick = pick
        self.size = size
        self.isFocused = isFocused
        self.marksType = marksType
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            art
            HStack(spacing: 6) {
                SourceBadge(pick: pick)
                Text(verbatim: pick.title.isEmpty ? "Untitled" : pick.title)
                    .font(.system(size: 12, weight: isFocused ? .semibold : .medium))
                    .foregroundColor(isFocused ? Color.white : Theme.softTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: size, height: 16, alignment: .leading)
        }
        .onHover { inside in
            isHovered = inside
        }
        .contentShape(Rectangle())
        .help(pick.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var art: some View {
        content
            .frame(width: size, height: size)
            .background(Theme.tileBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(isHovered && !isFocused ? Theme.tileEdgeHover : Theme.tileEdge, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(isHovered && !isFocused ? 0.3 : 0), radius: 12, x: 0, y: 10)
            .overlay(alignment: .bottomLeading) { gifTag }
            .overlay(alignment: .topTrailing) { saveControl }
            .overlay { ring }
            .offset(y: isHovered && !isFocused ? -2 : 0)
            .animation(.easeOut(duration: 0.14), value: isHovered)
    }

    @ViewBuilder
    private var content: some View {
        switch pick {
        case let .meme(item):
            OwnTileContent(item: item, isFocused: isFocused, size: size)
        case let .gif(gif):
            GiphyTileContent(gif: gif, isFocused: isFocused, web: model.web, size: size, isSticker: false)
        case let .giphySticker(gif):
            GiphyTileContent(gif: gif, isFocused: isFocused, web: model.webStickers, size: size, isSticker: true)
        case let .template(template):
            TemplateTileContent(template: template, model: model, size: size)
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

    /// Pointing at one of yours: ☆ (★ once starred). Otherwise a starred one shows its star.
    @ViewBuilder
    private var saveControl: some View {
        if model.canSave(pick) {
            let saved = model.isSaved(pick)
            if isHovered {
                Button {
                    model.toggleSaved(pick)
                } label: {
                    Image(systemName: saved ? "star.fill" : "star")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Theme.background.opacity(0.72)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(6)
                .help(Text(verbatim: saved ? "Remove from Favorites (⌘S)" : "Add to Favorites (⌘S)"))
                .accessibilityHidden(true)
            } else if saved {
                Image(systemName: "star.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Theme.badgeBackground))
                    .padding(6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var ring: some View {
        if isFocused {
            // White, like the rest of the glass: a 2 pt ring hugging the tile and a faint 4 pt halo around it. Orange is
            // kept for the ↩ key that copies it.
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius + 4, style: .continuous)
                    .stroke(Theme.selectionHalo, lineWidth: 4)
                    .padding(-4)
                RoundedRectangle(cornerRadius: cornerRadius + 1, style: .continuous)
                    .stroke(Theme.selectionRing, lineWidth: 2)
                    .padding(-1)
            }
            .allowsHitTesting(false)
        }
    }

    private var accessibilityText: String {
        let action = "Copy and go back to the chat."
        switch pick {
        case let .meme(item):
            let source: String
            switch item.kind {
            case .mine: source = item.isSticker ? "your sticker" : "on your Mac"
            case .friend: source = "friend sticker"
            case .pack: source = "from a pack"
            case .web: source = item.attribution ?? "via GIPHY"
            }
            let format = item.isAnimated ? ", GIF" : ""
            let saved = model.isSaved(pick) ? ", favorite" : ""
            return "\(item.displayName), \(source)\(format)\(saved). \(action)"
        case let .gif(gif):
            let creator = gif.creator.map { " by \($0)" } ?? ""
            return "\(gif.title), GIF\(creator) from GIPHY. \(action)"
        case let .giphySticker(gif):
            let creator = gif.creator.map { " by \($0)" } ?? ""
            return "\(gif.title), sticker\(creator) from GIPHY. \(action)"
        case let .template(template):
            return "\(template.name), classic meme from Imgflip. \(action)"
        }
    }
}

/// Where a result is from, beside its name: GIPHY (a "G"), a classic meme, one of your stickers, or your Mac.
private struct SourceBadge: View {
    let pick: Pick

    var body: some View {
        Group {
            if pick.isFromGiphy {
                Text(verbatim: "G")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundColor(Theme.text)
                    .frame(width: 14, height: 14)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.black))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .frame(width: 14, height: 14)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.glassFillStrong))
            }
        }
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch pick {
        case let .meme(item): return item.isSticker ? "face.smiling" : "laptopcomputer"
        case .template: return "text.below.photo"
        case .gif, .giphySticker: return "play.rectangle"
        }
    }
}

/// One of your things: its thumbnail filling the tile (a sticker whole, cut out on the tile), playing while focused
/// when it is a GIF.
private struct OwnTileContent: View {
    let item: LibraryItem
    let isFocused: Bool
    let size: CGFloat

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
                        .padding(8)
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
        .frame(width: size, height: size)
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
        let loaded = await ThumbnailCache.shared.thumbnail(for: url, maxPixel: 320)
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

/// A GIF or sticker from GIPHY: its small still, playing its preview while focused. A sticker shows whole.
private struct GiphyTileContent: View {
    let gif: WebGIF
    let isFocused: Bool
    let web: WebDiscover
    let size: CGFloat
    let isSticker: Bool

    @State private var still: NSImage? = nil
    @State private var animation: NSImage? = nil

    var body: some View {
        let image = still ?? web.cachedStill(for: gif)
        ZStack {
            if let image {
                if isSticker {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            if isFocused, let animation {
                // Display-only, so the tile keeps its tap and drag gestures.
                AnimatedImageView(image: animation)
                    .padding(isSticker ? 8 : 0)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .task(id: gif.stillURL) { @MainActor in
            if web.cachedStill(for: gif) == nil {
                let loaded = await web.still(for: gif)
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
            let loaded = await web.preview(for: gif)
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
    let size: CGFloat

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
        .frame(width: size, height: size)
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
