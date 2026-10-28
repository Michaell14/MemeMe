import AppKit
import MemeMeCore
import SwiftUI

/// Popover under the menu-bar icon after a drop: made stickers (with Undo) or kept memes.
struct StickerPopoverView: View {
    @ObservedObject var model: StickerPopoverModel

    private let contentWidth: CGFloat = 368

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let batch = model.stickerBatch {
                stickerContent(batch)
            } else if let kept = model.keptBatch {
                keptContent(kept)
            }
        }
        .frame(width: contentWidth, alignment: .topLeading)
        .padding(16)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.background)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Stickers

    @ViewBuilder
    private func stickerContent(_ batch: StickerBatch) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: headline(for: batch))
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            if batch.undone {
                Button("Done") {
                    model.close()
                }
                .buttonStyle(PanelLinkButtonStyle(fontSize: 13))
            } else {
                Button("Undo all") {
                    model.undoAll()
                }
                .buttonStyle(PanelLinkButtonStyle(fontSize: 13))
            }
        }

        if model.askGrouping && !batch.undone {
            groupingQuestion
        }

        if !batch.undone && !batch.stickers.isEmpty {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(StickerCell.size), spacing: 10, alignment: .top), count: 4),
                alignment: .leading,
                spacing: 14
            ) {
                ForEach(batch.stickers) { sticker in
                    StickerCell(
                        sticker: sticker,
                        onToggle: {
                            model.toggle(stickerID: sticker.id)
                        },
                        onConfirm: { personID in
                            model.confirm(stickerID: sticker.id, personID: personID)
                        }
                    )
                }
            }
            .padding(.top, 6)
        }

        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Theme.separator)
                .frame(height: 1)
                .padding(.bottom, 10)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: footnote(for: batch))
                    .font(.system(size: 12))
                    .foregroundColor(Theme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Keep as photo only") {
                    model.keepAsPhotoOnly()
                }
                .buttonStyle(PanelLinkButtonStyle(fontSize: 12))
            }
        }
    }

    private var groupingQuestion: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Group stickers by person?")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.text)
            Text("MemeMe matches faces only against stickers you made. Face data stays on this Mac.")
                .font(.system(size: 12))
                .foregroundColor(Theme.softText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Yes, group them") {
                    model.groupYes()
                }
                .buttonStyle(PanelFilledButtonStyle(fontSize: 12, cornerRadius: 7))
                Button("Not now") {
                    model.groupNo()
                }
                .buttonStyle(OutlinedButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
        )
    }

    private func headline(for batch: StickerBatch) -> String {
        if batch.undone {
            return "No stickers made"
        }
        let count = batch.stickers.filter { !$0.removed }.count
        return "Made \(count) sticker" + (count == 1 ? "" : "s")
    }

    private func footnote(for batch: StickerBatch) -> String {
        if batch.undone {
            return "All stickers from this photo were removed."
        }
        if batch.skippedFaces > 0 {
            let faces = batch.skippedFaces == 1 ? "1 small face" : "\(batch.skippedFaces) small faces"
            return "Skipped \(faces) in the back. × drops a sticker, + adds it back."
        }
        return "× drops a sticker, + adds it back."
    }

    // MARK: Kept memes

    private func keptContent(_ batch: IndexBatch) -> some View {
        HStack(spacing: 8) {
            keptSummary(batch)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button("Undo") {
                model.undoKept()
            }
            .buttonStyle(PanelLinkButtonStyle(fontSize: 13))
        }
    }

    /// "Kept 23 · 4 duplicates merged"
    private func keptSummary(_ batch: IndexBatch) -> Text {
        var summary = Text(verbatim: "Kept \(batch.addedIDs.count.formatted())")
            .fontWeight(.semibold)
            .foregroundColor(Theme.text)
        if batch.duplicates > 0 {
            let merged = batch.duplicates == 1
                ? " · 1 duplicate merged"
                : " · \(batch.duplicates.formatted()) duplicates merged"
            summary = summary + Text(verbatim: merged).foregroundColor(Theme.mutedText)
        }
        if batch.skipped > 0 {
            summary = summary + Text(verbatim: " · \(batch.skipped.formatted()) skipped").foregroundColor(Theme.mutedText)
        }
        return summary
    }
}

// MARK: - Sticker cell

/// One die-cut sticker on a checkerboard, with its name label and × / + toggle.
private struct StickerCell: View {
    static let size: CGFloat = 84

    let sticker: MadeSticker
    let onToggle: () -> Void
    let onConfirm: (UUID) -> Void

    @State var image: NSImage? = nil

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Checkerboard()
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(4)
                    }
                }
                .frame(width: Self.size, height: Self.size)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(sticker.removed ? 0.35 : 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(imageDescription)

                Button(action: onToggle) {
                    Text(sticker.removed ? "+" : "×")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.text)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Theme.border))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityLabel(sticker.removed ? "Add this sticker back" : "Remove this sticker")
            }
            nameLabel
        }
        .frame(width: Self.size)
        .task(id: sticker.fileURL) { @MainActor in
            let url = sticker.fileURL
            if let cached = ThumbnailCache.shared.cached(url) {
                image = cached
                return
            }
            let loaded = await ThumbnailCache.shared.thumbnail(for: url, maxPixel: 256)
            if !Task.isCancelled, let loaded {
                image = loaded
            }
        }
    }

    /// "Maya ✓" (confident), "Jordan?" + confirm (likely), or "New face".
    @ViewBuilder
    private var nameLabel: some View {
        switch sticker.match {
        case .confident:
            labelText("\(sticker.personName ?? "Friend") ✓")
        case .likely(let personID, _):
            VStack(spacing: 4) {
                labelText("\(sticker.personName ?? "Friend")?")
                if !sticker.removed {
                    Button {
                        onConfirm(personID)
                    } label: {
                        Text(verbatim: "Yes, that’s \(sticker.personName ?? "them")")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.text)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Theme.chipBorder, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: Self.size)
                }
            }
        case .newFace:
            labelText("New face")
        }
    }

    private func labelText(_ string: String) -> some View {
        Text(verbatim: string)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Theme.text)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: Self.size)
    }

    private var imageDescription: String {
        switch sticker.match {
        case .confident:
            if let name = sticker.personName {
                return "Sticker of \(name)"
            }
            return "Sticker of a friend"
        case .likely:
            if let name = sticker.personName {
                return "Sticker, possibly \(name)"
            }
            return "Sticker of a friend"
        case .newFace:
            return "Sticker of an unnamed face"
        }
    }
}

/// Transparency checkerboard behind die-cut stickers.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 6
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.checkerDark))
            var squares = Path()
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : cell
                while x < size.width {
                    squares.addRect(CGRect(x: x, y: y, width: cell, height: cell))
                    x += cell * 2
                }
                y += cell
                row += 1
            }
            context.fill(squares, with: .color(Theme.checkerLight))
        }
        .accessibilityHidden(true)
    }
}

/// Outlined secondary button ("Not now").
private struct OutlinedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundColor(Theme.text)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? Theme.surface : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.chipBorder, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .fixedSize()
    }
}
