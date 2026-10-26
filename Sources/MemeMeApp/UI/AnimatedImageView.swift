import AppKit
import SwiftUI

/// Plays an animated GIF (or shows a still) from a local file. Display-only: clicks, hover and drags
/// go to the SwiftUI tile underneath.
struct AnimatedImageView: NSViewRepresentable {
    let url: URL

    /// An image view that never takes mouse events. An enabled NSImageView would otherwise track the click
    /// itself, and the tile's tap-to-copy and drag-into-chat gestures would never fire.
    final class PassthroughImageView: NSImageView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }

    final class Coordinator {
        var loadedURL: URL?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PassthroughImageView {
        let view = PassthroughImageView(frame: .zero)
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageFrameStyle = .none
        view.isEditable = false
        view.refusesFirstResponder = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        load(into: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: PassthroughImageView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        load(into: nsView, coordinator: context.coordinator)
    }

    /// Fills whatever space SwiftUI offers instead of reporting the image's pixel size.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PassthroughImageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 88, height: 88))
    }

    private func load(into view: NSImageView, coordinator: Coordinator) {
        coordinator.loadedURL = url
        view.image = NSImage(contentsOf: url)
        view.animates = true
    }
}
