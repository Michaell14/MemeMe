import AppKit
import SwiftUI

/// A short-lived pill at the top center of the main screen ("Copied … · ⌘V — not sent", "Copying…").
@MainActor
final class HUDController {
    static let shared = HUDController()

    /// How long a message stays fully visible.
    private let displayDuration: TimeInterval = 1.6
    private let fadeDuration: TimeInterval = 0.25
    /// Transparent margin around the pill so its SwiftUI shadow isn't clipped by the window.
    private let shadowMargin: CGFloat = 14
    /// Distance between the pill and the menu bar.
    private let topGap: CGFloat = 8

    private var panel: NSPanel?
    private var hostingView: NSHostingView<HUDPill>?
    /// Incremented on every `show`, so a pending fade-out of an older message is ignored.
    private var generation = 0

    private init() {}

    /// Pill at the top center of the main screen for 1.6 s (or until replaced). Optional 28 px thumbnail.
    func show(_ message: String, thumbnail: URL? = nil) {
        generation += 1
        let current = generation

        let pill = HUDPill(message: message, thumbnail: thumbnail, margin: shadowMargin)
        let (window, host) = ensureWindow(rootView: pill)
        host.rootView = pill
        host.layoutSubtreeIfNeeded()

        let fitting = host.fittingSize
        let size = NSSize(width: max(fitting.width, 120), height: max(fitting.height, 40))
        window.setFrame(frame(for: size), display: true)
        // A zero-length animation replaces a fade-out that may still be running.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            window.animator().alphaValue = 1
        }
        window.alphaValue = 1
        window.orderFrontRegardless()

        let visibleNanoseconds = UInt64(displayDuration * 1_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: visibleNanoseconds)
            self?.fadeOut(generation: current)
        }
    }

    // MARK: Private

    private func ensureWindow(rootView: HUDPill) -> (NSPanel, NSHostingView<HUDPill>) {
        if let existingPanel = self.panel, let existingHost = self.hostingView {
            return (existingPanel, existingHost)
        }
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        newPanel.isFloatingPanel = true
        newPanel.level = .statusBar
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        newPanel.ignoresMouseEvents = true
        newPanel.hidesOnDeactivate = false
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.sharingType = .none
        newPanel.isReleasedWhenClosed = false
        newPanel.animationBehavior = .none

        let newHost = NSHostingView(rootView: rootView)
        newHost.sizingOptions = [.intrinsicContentSize]
        newHost.frame = NSRect(x: 0, y: 0, width: 320, height: 60)
        newHost.autoresizingMask = [.width, .height]
        newPanel.contentView = newHost

        self.panel = newPanel
        self.hostingView = newHost
        return (newPanel, newHost)
    }

    /// Top center of the main screen, just under the menu bar.
    private func frame(for size: NSSize) -> NSRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return NSRect(origin: .zero, size: size)
        }
        let visible = screen.visibleFrame
        let x = (screen.frame.midX - size.width / 2).rounded()
        // The margin is transparent, so the visible pill sits `topGap` below the menu bar.
        // With the menu bar hidden, stay below the camera housing (safe area is 0 without a notch).
        let usableTop = min(visible.maxY, screen.frame.maxY - screen.safeAreaInsets.top)
        let top = usableTop - topGap + shadowMargin
        return NSRect(x: x, y: (top - size.height).rounded(), width: size.width, height: size.height)
    }

    private func fadeOut(generation expected: Int) {
        guard expected == generation, let panel, panel.isVisible else { return }
        let duration = fadeDuration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = 0
        }
        let fadeNanoseconds = UInt64((duration + 0.05) * 1_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: fadeNanoseconds)
            self?.finishFade(generation: expected)
        }
    }

    private func finishFade(generation expected: Int) {
        guard expected == generation, let panel else { return }
        panel.orderOut(nil)
        panel.alphaValue = 1
    }
}

/// The HUD's content: optional thumbnail and one line of text on a dark pill.
private struct HUDPill: View {
    let message: String
    let thumbnail: URL?
    let margin: CGFloat

    @State var image: NSImage? = nil

    var body: some View {
        HStack(spacing: 10) {
            if thumbnail != nil {
                thumbnailView
            }
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 440, alignment: .leading)
        }
        .padding(.vertical, thumbnail == nil ? 9 : 7)
        .padding(.leading, thumbnail == nil ? 14 : 8)
        .padding(.trailing, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.hudBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
        .padding(margin)
        .fixedSize()
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
        .task(id: thumbnail) { @MainActor in
            guard let url = thumbnail else {
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

    private var thumbnailView: some View {
        ZStack {
            Theme.surface
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
