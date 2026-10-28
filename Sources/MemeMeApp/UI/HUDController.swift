import AppKit
import SwiftUI

/// A button on the HUD ("Save as sticker").
struct HUDAction {
    let title: String
    let perform: @MainActor () -> Void
}

/// A short-lived pill at the top center of the main screen ("Copied … · ⌘V — not sent", "Copying…").
@MainActor
final class HUDController {
    static let shared = HUDController()

    /// How long a message stays fully visible.
    private let displayDuration: TimeInterval = 1.6
    /// … with a button, and after the pointer leaves it.
    private let actionDisplayDuration: TimeInterval = 5
    private let afterHoverDuration: TimeInterval = 1.2
    private let fadeDuration: TimeInterval = 0.25
    /// Transparent margin around the pill so its SwiftUI shadow isn't clipped by the window.
    private let shadowMargin: CGFloat = 14
    /// Distance between the pill and the menu bar.
    private let topGap: CGFloat = 8

    private var panel: NSPanel?
    private var hostingView: HUDHostingView?
    /// Incremented on every `show`, so a pending fade-out of an older message is ignored.
    private var generation = 0
    /// The pointer is over a HUD with a button: it stays until the pointer leaves.
    private var isHovered = false

    private init() {}

    /// Pill at the top center of the main screen for 1.6 s (or until replaced). Optional 28 px thumbnail.
    /// With an `action` it shows a button, takes clicks (without taking focus from the frontmost app), stays 5 s
    /// and while the pointer is over it.
    func show(_ message: String, thumbnail: URL? = nil, action: HUDAction? = nil) {
        generation += 1
        let current = generation
        isHovered = false

        var pill = HUDPill(message: message, thumbnail: thumbnail, margin: shadowMargin, actionTitle: action?.title)
        pill.onAction = { [weak self] in
            self?.dismiss()
            action?.perform()
        }
        pill.onHover = { [weak self] hovering in
            self?.hoverChanged(hovering, generation: current)
        }
        let (window, host) = ensureWindow(rootView: pill)
        window.ignoresMouseEvents = action == nil
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

        scheduleFadeOut(after: action == nil ? displayDuration : actionDisplayDuration, generation: current)
    }

    /// Hides the current message now.
    func dismiss() {
        generation += 1
        isHovered = false
        fadeOut(generation: generation)
    }

    // MARK: Private

    private func scheduleFadeOut(after delay: TimeInterval, generation current: Int) {
        let visibleNanoseconds = UInt64(delay * 1_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: visibleNanoseconds)
            self?.fadeOut(generation: current)
        }
    }

    private func hoverChanged(_ hovering: Bool, generation current: Int) {
        guard current == generation else { return }
        isHovered = hovering
        if !hovering {
            scheduleFadeOut(after: afterHoverDuration, generation: current)
        }
    }

    private func ensureWindow(rootView: HUDPill) -> (NSPanel, HUDHostingView) {
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
        newPanel.isReleasedWhenClosed = false
        newPanel.animationBehavior = .none

        let newHost = HUDHostingView(rootView: rootView)
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
        guard expected == generation, !isHovered, let panel, panel.isVisible else { return }
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

/// Takes the first click, so the HUD's button works without MemeMe being active.
private final class HUDHostingView: NSHostingView<HUDPill> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// The HUD's content: optional thumbnail, one line of text and an optional button on a dark pill.
private struct HUDPill: View {
    let message: String
    let thumbnail: URL?
    let margin: CGFloat
    var actionTitle: String? = nil
    var onAction: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }

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
            if let actionTitle {
                Button(actionTitle, action: onAction)
                    .buttonStyle(PanelFilledButtonStyle(fontSize: 12, cornerRadius: 7))
            }
        }
        .onHover { hovering in
            onHover(hovering)
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
        .accessibilityElement(children: actionTitle == nil ? .ignore : .contain)
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
