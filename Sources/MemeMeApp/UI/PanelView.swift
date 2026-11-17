import AppKit
import MemeMeCore
import SwiftUI
import UniformTypeIdentifiers

/// The panel: a search field across the top (the source menu at its right), the grid of results under it (the
/// camera's column beside it while face search is on), and a bar along the bottom: "Search with your face" (⌘F) on the
/// left; "Copy GIF ↩" and "Actions ⌘K" on the right. The source menu and the actions open over the panel. The face
/// editor and a footer (memes being collected, an update) grow it downward.
struct PanelView: View {
    @ObservedObject var model: AppModel

    private enum Field: Hashable { case search, menu }

    @FocusState private var focus: Field?
    @State private var isDropTargeted = false

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBar
            // The islands float over the results, which run to the panel's bottom edge under them.
            content
        }
        .frame(width: Theme.panelWidth, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        // Frosted glass over the desktop, under the menus (which are glass of their own).
        .glass(cornerRadius: Theme.panelRadius, blending: .behindWindow, shadow: false)
        .overlay { menuLayer }
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .environment(\.colorScheme, .dark)
        // Pinned to the window's top. The window is resized to fit a moment after the content changes (the face
        // editor opening or closing); until then a centered panel would jump by half the change and back.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            focus = .search
        }
        .onChange(of: model.isPanelVisible) { _, visible in
            if visible { focus = .search }
        }
        .onChange(of: model.menu) { _, menu in
            focus = menu == nil ? .search : .menu
        }
        .task(id: model.isPanelVisible) { @MainActor in
            // The panel becomes key just after it is shown; focus the field once it is.
            guard model.isPanelVisible else { return }
            try? await Task.sleep(nanoseconds: 60_000_000)
            if !Task.isCancelled && model.isPanelVisible {
                focus = model.menu == nil ? .search : .menu
            }
        }
        .task(id: model.showSetupCard) { @MainActor in
            // Closing the You're-set card brings the search field back and makes the panel key again.
            guard !model.showSetupCard, model.isPanelVisible else { return }
            try? await Task.sleep(nanoseconds: 60_000_000)
            if !Task.isCancelled && !model.showSetupCard && model.isPanelVisible {
                focus = .search
            }
        }
    }

    // MARK: Search bar

    /// The search field: what you type searches the source showing. Once the camera caught a face its word sits in the
    /// field as a token (× drops it), and what you type refines it. The source menu sits at the right.
    private var searchBar: some View {
        HStack(spacing: 12) {
            queryGlyph
            if model.queryText.isEmpty, let readout = model.readout {
                faceToken(readout)
            }
            ZStack(alignment: .leading) {
                if model.queryText.isEmpty {
                    Text(verbatim: model.searchPlaceholder)
                        .font(.system(size: 17))
                        .foregroundColor(Theme.placeholderText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextField("", text: $model.queryText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .foregroundColor(Theme.text)
                    .focused($focus, equals: .search)
                    .accessibilityLabel("Search GIFs, stickers and memes, or drop or paste an image")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            sourceButton
        }
        .padding(.horizontal, Theme.gridPadding)
        .frame(height: Theme.searchBarHeight)
    }

    @ViewBuilder
    private var queryGlyph: some View {
        if model.showsFaceToken {
            Button {
                model.removeFaceToken()
            } label: {
                Image(systemName: "face.smiling.inverse")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(Theme.accent)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(model.faceTokenIsPose ? "Stop using your pose in this search" : "Stop using your face in this search")
            .accessibilityLabel(model.faceTokenIsPose ? "Stop using your pose in this search" : "Stop using your face in this search")
        } else {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(Theme.mutedText)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        }
    }

    /// The word the camera's search went by, as a token in the field: where it came from (your face, your pose, or
    /// sparkles when the on-device model named the pose), the word (an edit that changed it shows the old one struck
    /// out), and × to say "not this face".
    private func faceToken(_ readout: MoodReadout) -> some View {
        let dismissable = model.canDismissCaughtFace
        return HStack(spacing: 5) {
            Image(systemName: readout.named ? "sparkles" : (readout.source == .face ? "face.smiling" : "figure.arms.open"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.accent)
                .accessibilityHidden(true)
            if let replaced = model.replacedWord {
                Text(verbatim: replaced)
                    .font(.system(size: 13, weight: .medium))
                    .strikethrough(true, color: Theme.mutedText)
                    .foregroundColor(Theme.mutedText)
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Theme.mutedText)
                    .accessibilityHidden(true)
            }
            Text(verbatim: readout.word)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            if dismissable {
                Button {
                    model.dismissCaughtFace()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Theme.mutedText)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Not this face: back to your recent picks")
                .accessibilityLabel("Not this face")
            }
        }
        .foregroundColor(Theme.text)
        .padding(.leading, 9)
        .padding(.trailing, dismissable ? 3 : 10)
        .frame(height: 28)
        .background(Capsule().fill(Theme.keyFill))
        .overlay(Capsule().strokeBorder(Theme.glassEdge, lineWidth: 1))
        .opacity(model.holdProgress >= 0.05 ? 0.45 : 1)
        .animation(.easeOut(duration: 0.15), value: readout)
        .animation(.easeOut(duration: 0.2), value: model.replacedWord)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "Searching \(readout.word)"))
    }

    /// The source showing, at the right of the search field; a click (or ⌘P) opens the source menu.
    private var sourceButton: some View {
        let isOpen = model.menu == .sources
        return Button {
            model.toggleMenu(.sources)
        } label: {
            HStack(spacing: 7) {
                SourceGlyph(symbol: model.source.isGiphy ? nil : AppModel.symbol(for: model.source),
                            letter: model.source.isGiphy ? "G" : nil, size: 18)
                Text(verbatim: model.source.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.mutedText)
            }
            .padding(.leading, 7)
            .padding(.trailing, 9)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isOpen ? Theme.glassFillStrong : Theme.glassFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.glassEdge, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Choose where results come from (⌘P)")
        .accessibilityLabel(Text(verbatim: "Source: \(model.source.title)"))
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.showSetupCard {
                SetupCardView(model: model)
                    .padding(.horizontal, Theme.gridPadding)
                    .padding(.top, 14)
            }
            if !model.showSetupCard, let naming = model.naming, !naming.candidates.isEmpty {
                NamingRow(prompt: naming) { personID in
                    model.nameUnknownFace(personID: personID)
                }
                .padding(.horizontal, Theme.gridPadding)
                .padding(.top, 12)
            }
            HStack(alignment: .top, spacing: 0) {
                if model.showsFaceColumn {
                    FaceColumn(model: model)
                        .padding(.leading, Theme.gridPadding)
                }
                // The grid insets its own content by the gutter: its scroll view then reaches the panel's edge, so the
                // focus ring's glow is never clipped.
                PickerGrid(model: model)
                    .overlay {
                        if showsDrop {
                            DropCard()
                                .padding(.horizontal, Theme.gridPadding)
                                .padding(.vertical, 12)
                        }
                    }
                    .opacity(model.showSetupCard ? 0.55 : 1)
            }
            .frame(height: Theme.contentHeight + Theme.bottomBarHeight, alignment: .top)
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if let notice = model.clipNotice {
                        ClipNoticeView(model: model, notice: notice)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    bottomBar
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.clipNotice)
            }
            if model.faceEdit != nil {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                FaceEditorView(model: model)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
            }
            if model.footer != .hidden {
                FooterView(model: model)
                    .padding(.horizontal, Theme.gridPadding)
                    .padding(.bottom, 12)
            }
        }
    }

    /// An image dragged over the panel, not one of its own tiles on its way out.
    private var showsDrop: Bool {
        isDropTargeted && !model.isDraggingTile
    }

    // MARK: Bottom bar

    /// Islands along the bottom, floating over the results (no strip behind them: the grid runs on under them), 16 pt
    /// from the panel's edges like everything else: your face and ✂ share the left one
    /// (MemeMe's own), "Copy ↩ · Actions ⌘K" the right one. Their labels never change, so nothing moves as the pointer
    /// passes over the tiles (what will be copied shows on the tile itself).
    private var bottomBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                faceButton
                Rectangle().fill(Theme.glassFillStrong).frame(width: 1, height: 16)
                scissorsButton
            }
            .island(highlighted: model.faceSearchOn)
            Spacer(minLength: 8)
            if model.focusedPick != nil {
                HStack(spacing: 2) {
                    Button {
                        model.perform(.copy)
                    } label: {
                        HStack(spacing: 8) {
                            Text("Copy")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.text)
                            Keycap("↩", filled: true)
                        }
                        .padding(.leading, 10)
                        .padding(.trailing, 5)
                        .frame(height: Theme.islandButtonHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(IslandButtonStyle())
                    .help(Text(verbatim: "\(model.copyLabel) and go back to the chat. MemeMe never pastes for you."))
                    .accessibilityLabel(Text(verbatim: model.copyLabel))
                    Rectangle().fill(Theme.glassFillStrong).frame(width: 1, height: 16)
                    Button {
                        model.toggleMenu(.actions)
                    } label: {
                        HStack(spacing: 8) {
                            Text("Actions")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Theme.softTitle)
                            Keycap("⌘K")
                        }
                        .padding(.leading, 10)
                        .padding(.trailing, 5)
                        .frame(height: Theme.islandButtonHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(IslandButtonStyle(selected: model.menu == .actions))
                    .accessibilityLabel("Actions")
                }
                .island()
            }
        }
        .padding(.horizontal, Theme.gridPadding)
        .padding(.top, 8)
        .padding(.bottom, Theme.gridPadding)
        .frame(height: Theme.bottomBarHeight)
    }

    /// ✂: with face search on, "Clip me" clips your reaction from the camera (tap a still, hold a moving one); off, it
    /// cuts a sticker out of the screen. ⌥S does the same.
    @ViewBuilder
    private var scissorsButton: some View {
        if model.faceSearchOn {
            ClipButton(model: model, capture: model.capture)
        } else {
            Button {
                model.requestScreenCut()
            } label: {
                Image(systemName: "scissors")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.softTitle)
                    .frame(width: Theme.islandButtonHeight, height: Theme.islandButtonHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(IslandButtonStyle())
            .help("Cut a sticker out of your screen (⌥S)")
            .accessibilityLabel("Cut a sticker out of your screen")
        }
    }

    /// Bottom left, MemeMe's own: the camera searches with your face (⌘F); again, it stops. The words stay put; while
    /// it is on, the camera fills in the signal color and the island takes its tint.
    private var faceButton: some View {
        let on = model.faceSearchOn
        return Button {
            model.toggleFaceSearch()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(on ? Theme.onAccent : Theme.text)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(on ? Theme.accent : Theme.glassFillStrong)
                    )
                Text("Search with your face")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.text)
                Keycap("⌘F")
            }
            .padding(.leading, 4)
            .padding(.trailing, 5)
            .frame(height: Theme.islandButtonHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(IslandButtonStyle())
        .help(on ? "Stop searching with your face (⌘F)" : "Search with your face (⌘F)")
        .accessibilityLabel(on ? "Face search on" : "Search with your face")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Menus

    @ViewBuilder
    private var menuLayer: some View {
        if let menu = model.menu {
            ZStack(alignment: menu == .sources ? .topTrailing : .bottomTrailing) {
                // A click anywhere else closes the menu.
                Color.black.opacity(0.001)
                    .onTapGesture { model.closeMenu() }
                    .accessibilityHidden(true)
                MenuPanel(model: model, menu: menu, focus: $focus, menuField: .menu)
                    .padding(.trailing, Theme.gridPadding)
                    .padding(.top, menu == .sources ? 52 : 0)
                    .padding(.bottom, menu == .actions ? Theme.bottomBarHeight + 6 : 0)
            }
        }
    }

    // MARK: Drop

    /// Files and images dropped on the panel become an image query (never saved silently).
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        // A tile dragged out and let go over the panel isn't a search for itself.
        guard !model.isDraggingTile else { return false }
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
                .fill(Theme.glassFill)
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

// MARK: - Menus

/// A menu over the panel: the source menu (under the source button) or the actions for the selected result (over the
/// Actions button). A filter field types into it; ↑ ↓ move, ↵ runs, Esc closes (the panel controller routes the keys).
private struct MenuPanel<Field: Hashable>: View {
    @ObservedObject var model: AppModel
    let menu: PanelMenu
    var focus: FocusState<Field?>.Binding
    let menuField: Field

    var body: some View {
        let rows = model.menuRows
        VStack(alignment: .leading, spacing: 0) {
            if menu == .sources {
                filterField(placeholder: "Filter sources…")
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.bottom, 6)
            } else if let title = model.focusedPick?.title, !title.isEmpty {
                Text(verbatim: title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.mutedText)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .frame(height: 32, alignment: .leading)
            }
            // Many groups make ⌘K taller than the panel: the rows scroll, and follow the highlighted one.
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: rowsHeight(rows) > maxRowsHeight) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if row.startsGroup {
                                Rectangle().fill(Theme.hairline).frame(height: 1)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                            }
                            if let heading = row.heading {
                                Text(verbatim: heading)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(Theme.mutedText)
                                    .padding(.horizontal, 14)
                                    .frame(height: 22, alignment: .bottomLeading)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            rowView(row, index: index, selected: index == model.menuSelection)
                                .id(row.id)
                        }
                    }
                }
                .frame(height: min(rowsHeight(rows), maxRowsHeight))
                .onChange(of: model.menuSelection) { _, selected in
                    guard selected >= 0, selected < rows.count else { return }
                    proxy.scrollTo(rows[selected].id)
                }
            }
            if rows.isEmpty {
                Text("No matches")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.mutedText)
                    .padding(.horizontal, 14)
                    .frame(height: 30, alignment: .leading)
            }
            if menu == .actions {
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.top, 6)
                filterField(placeholder: "Search for actions…")
            } else {
                Color.clear.frame(height: 6)
            }
        }
        .frame(width: menu == .sources ? 252 : 312, alignment: .leading)
        .glass(cornerRadius: 12, tint: Theme.menuTint, edge: Color.white.opacity(0.16))
        .shadow(color: .black.opacity(0.4), radius: 22, x: 0, y: 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(menu == .sources ? "Sources" : "Actions")
    }

    private var rowHeight: CGFloat { menu == .sources ? 30 : 32 }

    /// The rows' own height: each row, a line (9 pt) before each group, a heading (22 pt) where one is.
    private func rowsHeight(_ rows: [MenuRow]) -> CGFloat {
        let lines = rows.filter(\.startsGroup).count
        let headings = rows.filter { $0.heading != nil }.count
        return CGFloat(rows.count) * rowHeight + CGFloat(lines) * 9 + CGFloat(headings) * 22
    }

    /// What fits over the grid with the menu's title and filter field: past this the rows scroll.
    private var maxRowsHeight: CGFloat {
        Theme.contentHeight - 64
    }

    private func filterField(placeholder: String) -> some View {
        ZStack(alignment: .leading) {
            if model.menuQuery.isEmpty {
                Text(verbatim: placeholder)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.placeholderText)
                    .allowsHitTesting(false)
            }
            TextField("", text: $model.menuQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(Theme.text)
                .focused(focus, equals: menuField)
                .accessibilityLabel(Text(verbatim: placeholder))
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    private func rowView(_ row: MenuRow, index: Int, selected: Bool) -> some View {
        Button {
            model.performMenuRow(at: index)
        } label: {
            HStack(spacing: 10) {
                if menu == .sources {
                    SourceGlyph(symbol: row.symbol, letter: row.letter, size: 18)
                } else if let symbol = row.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(Theme.softTitle)
                        .frame(width: 18)
                }
                Text(verbatim: row.title)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if row.isChecked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.accent)
                }
                if !row.keys.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(Array(row.keys.enumerated()), id: \.offset) { _, key in
                            Keycap(key)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: menu == .sources ? 30 : 32)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Theme.glassFillStrong : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { inside in
            if inside { model.hoverMenuRow(index) }
        }
        .accessibilityAddTraits(row.isChecked ? .isSelected : [])
    }
}

/// A source's glyph: an SF Symbol on a small square, or a letter (GIPHY's).
struct SourceGlyph: View {
    let symbol: String?
    let letter: String?
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let letter {
                Text(verbatim: letter)
                    .font(.system(size: size * 0.55, weight: .heavy))
                    .foregroundColor(Theme.text)
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Color.black))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            } else {
                Image(systemName: symbol ?? "square.grid.2x2")
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Theme.glassFillStrong))
            }
        }
        .accessibilityHidden(true)
    }
}

/// One key of a shortcut: "⌘", "K", "↩".
struct Keycap: View {
    let key: String
    /// Filled in the signal color: the key of the main action (↩ beside Copy).
    let filled: Bool

    init(_ key: String, filled: Bool = false) {
        self.key = key
        self.filled = filled
    }

    var body: some View {
        Text(verbatim: key)
            .font(.system(size: 11, weight: filled ? .semibold : .medium))
            .foregroundColor(filled ? Theme.onAccent : Theme.softTitle)
            .frame(minWidth: 20, minHeight: 20)
            .padding(.horizontal, key.count > 1 ? 4 : 0)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(filled ? Theme.accent : Theme.keyFill))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(filled ? Color.clear : Theme.glassEdge, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

// MARK: - Islands

/// A floating island along the panel's bottom edge: smoked glass of its own over the results (near-black at 60 % over
/// the blur, a white 10 % edge, a deep shadow, radius 12), readable over any GIF; tinted and edged in the signal color
/// while what it holds is on.
private struct IslandModifier: ViewModifier {
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .padding(3)
            .glass(cornerRadius: 12,
                   tint: highlighted ? Theme.islandOnTint : Theme.islandTint,
                   edge: highlighted ? Theme.accent.opacity(0.6) : Theme.islandEdge,
                   shadow: false, highlight: false)
            .shadow(color: .black.opacity(0.45), radius: 15, x: 0, y: 10)
    }
}

extension View {
    fileprivate func island(highlighted: Bool = false) -> some View {
        modifier(IslandModifier(highlighted: highlighted))
    }
}

/// A button inside an island: lit while pointed at or pressed.
private struct IslandButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        IslandButtonBody(configuration: configuration, selected: selected)
    }

    private struct IslandButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(fill)
                )
                .onHover { isHovered = $0 }
        }

        private var fill: Color {
            if configuration.isPressed { return Color.white.opacity(0.14) }
            if selected || isHovered { return Color.white.opacity(0.08) }
            return .clear
        }
    }
}

/// The left island's ✂ while face search is on: "Clip me". Tap for a still sticker of your reaction, hold for a moving
/// one (the label counts the seconds while it records).
private struct ClipButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var capture: CaptureModel
    @State private var pressed = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isRecording ? "record.circle" : "scissors")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isRecording ? Theme.accent : Theme.text)
            // A fixed width: "Clip me", "1.4 s" and "Cutting…" don't move the island.
            Text(label)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundColor(Theme.text)
                .frame(width: 58, alignment: .leading)
            Keycap("⌥S")
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .frame(height: Theme.islandButtonHeight)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(pressed ? Color.white.opacity(0.14) : Color.clear)
        )
        .opacity(model.canClip || capture.isBusy ? 1 : 0.5)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    model.clipPress(from: .mouse)
                }
                .onEnded { _ in
                    pressed = false
                    model.clipRelease(from: .mouse)
                }
        )
        .help("Clip me: tap for a sticker of your reaction, hold for a moving one. Saved to My Stickers and copied.")
        .accessibilityLabel("Clip me")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.clipTap() }
    }

    private var isRecording: Bool {
        if case .recording = capture.phase { return true }
        return false
    }

    private var label: String {
        if case let .recording(progress) = capture.phase {
            return String(format: "%.1f s", progress * CaptureRenderer.maximumClipDuration)
        }
        if model.isCutting || capture.phase == .saving { return "Cutting…" }
        return "Clip me"
    }
}

/// Over the islands after Clip me: the sticker, saved to My Stickers and copied, with Rename and Undo; under it, your
/// latest used groups as chips and New group: one click files the sticker (another takes it out).
private struct ClipNoticeView: View {
    @ObservedObject var model: AppModel
    let notice: ClipNotice

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summary
            groupChips
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .frame(maxWidth: 460)
        .island()
        .padding(.horizontal, Theme.gridPadding)
        .task(id: notice) { @MainActor in
            // Goes on its own 8 s after the last change (filing it in a group counts).
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled, model.clipNotice == notice { model.dismissClipNotice() }
        }
    }

    private var groupChips: some View {
        // They wrap inside the notice: long names and groups made from it never push past its edge.
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(model.noticeGroups) { group in
                let isIn = notice.groupIDs.contains(group.id)
                Button {
                    model.toggleNoticeGroup(group.id)
                } label: {
                    GroupChipLabel(title: group.name, isOn: isIn, ticks: true, compact: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: isIn ? "In \(group.name)" : "Add to \(group.name)"))
                .accessibilityAddTraits(isIn ? .isSelected : [])
            }
            Button {
                model.newGroupFromNotice()
            } label: {
                NewGroupChipLabel(title: "New group", compact: true)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 38)
    }

    private var summary: some View {
        HStack(spacing: 10) {
            AsyncThumbnail(url: notice.thumbnail)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: notice.isNew ? "Saved “\(notice.name)” to My Stickers" : "Already one of your stickers")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                Text(verbatim: notice.copied ? "and copied: ⌘V in the chat to send it" : "Copy it with ↩")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.softTitle)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            noticeButton("Rename") { model.renameClippedSticker() }
            if notice.isNew {
                noticeButton("Undo") { model.undoClippedSticker() }
            }
            Button {
                model.dismissClipNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.softTitle)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(IslandButtonStyle())
            .accessibilityLabel("Dismiss")
        }
        .frame(height: 28)
    }
}

private extension ClipNoticeView {
    func noticeButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.text)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(IslandButtonStyle())
    }
}

/// A small picture from a file (the sticker just made).
private struct AsyncThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .task(id: url) {
            image = NSImage(contentsOf: url)
        }
    }
}
