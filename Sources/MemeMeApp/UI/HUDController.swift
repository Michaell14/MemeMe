import AppKit
import SwiftUI

/// A button on the HUD ("Save as sticker").
struct HUDAction {
    let title: String
    let perform: @MainActor () -> Void
}

/// A short-lived notice hanging from the notch, in the drawer's shape: "✓ Copied · ⌘V to paste" in the ears beside
/// the notch, or a longer line just under it ("Copying…", "Saved “You — happy” as a sticker" with Undo).
@MainActor
final class HUDController {
    static let shared = HUDController()

    /// How long a message stays fully visible.
    private let displayDuration: TimeInterval = 1.6
    /// … with a button, and after the pointer leaves it.
    private let actionDisplayDuration: TimeInterval = 5
    private let afterHoverDuration: TimeInterval = 1.2
    private let fadeDuration: TimeInterval = 0.25
    /// Transparent margin beside and under the notice so its SwiftUI shadow isn't clipped by the window.
    private let shadowMargin: CGFloat = 14

    private var panel: NSPanel?
    private var hostingView: HUDHostingView?
    /// Incremented on every `show`, so a pending fade-out of an older message is ignored.
    private var generation = 0
    /// The pointer is over a HUD with a button: it stays until the pointer leaves.
    private var isHovered = false

    private init() {}

    /// A line hanging from the notch for 1.6 s (or until replaced). Optional 28 px thumbnail.
    /// With an `action` it shows a button, takes clicks (without taking focus from the frontmost app), stays 5 s
    /// and while the pointer is over it.
    func show(_ message: String, thumbnail: URL? = nil, action: HUDAction? = nil) {
        present(.message(message), thumbnail: thumbnail, action: action)
    }

    /// "✓ Copied" and "⌘V to paste" in the ears beside the notch, for 1.6 s: the drawer folded back into the notch,
    /// which says so.
    func showCopied(thumbnail: URL? = nil) {
        present(.copied, thumbnail: thumbnail, action: nil)
    }

    private func present(_ content: HUDPill.Content, thumbnail: URL?, action: HUDAction?) {
        generation += 1
        let current = generation
        isHovered = false

        let screen = NSScreen.main ?? NSScreen.screens.first
        let measured = NotchMetrics.measure(screen)
        var pill = HUDPill(content: content, thumbnail: thumbnail, margin: shadowMargin, bandHeight: measured.band,
                           notchWidth: measured.notch, actionTitle: action?.title)
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
        window.setFrame(frame(for: size, on: screen), display: true)
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
        // Over the menu bar, like the drawer it stands in for.
        newPanel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
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

    /// Flush with the top of the screen, centered on the notch.
    private func frame(for size: NSSize, on screen: NSScreen?) -> NSRect {
        guard let screen else {
            return NSRect(origin: .zero, size: size)
        }
        let x = (screen.frame.midX - size.width / 2).rounded()
        return NSRect(x: x, y: (screen.frame.maxY - size.height).rounded(), width: size.width, height: size.height)
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

/// The HUD's content, in the drawer's shape, flush with the top of the screen. `.copied`: the band beside the notch
/// only, "✓ Copied" in the left ear and "⌘V to paste" in the right one. `.message`: the band, then a line under the
/// notch (optional thumbnail, the message, an optional button).
private struct HUDPill: View {
    enum Content {
        case copied
        case message(String)
    }

    let content: Content
    let thumbnail: URL?
    let margin: CGFloat
    let bandHeight: CGFloat
    let notchWidth: CGFloat
    var actionTitle: String? = nil
    var onAction: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }

    @State var image: NSImage? = nil

    /// Each ear of the copied notice.
    let earWidth: CGFloat = 112

    var body: some View {
        shape
            .onHover { hovering in
                onHover(hovering)
            }
            .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
            .padding(.horizontal, margin)
            .padding(.bottom, margin)
            .fixedSize()
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: actionTitle == nil ? .ignore : .contain)
            .accessibilityLabel(accessibilityText)
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

    @ViewBuilder
    private var shape: some View {
        switch content {
        case .copied:
            copiedEars
                .padding(.horizontal, Theme.shoulder)
                .background(DrawerShape(cornerRadius: 12).fill(Theme.hudBackground))
        case let .message(message):
            VStack(spacing: 0) {
                Color.clear
                    .frame(width: notchWidth + 2 * earWidth, height: bandHeight)
                messageLine(message)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                    .padding(.horizontal, 16)
            }
            .padding(.horizontal, Theme.shoulder)
            .background(DrawerShape(cornerRadius: 18).fill(Theme.hudBackground))
        }
    }

    /// The left ear says it is copied (with what, as a thumbnail), the right one how to paste it.
    private var copiedEars: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if thumbnail != nil {
                    thumbnailView(size: 20, radius: 5)
                }
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Theme.accent)
                Text("Copied")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
            }
            .frame(width: earWidth)
            Color.clear
                .frame(width: notchWidth)
            HStack(spacing: 6) {
                Text("⌘V")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.text)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 18, minHeight: 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Theme.keycapBorder, lineWidth: 1)
                    )
                Text("to paste")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.mutedText)
                    .lineLimit(1)
            }
            .frame(width: earWidth)
        }
        .frame(height: bandHeight)
    }

    private func messageLine(_ message: String) -> some View {
        HStack(spacing: 10) {
            if thumbnail != nil {
                thumbnailView(size: 28, radius: 6)
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
    }

    private var accessibilityText: String {
        switch content {
        case .copied: return "Copied. Press Command V to paste."
        case let .message(message): return message
        }
    }

    private func thumbnailView(size: CGFloat, radius: CGFloat) -> some View {
        ZStack {
            Theme.surface
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
