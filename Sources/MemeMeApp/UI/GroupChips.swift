import MemeMeCore
import SwiftUI

/// One sticker group as a capsule: its name, maybe how many stickers it has, and a check in the signal color when the
/// sticker in hand is in it. `filled`: the chip showing (My Stickers' filter); `dashed`: "New group".
struct GroupChip: View {
    let title: String
    var count: Int?
    var checked = false
    var filled = false
    var dashed = false
    var symbol: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Theme.accent)
                }
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.softTitle)
                }
                if !title.isEmpty {
                    Text(verbatim: title)
                        .font(.system(size: 12, weight: checked || filled ? .semibold : .medium))
                        .foregroundColor(filled ? Theme.ground : (dashed ? Theme.softTitle : Theme.text))
                        .lineLimit(1)
                }
                if let count {
                    Text(verbatim: "\(count)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(filled ? Theme.line : Theme.mutedText)
                }
            }
            .padding(.horizontal, title.isEmpty ? 0 : 10)
            .frame(minWidth: 26)
            .frame(height: 26)
            .background(
                Capsule(style: .continuous)
                    .fill(filled ? Theme.text : (checked ? Color.white.opacity(0.18) : (dashed ? Color.clear : Theme.glassFill)))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(checked ? Color.white.opacity(0.55) : Theme.glassEdge,
                                  style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : []))
                    .opacity(filled ? 0 : 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// My Stickers' chips, over the grid's title: All, each group, Ungrouped, and + to make one. A group's chip has Rename…
/// and Delete Group on a right-click.
struct GroupFilterBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All", filter: .all)
                ForEach(model.stickerGroups) { group in
                    chip(group.name, filter: .group(group.id))
                        .contextMenu {
                            Button("Rename…") { model.promptToRenameGroup(group.id) }
                            Button("Delete Group") { model.deleteGroup(group.id) }
                        }
                        .help("Right-click to rename or delete")
                }
                if model.stickerGroups.isEmpty {
                    GroupChip(title: "New group", dashed: true, symbol: "plus") {
                        model.promptForNewGroup(adding: nil)
                    }
                    .help("Make a group, then add stickers with ⌘K or right after Clip me")
                } else {
                    chip("Ungrouped", filter: .ungrouped)
                    GroupChip(title: "", symbol: "plus") {
                        model.promptForNewGroup(adding: nil)
                    }
                    .help("New group")
                    .accessibilityLabel("New group")
                }
            }
            .padding(.horizontal, Theme.gridPadding)
        }
        .frame(height: 30)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Groups")
    }

    private func chip(_ title: String, filter: StickerGroupFilter) -> some View {
        let selected = model.groupFilter == filter
        return GroupChip(title: title, count: model.stickerCount(for: filter), filled: selected) {
            model.selectGroupFilter(filter)
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
