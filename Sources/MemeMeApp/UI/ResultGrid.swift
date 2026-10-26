import AppKit
import MemeMeCore
import SwiftUI

/// The 5 × 2 grid of results. Empty slots keep their place so the panel never jumps.
struct ResultGrid: View {
    @ObservedObject var model: AppModel

    @State private var documentsAdded = false

    private let spacing: CGFloat = 8

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        let entries = gridEntries
        let showsDocuments = showsDocumentsTile(resultCount: entries.count)
        let placeholderCount = max(0, Theme.resultLimit - entries.count - (showsDocuments ? 1 : 0))

        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: spacing) {
            ForEach(entries) { entry in
                ResultTile(
                    result: entry.result,
                    number: entry.index < 9 ? entry.index + 1 : nil,
                    isFocused: entry.index == model.focusedIndex,
                    isNew: model.newResultIDs.contains(entry.result.id),
                    model: model
                )
                .onHover { inside in
                    if inside {
                        model.hover(index: entry.index)
                    }
                }
                .onTapGesture {
                    model.commit(index: entry.index)
                }
                .onDrag {
                    // The panel controller closes the panel when the drag is released outside it.
                    TileDragEvents.dragDidBegin?()
                    return model.dragItemProvider(index: entry.index) ?? NSItemProvider()
                }
                .accessibilityAction {
                    model.commit(index: entry.index)
                }
            }
            if showsDocuments {
                DocumentsTile {
                    addDocumentsFolder()
                }
            }
            ForEach(0..<placeholderCount, id: \.self) { _ in
                PlaceholderTile()
            }
        }
        .overlay(alignment: .bottom) {
            if entries.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.mutedText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 34)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Private

    private struct GridEntry: Identifiable {
        let index: Int
        let result: RankedResult
        var id: UUID { result.id }
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: Theme.columns)
    }

    private var gridEntries: [GridEntry] {
        model.results.prefix(Theme.resultLimit).enumerated().map { pair in
            GridEntry(index: pair.offset, result: pair.element)
        }
    }

    private var emptyMessage: String {
        let query = model.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.mode == .text && !query.isEmpty {
            return "No images match “\(query)”."
        }
        return "Drop memes here, or find the ones on this Mac"
    }

    private var documentsURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.standardizedFileURL
    }

    /// "Not here? Look in Documents…" after too few typed-search results, until Documents is watched.
    private func showsDocumentsTile(resultCount: Int) -> Bool {
        guard model.mode == .text, !documentsAdded, resultCount < Theme.resultLimit,
              let url = documentsURL else {
            return false
        }
        return !model.indexer.isWatching(url)
    }

    private func addDocumentsFolder() {
        guard let url = documentsURL else { return }
        documentsAdded = true
        model.indexer.addWatchedFolders([url])
    }
}

/// One result: aspect-filled thumbnail with number, source and format badges.
struct ResultTile: View {
    let result: RankedResult
    let number: Int?
    let isFocused: Bool
    let isNew: Bool
    @ObservedObject var model: AppModel

    @State private var thumbnail: NSImage? = nil
    @State private var animatedURL: URL? = nil

    private let cornerRadius: CGFloat = 10

    init(result: RankedResult, number: Int?, isFocused: Bool, isNew: Bool, model: AppModel) {
        self.result = result
        self.number = number
        self.isFocused = isFocused
        self.isNew = isNew
        _model = ObservedObject(wrappedValue: model)
    }

    private var item: LibraryItem { result.item }

    var body: some View {
        let still = thumbnail ?? ThumbnailCache.shared.cached(item.fileURL)

        Theme.surface
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let still {
                    Image(nsImage: still)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .overlay {
                if isFocused, let animatedURL {
                    // Display-only, so the tile keeps its tap and drag gestures.
                    AnimatedImageView(url: animatedURL)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(alignment: .topLeading) { numberBadge }
            .overlay(alignment: .topTrailing) { sourceMarker }
            .overlay(alignment: .bottomLeading) { gifBadge }
            .overlay(alignment: .bottomTrailing) { webLabel }
            .overlay { ring }
            .animation(.easeOut(duration: 0.2), value: isNew)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isButton)
            .task(id: item.fileURL) { @MainActor in
                await loadThumbnail()
            }
            .task(id: animationKey) { @MainActor in
                await loadAnimation()
            }
    }

    // MARK: Badges

    @ViewBuilder
    private var numberBadge: some View {
        if let number {
            Text(String(number))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 18, minHeight: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.badgeBackground)
                )
                .padding(5)
        }
    }

    /// Own items: accent dot. Friend stickers: amber ring.
    @ViewBuilder
    private var sourceMarker: some View {
        switch item.kind {
        case .mine:
            ZStack {
                Circle().fill(Theme.background)
                    .frame(width: 13, height: 13)
                Circle().fill(Theme.accent)
                    .frame(width: 9, height: 9)
            }
            .padding(5)
        case .friend:
            Circle()
                .strokeBorder(Theme.amber, lineWidth: 2.5)
                .background(Circle().fill(Theme.background))
                .frame(width: 11, height: 11)
                .padding(6)
        case .pack, .web:
            EmptyView()
        }
    }

    @ViewBuilder
    private var gifBadge: some View {
        if item.isAnimated {
            MicroBadge(text: "GIF", weight: .bold)
                .padding(5)
        }
    }

    @ViewBuilder
    private var webLabel: some View {
        if item.kind == .web {
            MicroBadge(text: item.attribution ?? "via GIPHY", weight: .medium)
                .padding(5)
        }
    }

    /// Focus: 2 px accent ring with a 2 px gap. Just arrived: the same ring in amber.
    @ViewBuilder
    private var ring: some View {
        if isFocused || isNew {
            RoundedRectangle(cornerRadius: cornerRadius + 3, style: .continuous)
                .stroke(isFocused ? Theme.accent : Theme.amber, lineWidth: 2)
                .padding(-3)
                .allowsHitTesting(false)
        }
    }

    private var accessibilityText: String {
        let source: String
        switch item.kind {
        case .mine: source = "from your library"
        case .friend: source = "friend sticker"
        case .pack: source = "from a pack"
        case .web: source = item.attribution ?? "via GIPHY"
        }
        let format = item.isAnimated ? ", GIF" : ""
        return "\(item.displayName), \(source)\(format). Copy and go back to the chat."
    }

    // MARK: Loading

    private var animationKey: String {
        "\(result.id.uuidString)|\(isFocused)|\(item.isAnimated)"
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
        if item.kind == .web {
            let preview = await model.web.localPreview(for: item)
            if !Task.isCancelled {
                animatedURL = preview
            }
        } else {
            animatedURL = item.fileURL
        }
    }
}

// MARK: - Supporting tiles

/// Tiny dark chip used for "GIF" and "via GIPHY".
private struct MicroBadge: View {
    let text: String
    let weight: Font.Weight

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: weight))
            .foregroundColor(.white)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.badgeBackground)
            )
            .fixedSize()
    }
}

/// "Not here? Look in Documents…": adds Documents as a watched folder.
private struct DocumentsTile: View {
    let action: () -> Void

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                Button(action: action) {
                    VStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 15))
                            .accessibilityHidden(true)
                        Text("Not here? Look in Documents…")
                            .font(.system(size: 10))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    }
                    .foregroundColor(Theme.softText)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.keycapBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .allowsHitTesting(false)
            )
    }
}

/// Faint square holding an empty slot.
private struct PlaceholderTile: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.surface.opacity(0.45))
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}
