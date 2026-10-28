import AppKit
import MemeMeCore
import SwiftUI
import UniformTypeIdentifiers

/// The compact strip: the mirror on the left, with the word it read (else the hint) under it; on the right the search
/// field, one row of your memes, and the shelf with one row of GIFs or classic memes; a footer below only while there
/// is something to act on.
struct PanelView: View {
    @ObservedObject var model: AppModel

    @FocusState private var searchFocused: Bool
    @State private var isDropTargeted = false

    private let cornerRadius: CGFloat = 14

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isCaptureOpen {
                CaptureView(model: model)
            } else {
                strip
            }
        }
        .padding(16)
        .frame(width: Theme.panelWidth, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(isDropTargeted ? Theme.accent : Theme.border, lineWidth: isDropTargeted ? 2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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

    // MARK: Search field

    /// Mirror + readout or hint, your memes and the shelf, footer.
    @ViewBuilder
    private var strip: some View {
        if model.showSetupCard {
            SetupCardView(model: model)
        }
        HStack(alignment: .top, spacing: 16) {
            if !model.showSetupCard {
                MirrorColumn(model: model)
            }
            VStack(alignment: .leading, spacing: 10) {
                if !model.showSetupCard {
                    searchField
                    if let naming = model.naming, !naming.candidates.isEmpty {
                        NamingRow(prompt: naming) { personID in
                            model.nameUnknownFace(personID: personID)
                        }
                    }
                }
                results
                    .opacity(model.showSetupCard ? 0.55 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        if model.footer != .hidden {
            FooterView(model: model)
        }
    }

    /// One row of your memes (none until you have some), then the shelf; a dashed "Drop to search" card over them
    /// while an image is dragged over the panel (the whole panel takes the drop).
    private var results: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.ownRows > 0 {
                ResultGrid(model: model)
            }
            WebShelf(model: model)
            if model.ownRows == 0 && !model.showsGiphyRow && !model.showsTemplateRow {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surface.opacity(0.45))
                    .frame(height: 88)
                    .overlay {
                        Text("Your memes will show here")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.mutedText)
                    }
            }
        }
        .overlay {
            if isDropTargeted {
                DropCard()
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.placeholderText)
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                if model.queryText.isEmpty {
                    Text("Type, or drop / ⌘V an image")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.placeholderText)
                        .lineLimit(1)
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
            if model.showsFaceToken {
                Button(model.faceTokenIsPose ? "+ your pose ×" : "+ your face ×") {
                    model.removeFaceToken()
                }
                .buttonStyle(PanelCapsuleButtonStyle(fontSize: 11, foreground: Theme.softText))
                .accessibilityLabel(model.faceTokenIsPose ? "Stop using your pose in this search" : "Stop using your face in this search")
            }
            KeycapRow(color: model.hotKeyAvailable ? Theme.mutedText : Theme.warning)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(model.queryText.isEmpty ? Theme.separator : Theme.accent, lineWidth: 1)
        )
    }

    // MARK: Drop

    /// Files and images dropped on the panel become an image query (never saved silently).
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !model.isCaptureOpen else { return false }
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
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            )
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 20))
                        .foregroundColor(Theme.accent)
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
