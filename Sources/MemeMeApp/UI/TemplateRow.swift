import AppKit
import MemeMeCore
import SwiftUI

/// The classic memes row: five famous static meme templates (Distracted Boyfriend, Surprised Pikachu…) from Imgflip's
/// list, picked on the Mac for your face's mood or the words you type.
struct TemplateRow: View {
    @ObservedObject var model: AppModel

    private let spacing: CGFloat = 8

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                (Text("Classic memes").foregroundColor(Theme.softText)
                    + Text(" · Imgflip").foregroundColor(Theme.mutedText))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .accessibilityLabel("Classic memes from Imgflip")
                Spacer(minLength: 0)
                if let query = model.templateQuery, query != .mood(.reaction) {
                    Text(verbatim: query.label)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.mutedText)
                        .lineLimit(1)
                        .accessibilityLabel(Text(verbatim: "Classic memes for \(query.label)"))
                }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                ForEach(Array(model.templateResults.prefix(Theme.columns).enumerated()), id: \.element.id) { offset, template in
                    let slot = model.templateSlot(offset)
                    TemplateTile(template: template, isFocused: model.focusedIndex == slot, model: model)
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
                        .accessibilityAction {
                            model.commit(index: slot)
                        }
                }
                ForEach(0..<max(0, Theme.columns - model.templateResults.count), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.surface.opacity(model.isTemplatesLoading ? 0.8 : 0.45))
                        .aspectRatio(1, contentMode: .fit)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if model.templateResults.isEmpty, let message = emptyMessage {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.mutedText)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: Theme.columns)
    }

    private var emptyMessage: String? {
        if model.isTemplatesLoading { return nil }
        if model.templatesUnavailable { return "Imgflip isn’t answering right now." }
        if case let .words(text)? = model.templateQuery {
            return "No classic memes for “\(text)”."
        }
        return nil
    }
}

/// One template, whole (letterboxed on the tile), so a four-panel meme still reads as one.
private struct TemplateTile: View {
    let template: MemeTemplate
    let isFocused: Bool
    @ObservedObject var model: AppModel

    @State private var image: NSImage? = nil

    private let cornerRadius: CGFloat = 10

    init(template: MemeTemplate, isFocused: Bool, model: AppModel) {
        self.template = template
        self.isFocused = isFocused
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        let shown = image ?? model.templates.cachedImage(for: template)

        Theme.surface
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let shown {
                    Image(nsImage: shown)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: cornerRadius + 3, style: .continuous)
                        .stroke(Theme.accent, lineWidth: 2)
                        .padding(-3)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .help(template.name)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(template.name), classic meme from Imgflip. Copy and go back to the chat.")
            .accessibilityAddTraits(.isButton)
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
