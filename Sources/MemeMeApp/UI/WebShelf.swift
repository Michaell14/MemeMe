import MemeMeCore
import SwiftUI

/// The shelf under your memes: one row of web results, GIPHY's GIFs or the classic memes. Two pills switch it, and so
/// do the arrow keys (it shows the row the focus is in); its header carries the attribution of the row on show
/// ("Powered by GIPHY", "from Imgflip"). Without a GIPHY key only the classic memes show, under their own name.
struct WebShelf: View {
    @ObservedObject var model: AppModel

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        if model.showsGiphyRow || model.showsTemplateRow {
            VStack(alignment: .leading, spacing: 6) {
                header
                switch model.visibleShelf {
                case .gifs:
                    GiphyRow(model: model)
                        .transition(.opacity)
                case .classic:
                    TemplateRow(model: model)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: model.visibleShelf)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 4) {
            if model.showsGiphyRow && model.showsTemplateRow {
                ShelfPill(title: "GIFs", isSelected: model.visibleShelf == .gifs) {
                    model.showShelf(.gifs)
                }
                ShelfPill(title: "Classic memes", isSelected: model.visibleShelf == .classic) {
                    model.showShelf(.classic)
                }
            } else {
                Text("Classic memes")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.softText)
            }
            Spacer(minLength: 0)
            switch model.visibleShelf {
            case .gifs:
                PoweredByGiphyMark()
            case .classic:
                Text("from Imgflip")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.mutedText)
            }
        }
        .frame(height: 20)
    }
}

/// "GIFs" or "Classic memes": filled when its row is on the shelf.
private struct ShelfPill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    init(title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isSelected ? Theme.text : (isHovered ? Theme.softText : Theme.mutedText))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background(Capsule().fill(isSelected ? Theme.surface : Color.clear))
                .overlay(Capsule().strokeBorder(isSelected ? Theme.chipBorder : Color.clear, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
