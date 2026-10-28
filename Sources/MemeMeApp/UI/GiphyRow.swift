import AppKit
import MemeMeCore
import SwiftUI

/// GIPHY's results for the face's mood, below the user's memes and apart from them: one row, in GIPHY's
/// own order, under "Powered by" and GIPHY's logo.
struct GiphyRow: View {
    @ObservedObject var model: AppModel

    private let spacing: CGFloat = 8

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                PoweredByGiphyMark()
                Spacer(minLength: 0)
                if let mood = model.giphyMood {
                    Text(verbatim: mood.label)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.mutedText)
                        .lineLimit(1)
                        .accessibilityLabel(Text(verbatim: "GIPHY results for \(mood.label)"))
                }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                ForEach(Array(model.giphyResults.prefix(Theme.columns).enumerated()), id: \.element.id) { offset, gif in
                    let slot = model.giphySlot(offset)
                    GiphyTile(gif: gif, isFocused: model.focusedIndex == slot, model: model)
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
                ForEach(0..<max(0, Theme.columns - model.giphyResults.count), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.surface.opacity(model.isGiphyLoading ? 0.8 : 0.45))
                        .aspectRatio(1, contentMode: .fit)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if model.giphyResults.isEmpty, let message = emptyMessage {
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
        if model.isGiphyLoading { return nil }
        if model.giphyUnavailable { return "GIPHY isn’t answering right now." }
        return model.giphyMood == nil ? "Make a face for GIFs from GIPHY." : "Nothing on GIPHY for this one."
    }
}

/// GIPHY's attribution: "Powered by" and GIPHY's logo from the app's resources (the word "GIPHY" if it's missing).
private struct PoweredByGiphyMark: View {
    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            Text("Powered by")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.softText)
            if let logo = PoweredByGiphyMark.logo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 13)
            } else {
                Text(verbatim: "GIPHY")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.text)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Powered by GIPHY")
    }

    /// Resources/GIPHY/GIPHYLogo.png: GIPHY's logo, white lettering on transparent for the dark panel, copied into the
    /// app by scripts/build-app.sh.
    static let logo: NSImage? = Bundle.main.image(forResource: "GIPHYLogo")
}

/// One GIPHY result: its small still, playing its preview while focused.
private struct GiphyTile: View {
    let gif: WebGIF
    let isFocused: Bool
    @ObservedObject var model: AppModel

    @State private var still: NSImage? = nil
    @State private var animation: NSImage? = nil

    private let cornerRadius: CGFloat = 10

    init(gif: WebGIF, isFocused: Bool, model: AppModel) {
        self.gif = gif
        self.isFocused = isFocused
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        let image = still ?? model.web.cachedStill(for: gif)

        Theme.surface
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .overlay {
                if isFocused, let animation {
                    // Display-only, so the tile keeps its tap and drag gestures.
                    AnimatedImageView(image: animation)
                        .allowsHitTesting(false)
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isButton)
            .task(id: gif.stillURL) { @MainActor in
                if model.web.cachedStill(for: gif) == nil {
                    let loaded = await model.web.still(for: gif)
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
                let loaded = await model.web.preview(for: gif)
                if !Task.isCancelled {
                    animation = loaded
                }
            }
    }

    private var accessibilityText: String {
        let creator = gif.creator.map { " by \($0)" } ?? ""
        return "\(gif.title), GIF\(creator) from GIPHY. Copy and go back to the chat."
    }
}
