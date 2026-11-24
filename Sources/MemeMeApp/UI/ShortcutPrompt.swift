import AppKit
import Carbon
import MemeMeCore

/// What letter keys say on the current keyboard layout (key codes are positions: the ANSI "Q" is "A" on AZERTY).
@MainActor enum KeyboardLayout {
    /// The key's label in the current ASCII-capable layout, uppercased; nil for keys whose label doesn't depend
    /// on the layout, or when the layout can't be read.
    static func label(for keyCode: UInt32) -> String? {
        guard HotKeyShortcut.isCharacterKey(keyCode),
              let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout -> String? in
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
            guard status == noErr, length > 0 else { return nil }
            let label = String(utf16CodeUnits: characters, count: length)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            return label.isEmpty ? nil : label
        }
    }
}

extension HotKeyShortcut {
    /// From a key press: its key code and its ⌘ ⇧ ⌥ ⌃.
    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= HotKeyShortcut.command }
        if flags.contains(.shift) { modifiers |= HotKeyShortcut.shift }
        if flags.contains(.option) { modifiers |= HotKeyShortcut.option }
        if flags.contains(.control) { modifiers |= HotKeyShortcut.control }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    @MainActor var layoutKeyName: String? { KeyboardLayout.label(for: keyCode) }
    /// "⌥M", with the key as the current layout shows it.
    @MainActor var label: String { display(keyName: layoutKeyName) }
    /// ["⌥", "M"], for keycaps.
    @MainActor var keycaps: [String] { symbols(keyName: layoutKeyName) }
    /// "Option M".
    @MainActor var accessibilityName: String { spokenName(keyName: layoutKeyName) }
    @MainActor var problemText: String? { problemMessage(keyName: layoutKeyName) }

    /// The menu item's key equivalent ("m" with [.option]); nil for keys a menu can't show as one character.
    @MainActor var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard HotKeyShortcut.isCharacterKey(keyCode) else { return nil }
        let key = (layoutKeyName ?? HotKeyShortcut.keyName(for: keyCode)).lowercased()
        guard key.count == 1 else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if has(HotKeyShortcut.command) { flags.insert(.command) }
        if has(HotKeyShortcut.shift) { flags.insert(.shift) }
        if has(HotKeyShortcut.option) { flags.insert(.option) }
        if has(HotKeyShortcut.control) { flags.insert(.control) }
        return (key, flags)
    }
}

/// Change Shortcut…: an alert that records the keys pressed and makes them the panel's shortcut.
@MainActor enum ShortcutPrompt {
    private static let returnKey: UInt16 = 36
    private static let enterKey: UInt16 = 76
    private static let escapeKey: UInt16 = 53

    /// Runs until a shortcut is saved, the alert is cancelled, or the panel is back on ⌥M. MemeMe's hot keys are let
    /// go meanwhile, so pressing the current one (or ⌥S) is recorded instead of acting.
    static func run(model: AppModel) {
        model.suspendHotKeys(true)
        defer { model.suspendHotKeys(false) }

        var candidate: HotKeyShortcut? = nil
        var notice: String? = model.hotKeyAvailable ? nil : "\(model.hotKey.label) is taken by another app."
        while true {
            guard let outcome = ask(model: model, candidate: candidate, notice: notice) else { return }
            if outcome == model.hotKey && model.hotKeyAvailable { return }
            if model.changeHotKey(to: outcome) {
                HUDController.shared.show("Open MemeMe with \(outcome.label)")
                return
            }
            candidate = outcome
            notice = "\(outcome.label) is taken by another app. Try another."
        }
    }

    /// One round of the alert: the shortcut to save, or nil when cancelled.
    private static func ask(model: AppModel, candidate: HotKeyShortcut?, notice: String?) -> HotKeyShortcut? {
        let current = model.hotKey
        let alert = NSAlert()
        alert.messageText = "Shortcut for MemeMe"
        alert.informativeText = "Press the keys that open MemeMe from any app. Use ⌃, ⌥ or ⌘ with a key, or an F key on its own."
        let save = alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if current != .standard {
            alert.addButton(withTitle: "Use \(HotKeyShortcut.standard.label)")
        }

        let field = ShortcutField(frame: NSRect(x: 0, y: 0, width: 300, height: 58))
        field.show(candidate ?? current, notice: notice, isWarning: notice != nil)
        alert.accessoryView = field
        var recorded = candidate
        save.isEnabled = candidate.map { $0.problem == nil } ?? false

        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === alert.window else { return event }
            let pressed = HotKeyShortcut(event: event)
            let strong = HotKeyShortcut.command | HotKeyShortcut.option | HotKeyShortcut.control
            if pressed.modifiers & strong == 0 && !HotKeyShortcut.isFunctionKey(pressed.keyCode) {
                // Return saves and Escape cancels, as in any alert.
                if [ShortcutPrompt.returnKey, ShortcutPrompt.enterKey, ShortcutPrompt.escapeKey].contains(event.keyCode) && pressed.modifiers == 0 { return event }
            }
            if let problem = pressed.problemText {
                field.show(pressed, notice: problem, isWarning: true)
                recorded = nil
                save.isEnabled = false
            } else {
                field.show(pressed, notice: pressed == current ? "That’s the shortcut now." : nil, isWarning: false)
                recorded = pressed
                save.isEnabled = true
            }
            return nil
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        switch FrontModal.run(alert) {
        case .alertFirstButtonReturn: return recorded
        case .alertThirdButtonReturn: return .standard
        default: return nil
        }
    }
}

/// The alert's keycaps and the line under them (what to do, or why the keys pressed can't be used).
private final class ShortcutField: NSView {
    private let keys = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        keys.font = .systemFont(ofSize: 22, weight: .medium)
        keys.alignment = .center
        note.font = .systemFont(ofSize: 11)
        note.alignment = .center
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 2
        for label in [keys, note] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            keys.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            keys.leadingAnchor.constraint(equalTo: leadingAnchor),
            keys.trailingAnchor.constraint(equalTo: trailingAnchor),
            note.topAnchor.constraint(equalTo: keys.bottomAnchor, constant: 4),
            note.leadingAnchor.constraint(equalTo: leadingAnchor),
            note.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    @MainActor func show(_ shortcut: HotKeyShortcut, notice: String?, isWarning: Bool) {
        keys.stringValue = shortcut.keycaps.joined(separator: " ")
        keys.setAccessibilityLabel(shortcut.accessibilityName)
        note.stringValue = notice ?? "Press a new shortcut."
        note.textColor = isWarning ? .systemRed : .secondaryLabelColor
    }
}
