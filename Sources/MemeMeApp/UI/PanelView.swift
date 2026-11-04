import AppKit
import MemeMeCore
import SwiftUI
import UniformTypeIdentifiers

/// The drawer: it hangs from the notch, flush with the top of the screen. Its top band, the height of the menu bar,
/// has an ear on each side of the notch: the query on the left (the word your face read, or what you type), the tabs
/// on the right. Under it: your face in a circle on the left, and two rows of 5 tiles for the tab showing; GIPHY's
/// credit under them while GIPHY's GIFs show; a footer only while there is something to act on.
struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var metrics: NotchMetrics

    @FocusState private var searchFocused: Bool
    @State private var isDropTargeted = false

    init(model: AppModel, metrics: NotchMetrics) {
        _model = ObservedObject(wrappedValue: model)
        _metrics = ObservedObject(wrappedValue: metrics)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ears
            if model.isCaptureOpen {
                CaptureView(model: model)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 18)
            } else {
                drawerBody
            }
        }
        .padding(.horizontal, Theme.shoulder)
        .frame(width: Theme.panelWidth, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(DrawerShape().fill(Theme.background))
        .clipShape(DrawerShape())
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            searchFocused = true
        }
        .onChange(of: model.isPanelVisible) { _, visible in
            if visible {
                searchFocused = true
            }
        }
        .onChange(of: model.isCaptureOpen) { _, open in
            // Back from the capture view: typing searches again.
            if !open {
                searchFocused = true
            }
        }
        .task(id: model.isPanelVisible) { @MainActor in
            // The panel becomes key just after it is shown; focus the field once it is.
            guard model.isPanelVisible else { return }
            try? await Task.sleep(nanoseconds: 60_000_000)
            if !Task.isCancelled && model.isPanelVisible {
                searchFocused = true
            }
        }
        .task(id: model.showSetupCard) { @MainActor in
            // Closing the You're-set card brings the search field back and makes the panel key again.
            guard !model.showSetupCard, model.isPanelVisible else { return }
            try? await Task.sleep(nanoseconds: 60_000_000)
            if !Task.isCancelled && !model.showSetupCard && model.isPanelVisible {
                searchFocused = true
            }
        }
    }

    // MARK: Ears

    /// The band beside the notch: the query in the left ear, the tabs in the right one. Neither reaches under the
    /// notch (`metrics.notchWidth`; 0 on a screen without one, where the ears meet).
    private var ears: some View {
        let inner = Theme.panelWidth - 2 * Theme.shoulder
        let earWidth = max(0, (inner - metrics.notchWidth) / 2)
        return HStack(spacing: 0) {
            if !model.isCaptureOpen {
                queryField
                    .frame(width: max(120, min(earWidth - 36, 300)), alignment: .leading)
            }
            Spacer(minLength: 0)
            if !model.isCaptureOpen && !model.showSetupCard {
                TabBar(model: model)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .frame(height: metrics.bandHeight)
    }

    /// The query: the word the camera's search went by (dimmed while a new face is held toward replacing it), or what
    /// you type. Its glyph says where the search comes from: your face or pose, or words (with your face kept: click
    /// it to drop the face).
    private var queryField: some View {
        HStack(spacing: 6) {
            queryGlyph
            ZStack(alignment: .leading) {
                if model.queryText.isEmpty {
                    queryPlaceholder
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextField("", text: $model.queryText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.text)
                    .focused($searchFocused)
                    .accessibilityLabel("Search by typing, or drop or paste an image")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 2)
        .padding(.trailing, 10)
        .frame(height: 26)
        .background(Capsule().fill(Theme.raised2))
        .overlay(
            Capsule().strokeBorder(model.queryText.isEmpty ? Color.clear : Theme.line, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var queryPlaceholder: some View {
        if let readout = model.readout {
            Text(verbatim: readout.word)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(model.holdProgress >= 0.05 ? 0.45 : 1)
                .animation(.easeOut(duration: 0.15), value: readout)
        } else {
            Text("Type to search")
                .font(.system(size: 13))
                .foregroundColor(Theme.placeholderText)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var queryGlyph: some View {
        if model.showsFaceToken {
            Button {
                model.removeFaceToken()
            } label: {
                glyphCircle("face.smiling", filled: true)
            }
            .buttonStyle(.plain)
            .help(model.faceTokenIsPose ? "Stop using your pose in this search" : "Stop using your face in this search")
            .accessibilityLabel(model.faceTokenIsPose ? "Stop using your pose in this search" : "Stop using your face in this search")
        } else if model.queryText.isEmpty, let readout = model.readout {
            glyphCircle(readout.named ? "sparkles" : (readout.source == .face ? "face.smiling" : "figure.arms.open"),
                        filled: false)
                .accessibilityHidden(true)
        } else {
            glyphCircle("magnifyingglass", filled: false)
                .accessibilityHidden(true)
        }
    }

    private func glyphCircle(_ symbol: String, filled: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(filled ? Theme.onAccent : Theme.text)
            .frame(width: 22, height: 22)
            .background(Circle().fill(filled ? Theme.text : Theme.line))
    }

    // MARK: Body

    private var drawerBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.showSetupCard {
                SetupCardView(model: model)
            }
            if !model.showSetupCard, let naming = model.naming, !naming.candidates.isEmpty {
                NamingRow(prompt: naming) { personID in
                    model.nameUnknownFace(personID: personID)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                MirrorColumn(model: model)
                VStack(alignment: .trailing, spacing: 8) {
                    DrawerGrid(model: model)
                        .overlay {
                            if showsDrop {
                                DropCard()
                            }
                        }
                    giphyCredit
                }
                .opacity(model.showSetupCard ? 0.55 : 1)
            }
            if model.footer != .hidden {
                FooterView(model: model)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    /// GIPHY's credit, right under the tiles while GIPHY's GIFs show; the line keeps its height when they don't, so
    /// switching tabs never resizes the drawer.
    private var giphyCredit: some View {
        ZStack(alignment: .trailing) {
            Color.clear
                .frame(height: 14)
            if model.layout.showsGiphy {
                PoweredByGiphyMark()
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// An image dragged over the panel, not one of its own tiles on its way out.
    private var showsDrop: Bool {
        isDropTargeted && !model.isDraggingTile
    }

    // MARK: Drop

    /// Files and images dropped on the panel become an image query (never saved silently).
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        // A tile dragged out and let go over the panel isn't a search for itself.
        guard !model.isCaptureOpen, !model.isDraggingTile else { return false }
        let model = self.model
        let fileType = UTType.fileURL.identifier
        let imageType = UTType.image.identifier

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(fileType) }) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in
                    model.search(withImageAt: url)
                }
            }
            return true
        }
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(imageType) }) {
            _ = provider.loadFileRepresentation(forTypeIdentifier: imageType) { url, _ in
                // The provided file is deleted when this handler returns, so copy it first.
                guard let url, let copy = copyDroppedImageToTemporaryFile(url) else { return }
                Task { @MainActor in
                    model.search(withImageAt: copy)
                }
            }
            return true
        }
        return false
    }
}

/// Copies a dropped image representation to a stable temporary file.
private func copyDroppedImageToTemporaryFile(_ url: URL) -> URL? {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory.appendingPathComponent("MemeMeDrops", isDirectory: true)
    do {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let pathExtension = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let destination = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pathExtension)
        try fileManager.copyItem(at: url, to: destination)
        return destination
    } catch {
        return nil
    }
}

/// Shown over the results while an image is dragged over the panel.
private struct DropCard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.background.opacity(0.92))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            )
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 20))
                        .foregroundColor(Theme.text)
                    Text("Drop to search with it")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.text)
                    Text("It isn’t saved unless you keep it.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.mutedText)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - "Is one of these Sam?"

/// Lazy naming: up to three unnamed faces to attach a typed name to.
private struct NamingRow: View {
    let prompt: NamingPrompt
    let onPick: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "Is one of these \(prompt.name)?")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.text)
                .lineLimit(1)
            HStack(spacing: 8) {
                ForEach(Array(prompt.candidates.prefix(3))) { candidate in
                    candidateButton(candidate)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
        )
    }

    private func candidateButton(_ candidate: NamingCandidate) -> some View {
        let caption = Self.caption(for: candidate)
        let label = "This is \(prompt.name) — \(caption)"
        return Button {
            onPick(candidate.personID)
        } label: {
            candidateLabel(candidate, caption: caption)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: label))
    }

    private func candidateLabel(_ candidate: NamingCandidate, caption: String) -> some View {
        HStack(spacing: 8) {
            NamingFace(sample: candidate.sample)
            Text(verbatim: caption)
                .font(.system(size: 11))
                .foregroundColor(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .overlay(Capsule().strokeBorder(Theme.chipBorder, lineWidth: 1))
        .contentShape(Capsule())
    }

    private static func caption(for candidate: NamingCandidate) -> String {
        let count = candidate.stickerCount
        return "New face · \(count) sticker" + (count == 1 ? "" : "s")
    }
}

/// Round sample sticker of an unnamed person.
private struct NamingFace: View {
    let sample: LibraryItem?

    @State var image: NSImage? = nil

    var body: some View {
        ZStack {
            Circle().fill(Theme.checkerDark)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.mutedText)
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: sample?.fileURL) { @MainActor in
            guard let url = sample?.fileURL else {
                image = nil
                return
            }
            if let cached = ThumbnailCache.shared.cached(url, minPixel: 96) {
                image = cached
                return
            }
            let loaded = await ThumbnailCache.shared.thumbnail(for: url, maxPixel: 96)
            if !Task.isCancelled {
                image = loaded
            }
        }
    }
}

// MARK: - Tabs

/// The right ear: For You · GIFs · Stickers · Memes. Tab and Shift-Tab move along them; the panel opens on For You.
private struct TabBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ResultTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .help("Tab: the next type")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Type")
    }

    private func tabButton(_ tab: ResultTab) -> some View {
        let isSelected = model.tab == tab
        return Button {
            model.selectTab(tab)
        } label: {
            Text(verbatim: tab.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isSelected ? Theme.text : Theme.mutedText)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Theme.raised2 : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
