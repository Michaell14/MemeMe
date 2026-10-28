import AppKit
import AVFoundation
import Combine
import SwiftUI

/// Borderless floating panel that can take key focus without activating MemeMe,
/// so the chat app stays frontmost and keeps its draft and caret.
private final class KeyablePanel: NSPanel {
    /// Cleared while the You're-set card shows, so the user's ⌘V reaches the chat instead of the panel.
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Signals from result tiles to the panel controller. SwiftUI's `onDrag` reports when a drag begins
/// but not when it ends, so the controller watches the mouse button from that moment on.
@MainActor
enum TileDragEvents {
    static var dragDidBegin: (@MainActor () -> Void)? = nil
}

/// Shows and hides the search panel, keeps it sized to its SwiftUI content and routes keys.
@MainActor
final class PanelController: NSObject {
    /// What a press that started in another app does when it is released.
    private enum OutsidePress {
        case idle
        /// Closes the panel, unless released over it (a file dragged in from another app).
        case closes
        /// Answers a macOS consent alert: the panel stays.
        case answersConsentAlert
        /// Uses macOS's screenshot tool (⇧⌘4 selection, ⇧⌘5 toolbar): the panel stays, so it can be captured.
        case takesScreenshot
    }

    private let model: AppModel
    private let panel: KeyablePanel
    private let hostingView: NSHostingView<PanelView>

    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var dragWatch: Task<Void, Never>?
    private var previousApp: NSRunningApplication?
    private var modelObservation: AnyCancellable?
    private var sizeUpdatePending = false
    private var outsidePress: OutsidePress = .idle
    /// System uptime until which app switches are taken to come from answering a consent alert.
    private var consentAlertGraceUntil: TimeInterval = 0
    /// Screen position of the panel's top edge and horizontal center while it is visible.
    private var anchorTop: CGFloat = 0
    private var anchorMidX: CGFloat = 0
    /// visibleFrame of the screen the panel was opened on (the one with keyboard focus).
    private var anchorVisibleFrame: NSRect?

    /// Gap between the menu bar and the panel.
    private let menuBarGap: CGFloat = 8
    private let fallbackHeight: CGFloat = 330
    /// How long after answering a consent alert an app switch still counts as part of answering it.
    private let consentAlertGrace: TimeInterval = 1.5
    private let dragPollNanoseconds: UInt64 = 50_000_000

    /// macOS draws its consent alerts (camera; Desktop, Downloads and Documents folders) from this agent.
    private static let consentAlertBundleID = "com.apple.UserNotificationCenter"
    /// macOS draws the ⇧⌘4 selection and the ⇧⌘5 toolbar from this agent.
    private static let screenshotBundleID = "com.apple.screencaptureui"

    init(model: AppModel) {
        self.model = model
        let initialFrame = NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 330)
        panel = KeyablePanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        hostingView = NSHostingView(rootView: PanelView(model: model))
        super.init()
        configurePanel(initialFrame: initialFrame)

        model.onRequestClose = { [weak self] in
            self?.hide()
        }
        modelObservation = model.objectWillChange.sink { [weak self] _ in
            self?.scheduleSizeUpdate()
        }
        TileDragEvents.dragDidBegin = { [weak self] in
            self?.watchTileDrag()
        }
    }

    var isVisible: Bool {
        panel.isVisible
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard !panel.isVisible else {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let frontmost, frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        } else {
            previousApp = nil
        }

        model.panelWillShow(previousApp: previousApp)

        let size = contentSize()
        let screen = NSScreen.main ?? NSScreen.screens.first
        anchorVisibleFrame = screen?.visibleFrame
        if let screen {
            let full = screen.frame
            let visible = screen.visibleFrame
            anchorMidX = full.midX
            // With the menu bar hidden (full screen, auto-hide), stay below the camera housing.
            let usableTop = min(visible.maxY, full.maxY - screen.safeAreaInsets.top)
            anchorTop = usableTop - menuBarGap
        } else {
            anchorMidX = size.width / 2
            anchorTop = size.height
        }
        applyFrame(size: size)

        panel.allowsKey = true
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        installMonitors()
        // The first layout pass can settle after the window is on screen.
        scheduleSizeUpdate()
    }

    func hide() {
        hide(restoringPreviousApp: true)
    }

    /// `restoringPreviousApp` is false when the user went to another app themselves
    /// (a click or drop elsewhere, an app switch): giving focus back to the chat would undo that.
    private func hide(restoringPreviousApp: Bool) {
        guard panel.isVisible else { return }
        removeMonitors()
        panel.orderOut(nil)
        panel.allowsKey = true
        model.panelDidHide()

        if restoringPreviousApp, let app = previousApp, !app.isTerminated,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            app.activate(options: [])
        }
        previousApp = nil
    }

    // MARK: Window setup and sizing

    private func configurePanel(initialFrame: NSRect) {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .utilityWindow

        // A plain container keeps window sizing in our hands; the hosting view fills it.
        let container = NSView(frame: NSRect(origin: .zero, size: initialFrame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        panel.contentView = container
    }

    /// The SwiftUI content's size at the panel width.
    private func contentSize() -> NSSize {
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let height = fitting.height.isFinite && fitting.height > 1 ? fitting.height : fallbackHeight
        return NSSize(width: Theme.panelWidth, height: ceil(height))
    }

    /// Places the panel so its top edge stays at `anchorTop`, horizontally centered on `anchorMidX`.
    private func applyFrame(size: NSSize) {
        var frame = NSRect(
            x: (anchorMidX - size.width / 2).rounded(),
            y: anchorTop - size.height,
            width: size.width,
            height: size.height
        )
        // Clamp to the screen the anchor was computed from: panel.screen still names the display the
        // ordered-out panel was last shown on.
        if let visible = anchorVisibleFrame ?? (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            if frame.minY < visible.minY {
                frame.origin.y = visible.minY
            }
        }
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: panel.isVisible)
        panel.invalidateShadow()
    }

    /// Coalesces model changes into one update after SwiftUI has applied them.
    private func scheduleSizeUpdate() {
        guard !sizeUpdatePending else { return }
        sizeUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let controller = self else { return }
                controller.performPendingSizeUpdate()
            }
        }
    }

    private func performPendingSizeUpdate() {
        sizeUpdatePending = false
        guard panel.isVisible else { return }
        applyFrame(size: contentSize())
        syncKeyFocusWithSetupCard()
    }

    /// While the You're-set card shows, the panel stays on screen but hands key focus back to the chat,
    /// so the card's "Paste it with ⌘V" reaches the chat. Closing the card (×) makes the panel key again.
    private func syncKeyFocusWithSetupCard() {
        if model.showSetupCard {
            // Hand key focus to the chat only when the chat is the active app. When MemeMe itself is active
            // (first run from Finder, after the camera alert) no one would take it, and giving it up would
            // leave Esc with no window at all.
            guard panel.allowsKey, !NSApp.isActive else { return }
            panel.allowsKey = false
            guard panel.isKeyWindow else { return }
            // Ordering the key panel out returns key focus to the active app; it comes back as a non-key window.
            let animation = panel.animationBehavior
            panel.animationBehavior = .none
            panel.orderOut(nil)
            panel.orderFrontRegardless()
            panel.animationBehavior = animation
        } else if !panel.allowsKey {
            panel.allowsKey = true
            panel.makeKey()
        }
    }

    // MARK: Closing on clicks, app switches and drops elsewhere

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyUp {
                return self.handleKeyUp(event)
            }
            return self.handleKeyDown(event)
        }
        // Clicks in other apps close the panel, so a later ↵ can't reach the chat by surprise. Deciding on
        // release lets a file dragged in from another app be dropped on the panel.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]) { [weak self] event in
            self?.handleOutsideMouse(event)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.applicationDidActivate(app)
            }
        }
    }

    private func removeMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        dragWatch?.cancel()
        dragWatch = nil
        outsidePress = .idle
    }

    private func handleOutsideMouse(_ event: NSEvent) {
        guard panel.isVisible else { return }
        let location = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            if isAnsweringConsentAlert(at: location) {
                outsidePress = .answersConsentAlert
                extendConsentAlertGrace()
            } else if PanelController.ownerBundleID(ofWindowAt: location) == PanelController.screenshotBundleID {
                outsidePress = .takesScreenshot
            } else {
                outsidePress = .closes
            }
        case .leftMouseUp:
            let press = outsidePress
            outsidePress = .idle
            switch press {
            case .closes:
                if panel.frame.contains(location) {
                    // Released over the panel: something dragged in from another app was dropped on it.
                    if panel.allowsKey {
                        panel.makeKey()
                    }
                } else {
                    hide(restoringPreviousApp: false)
                }
            case .answersConsentAlert:
                extendConsentAlertGrace()
            case .takesScreenshot, .idle:
                break
            }
        case .rightMouseDown:
            if isAnsweringConsentAlert(at: location) {
                extendConsentAlertGrace()
            } else if PanelController.ownerBundleID(ofWindowAt: location) != PanelController.screenshotBundleID {
                hide(restoringPreviousApp: false)
            }
        default:
            break
        }
    }

    /// Switching to another app closes the panel, including the You're-set card.
    private func applicationDidActivate(_ app: NSRunningApplication?) {
        guard panel.isVisible, let app else { return }
        // MemeMe itself: activated for the camera alert, a menu command or a drop on the menu-bar icon.
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        // macOS's screenshot tool, while the user captures the panel.
        if app.bundleIdentifier == PanelController.screenshotBundleID { return }
        if app.bundleIdentifier == PanelController.consentAlertBundleID || isCameraAccessUndecided {
            extendConsentAlertGrace()
            return
        }
        // Focus going back to the chat right after a consent alert was answered.
        if ProcessInfo.processInfo.systemUptime < consentAlertGraceUntil { return }
        // A press still held is decided on release: it may be a drag onto the panel, or a tile drag out of it.
        if (NSEvent.pressedMouseButtons & 1) != 0 { return }
        hide(restoringPreviousApp: false)
    }

    /// macOS draws consent alerts in its own process, so answering one looks like a click in another app;
    /// it must not close the panel (closing would cancel the pending camera request on first run).
    /// While camera access is undecided, its alert is up or about to appear.
    private func isAnsweringConsentAlert(at screenPoint: NSPoint) -> Bool {
        isCameraAccessUndecided || PanelController.isConsentAlertWindow(at: screenPoint)
    }

    private var isCameraAccessUndecided: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined
    }

    private func extendConsentAlertGrace() {
        consentAlertGraceUntil = ProcessInfo.processInfo.systemUptime + consentAlertGrace
    }

    /// True when the topmost window at `screenPoint` belongs to the agent that shows consent alerts.
    private static func isConsentAlertWindow(at screenPoint: NSPoint) -> Bool {
        ownerBundleID(ofWindowAt: screenPoint) == consentAlertBundleID
    }

    /// Bundle id of the app that owns the topmost window at `screenPoint`.
    /// Owner PIDs are readable without Screen Recording access (only window titles are not).
    private static func ownerBundleID(ofWindowAt screenPoint: NSPoint) -> String? {
        let windowNumber = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        guard windowNumber > 0,
              let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(clamping: windowNumber)) as? [[String: Any]],
              let ownerPID = (windows.first?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let owner = NSRunningApplication(processIdentifier: ownerPID) else {
            return nil
        }
        return owner.bundleIdentifier
    }

    /// A tile drag ends in another process's drop, which no monitor sees: poll the button and close
    /// once it is released outside the panel, i.e. the tile was dropped into the chat.
    private func watchTileDrag() {
        guard panel.isVisible else { return }
        dragWatch?.cancel()
        let pollNanoseconds = dragPollNanoseconds
        dragWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: pollNanoseconds)
                guard let self, !Task.isCancelled else { return }
                if (NSEvent.pressedMouseButtons & 1) != 0 {
                    continue
                }
                self.dragWatch = nil
                if self.panel.isVisible && !self.panel.frame.contains(NSEvent.mouseLocation) {
                    self.hide(restoringPreviousApp: false)
                }
                return
            }
        }
    }

    // MARK: Keys

    private enum KeyCode {
        static let escape: UInt16 = 53
        static let returnKey: UInt16 = 36
        static let enter: UInt16 = 76
        static let tab: UInt16 = 48
        static let space: UInt16 = 49
        static let v: UInt16 = 9
        static let c: UInt16 = 8
        static let x: UInt16 = 7
        static let a: UInt16 = 0
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    /// Returns nil when the key was handled; otherwise the event continues to the search field.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard panel.isVisible, panel.isKeyWindow || event.window === panel else { return event }
        // Let an input method finish composing (marked text) before we interpret keys.
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() {
            return event
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = flags.contains(.command)
        let hasShift = flags.contains(.shift)
        // Keypad keys also carry .numericPad, which doesn't count as a modifier here.
        let hasNoModifiers = flags.intersection([.command, .control, .option, .shift]).isEmpty
        let hasNoCommandLikeModifiers = flags.intersection([.command, .control, .option]).isEmpty

        if model.isCaptureOpen {
            return handleCaptureKeyDown(event, hasNoCommandLikeModifiers: hasNoCommandLikeModifiers)
        }

        switch event.keyCode {
        case KeyCode.escape:
            if !model.handleEscape() {
                hide()
            }
            return nil

        case KeyCode.returnKey, KeyCode.enter:
            guard hasNoCommandLikeModifiers else { return event }
            model.commitFocused()
            return nil

        case KeyCode.left, KeyCode.right:
            guard hasNoCommandLikeModifiers, model.queryText.isEmpty else { return event }
            model.moveFocus(dx: event.keyCode == KeyCode.left ? -1 : 1, dy: 0)
            return nil

        case KeyCode.up, KeyCode.down:
            guard hasNoCommandLikeModifiers else { return event }
            model.moveFocus(dx: 0, dy: event.keyCode == KeyCode.up ? -1 : 1)
            return nil

        case KeyCode.space:
            guard model.queryText.isEmpty else { return event }
            if hasNoModifiers {
                model.snap()
                return nil
            }
            // ⇧Space opens the capture view.
            guard flags.intersection([.command, .control, .option, .shift]) == .shift, model.canOpenCapture else { return event }
            model.openCapture()
            return nil

        case KeyCode.tab:
            guard hasNoCommandLikeModifiers else { return event }
            if hasShift {
                model.backToFace()
            } else {
                model.moreLikeFocused()
            }
            return nil

        case KeyCode.v where hasCommand && flags.intersection([.control, .option]).isEmpty:
            if model.pasteFromClipboard() {
                return nil
            }
            return performTextCommand(event, action: #selector(NSText.paste(_:)))

        case KeyCode.c where hasCommand && flags.intersection([.control, .option, .shift]).isEmpty:
            return performTextCommand(event, action: #selector(NSText.copy(_:)))

        case KeyCode.x where hasCommand && flags.intersection([.control, .option, .shift]).isEmpty:
            return performTextCommand(event, action: #selector(NSText.cut(_:)))

        case KeyCode.a where hasCommand && flags.intersection([.control, .option, .shift]).isEmpty:
            return performTextCommand(event, action: #selector(NSText.selectAll(_:)))

        default:
            // A digit is what the key types on the active layout, not where it sits: AZERTY types
            // & é " ' ( § è ! ç à on the unshifted top row (its digits need Shift), Czech types + ě š č ř ž…
            guard hasNoCommandLikeModifiers, let digit = PanelController.typedDigit(of: event) else { return event }
            // Digits never type: 1–9 (main row or keypad) pick, 0 does nothing.
            if digit >= 1 {
                model.commitNumbered(index: digit - 1)
            }
            return nil
        }
    }

    /// The capture view has no text field: Space (tap or hold) and ↵ are the shutter, ← → change the filter, Esc goes
    /// back; other plain keys do nothing.
    private func handleCaptureKeyDown(_ event: NSEvent, hasNoCommandLikeModifiers: Bool) -> NSEvent? {
        switch event.keyCode {
        case KeyCode.escape:
            if !model.handleEscape() {
                hide()
            }
            return nil
        case KeyCode.space:
            // Held down, the key repeats; only the first press counts.
            if !event.isARepeat {
                model.capture.press()
            }
            return nil
        case KeyCode.returnKey, KeyCode.enter:
            guard hasNoCommandLikeModifiers, !event.isARepeat else { return nil }
            model.capture.press()
            model.capture.release()
            return nil
        case KeyCode.left, KeyCode.right:
            model.capture.cycleFilter(by: event.keyCode == KeyCode.left ? -1 : 1)
            return nil
        default:
            return hasNoCommandLikeModifiers ? nil : event
        }
    }

    /// Releasing Space ends a press in the capture view (people often let go of ⇧ first, so any modifiers count).
    private func handleKeyUp(_ event: NSEvent) -> NSEvent? {
        guard panel.isVisible, model.isCaptureOpen, event.keyCode == KeyCode.space else { return event }
        model.capture.release()
        return nil
    }

    /// The digit 0–9 this key types on the current keyboard layout, if any. Decimal digits of any script
    /// count (Arabic and Persian layouts type ١ and ۱ on their top row), so digits never type anywhere.
    private static func typedDigit(of event: NSEvent) -> Int? {
        guard let typed = event.characters, typed.count == 1,
              let character = typed.first,
              character.unicodeScalars.count == 1,
              character.unicodeScalars.first?.properties.numericType == .decimal,
              let value = character.wholeNumberValue,
              (0...9).contains(value) else { return nil }
        return value
    }

    /// Standard editing shortcuts for the search field. An accessory app may have no Edit menu,
    /// in which case these key equivalents would never reach the field on their own.
    private func performTextCommand(_ event: NSEvent, action: Selector) -> NSEvent? {
        if let mainMenu = NSApp.mainMenu, mainMenu.performKeyEquivalent(with: event) {
            return nil
        }
        if NSApp.sendAction(action, to: nil, from: panel) {
            return nil
        }
        return event
    }
}
