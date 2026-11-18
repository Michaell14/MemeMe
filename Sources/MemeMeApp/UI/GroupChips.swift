import AppKit
import MemeMeCore
import SwiftUI

/// A group as a chip: its name (and count), lit while it shows or the sticker is in it. Over My Stickers, on the Clip
/// me notice and on the screen cut's card.
struct GroupChipLabel: View {
    let title: String
    var count: Int? = nil
    let isOn: Bool
    /// A tick before the name while on (filing a sticker; My Stickers' chips don't tick).
    var ticks = false
    /// The notice's and the card's smaller chips.
    var compact = false
    /// A saved search that fills itself: sparkles before the name.
    var live = false

    var body: some View {
        HStack(spacing: 5) {
            if live {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.accent)
            }
            if ticks && isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
            }
            Text(verbatim: shortTitle)
                .font(.system(size: compact ? 12 : 13, weight: isOn ? .semibold : .medium))
                .lineLimit(1)
            if let count {
                Text(verbatim: "\(count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isOn ? Theme.softTitle : Theme.mutedText)
            }
        }
        .foregroundColor(isOn ? Color.white : Theme.softTitle)
        .fixedSize()
        .padding(.horizontal, compact ? 10 : 12)
        .frame(height: compact ? 26 : 30)
        .background(Capsule().fill(isOn ? Color.white.opacity(0.16) : Theme.tileBackground))
        .overlay(Capsule().strokeBorder(isOn ? Color.white.opacity(0.32) : Theme.tileEdge, lineWidth: 1))
        .contentShape(Capsule())
        .help(Text(verbatim: title))
    }

    /// A long name is cut, so one chip never crowds out the others.
    private var shortTitle: String {
        let limit = compact ? 18 : 24
        guard title.count > limit else { return title }
        return String(title.prefix(limit - 1)) + "…"
    }
}

/// + as a dashed chip: makes a group ("New group" beside it where there is room).
struct NewGroupChipLabel: View {
    var title: String? = nil
    var compact = false

    var body: some View {
        let height: CGFloat = compact ? 26 : 30
        HStack(spacing: 4) {
            Image(systemName: "plus")
                .font(.system(size: compact ? 9 : 10, weight: .bold))
            if let title {
                Text(verbatim: title)
                    .font(.system(size: compact ? 12 : 13, weight: .medium))
                    .lineLimit(1)
            }
        }
        .foregroundColor(Theme.softTitle)
        .padding(.horizontal, title == nil ? 0 : (compact ? 10 : 12))
        .frame(minWidth: height, minHeight: height, maxHeight: height)
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.30), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .contentShape(Capsule())
    }
}

/// Over My Stickers' grid: All, each group, Ungrouped, +. Right-click a group for Rename… and Delete Group.
struct StickerGroupBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.groupChips) { chip in
                    chipButton(chip)
                }
                Button {
                    model.newGroup()
                } label: {
                    NewGroupChipLabel(title: model.stickerGroups.isEmpty ? "New Group" : nil)
                }
                .buttonStyle(.plain)
                .help("New Group")
                .accessibilityLabel("New Group")
            }
            .padding(.horizontal, Theme.gridPadding)
            .padding(.vertical, 3)
        }
        .frame(height: 36)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sticker groups")
    }

    @ViewBuilder
    private func chipButton(_ chip: GroupChip) -> some View {
        let selected = model.groupFilter == chip.filter
        let button = Button {
            model.selectGroupFilter(chip.filter)
        } label: {
            GroupChipLabel(title: chip.title, count: chip.count, isOn: selected, live: chip.isLive)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        if let id = chip.groupID {
            button
                .help(Text(verbatim: chip.isLive ? "Fills itself with the stickers its words match" : chip.title))
                .contextMenu {
                    Button("Rename…") { model.renameGroup(id) }
                    Divider()
                    Button("Delete Group", role: .destructive) { model.deleteGroup(id) }
                }
        } else {
            button
        }
    }
}

/// Over My Stickers' All: up to three groups MemeMe offers to make, each with a few of its stickers, why it is offered,
/// Make Group and Not Now.
struct GroupSuggestionsRow: View {
    @ObservedObject var model: AppModel
    let suggestions: [GroupSuggestion]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.accent)
                Text("Suggested groups")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.softTitle)
                Text("from what MemeMe already read in them")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.mutedText)
            }
            .frame(height: 20)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: Theme.gridSpacing) {
                ForEach(suggestions) { suggestion in
                    card(suggestion)
                }
            }
        }
    }

    private func card(_ suggestion: GroupSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    ForEach(Array(previews(of: suggestion).enumerated()), id: \.element.id) { index, item in
                        SuggestionThumbnail(url: item.fileURL)
                            .frame(width: 42, height: 42)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.raised2))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.glassEdge, lineWidth: 1))
                            .rotationEffect(.degrees(Double(index - 1) * 8))
                            .offset(x: CGFloat(index) * 14)
                            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    }
                }
                .frame(width: 72, height: 48, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: suggestion.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                    Text(verbatim: suggestion.reason)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.softTitle)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Button {
                    model.acceptSuggestion(suggestion)
                } label: {
                    Text("Make Group")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.glassFillStrong))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    model.dismissSuggestion(suggestion)
                } label: {
                    Text("Not Now")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.softTitle)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous).fill(Theme.tileBackground))
        .overlay(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous).strokeBorder(Theme.tileEdge, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "Suggested group \(suggestion.name): \(suggestion.reason)"))
    }

    /// Three of its stickers, the newest first.
    private func previews(of suggestion: GroupSuggestion) -> [LibraryItem] {
        suggestion.stickerIDs.prefix(3).compactMap { model.store.item(id: $0) }
    }
}

/// A sticker's picture, small.
private struct SuggestionThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
            }
        }
        .task(id: url) {
            image = NSImage(contentsOf: url)
        }
    }
}

/// Lays its views out in lines, left to right, wrapping when the next one doesn't fit (the card's group chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(subviews, width: proposal.width ?? .infinity)
        let width = frames.map(\.maxX).max() ?? 0
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(subviews, width: bounds.width)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}
