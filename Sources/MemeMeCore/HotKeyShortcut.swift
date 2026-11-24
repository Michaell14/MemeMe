import Foundation

/// The shortcut that opens the panel from any app, as Carbon registers it: a virtual key code (kVK_*) and Carbon
/// modifier flags. Names here follow the ANSI (US) layout; the app shows letter keys in the current layout.
public struct HotKeyShortcut: Equatable, Hashable, Sendable {
    // Carbon modifier flags (cmdKey, shiftKey, optionKey, controlKey).
    public static let command: UInt32 = 256
    public static let shift: UInt32 = 512
    public static let option: UInt32 = 2048
    public static let control: UInt32 = 4096
    public static let supportedModifiers: UInt32 = command | shift | option | control

    public var keyCode: UInt32
    public var modifiers: UInt32

    /// Flags other than ⌘ ⇧ ⌥ ⌃ (caps lock, the keypad bit) are dropped.
    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & HotKeyShortcut.supportedModifiers
    }

    /// ⌥M, the shortcut MemeMe ships with.
    public static let standard = HotKeyShortcut(keyCode: 46, modifiers: option)
    /// ⌥S, the screen cut's own shortcut.
    public static let screenCut = HotKeyShortcut(keyCode: 1, modifiers: option)

    /// Shortcuts macOS keeps for itself: Spotlight, input sources, the app switcher, screenshots, Lock Screen,
    /// Force Quit, the Character Viewer.
    static let reserved: Set<HotKeyShortcut> = [
        HotKeyShortcut(keyCode: 49, modifiers: command),                     // ⌘Space
        HotKeyShortcut(keyCode: 49, modifiers: control),                     // ⌃Space
        HotKeyShortcut(keyCode: 49, modifiers: command | option),            // ⌥⌘Space
        HotKeyShortcut(keyCode: 49, modifiers: control | command),           // ⌃⌘Space
        HotKeyShortcut(keyCode: 48, modifiers: command | shift),             // ⇧⌘Tab
        HotKeyShortcut(keyCode: 20, modifiers: command | shift),             // ⇧⌘3
        HotKeyShortcut(keyCode: 21, modifiers: command | shift),             // ⇧⌘4
        HotKeyShortcut(keyCode: 23, modifiers: command | shift),             // ⇧⌘5
        HotKeyShortcut(keyCode: 12, modifiers: control | command),           // ⌃⌘Q
        HotKeyShortcut(keyCode: 53, modifiers: command | option),            // ⌥⌘⎋
    ]

    public func has(_ modifier: UInt32) -> Bool {
        modifiers & modifier != 0
    }

    // MARK: Checking

    public enum Problem: Equatable, Sendable {
        /// No ⌃, ⌥ or ⌘ (⇧ alone isn't enough), on a key other than F1–F20.
        case needsModifier
        /// ⌘ alone: those belong to the app in front.
        case commandOnly
        /// ⌥S is the screen cut's.
        case screenCut
        /// macOS uses it.
        case reserved
    }

    /// Why this can't be the panel's shortcut; nil when it can.
    public var problem: Problem? {
        let strong = HotKeyShortcut.command | HotKeyShortcut.option | HotKeyShortcut.control
        if modifiers & strong == 0 && !HotKeyShortcut.isFunctionKey(keyCode) { return .needsModifier }
        if modifiers == HotKeyShortcut.command && !HotKeyShortcut.isFunctionKey(keyCode) { return .commandOnly }
        if self == HotKeyShortcut.screenCut { return .screenCut }
        if HotKeyShortcut.reserved.contains(self) { return .reserved }
        return nil
    }

    /// What to tell someone who pressed it ("⌥S cuts stickers from the screen."); nil when it's fine.
    /// `keyName` is the key as the current layout shows it (see `symbols(keyName:)`).
    public func problemMessage(keyName: String? = nil) -> String? {
        switch problem {
        case .needsModifier: return "Add ⌃, ⌥ or ⌘ to the key."
        case .commandOnly: return "⌘ shortcuts belong to the app you’re in. Add ⌃, ⌥ or ⇧."
        case .screenCut: return "⌥S cuts stickers from the screen. Pick another."
        case .reserved: return "macOS uses \(display(keyName: keyName)). Pick another."
        case nil: return nil
        }
    }

    // MARK: Showing

    /// ⌃ ⌥ ⇧ ⌘ in the order macOS menus show them, then the key: ["⌥", "M"]. `keyName` replaces the ANSI name
    /// of a letter or symbol key (another layout's letter); nil or empty keeps it.
    public func symbols(keyName: String? = nil) -> [String] {
        var parts: [String] = []
        if has(HotKeyShortcut.control) { parts.append("⌃") }
        if has(HotKeyShortcut.option) { parts.append("⌥") }
        if has(HotKeyShortcut.shift) { parts.append("⇧") }
        if has(HotKeyShortcut.command) { parts.append("⌘") }
        parts.append(resolvedKeyName(keyName))
        return parts
    }

    /// "⌥M", "⌃⌥Space".
    public func display(keyName: String? = nil) -> String {
        symbols(keyName: keyName).joined()
    }

    /// "Option M", "Control Shift Left Arrow", for VoiceOver.
    public func spokenName(keyName: String? = nil) -> String {
        var words: [String] = []
        if has(HotKeyShortcut.control) { words.append("Control") }
        if has(HotKeyShortcut.option) { words.append("Option") }
        if has(HotKeyShortcut.shift) { words.append("Shift") }
        if has(HotKeyShortcut.command) { words.append("Command") }
        words.append(HotKeyShortcut.spokenKeyNames[keyCode] ?? resolvedKeyName(keyName))
        return words.joined(separator: " ")
    }

    private func resolvedKeyName(_ keyName: String?) -> String {
        if HotKeyShortcut.isCharacterKey(keyCode), let keyName, !keyName.isEmpty { return keyName }
        return HotKeyShortcut.keyName(for: keyCode)
    }

    // MARK: Keys

    /// F1–F20, which work as a shortcut without a modifier.
    public static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        functionKeys[keyCode] != nil
    }

    /// Letter, digit and symbol keys of the main block, whose label depends on the layout.
    public static func isCharacterKey(_ keyCode: UInt32) -> Bool {
        characterKeys[keyCode] != nil
    }

    /// The key's label on an ANSI keyboard ("M", "Space", "F5", "←"); "Key 93" for one this table doesn't know.
    public static func keyName(for keyCode: UInt32) -> String {
        characterKeys[keyCode] ?? functionKeys[keyCode] ?? specialKeys[keyCode] ?? keypadKeys[keyCode] ?? "Key \(keyCode)"
    }

    private static let characterKeys: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 10: "§", 11: "B",
        12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 50: "`",
    ]

    private static let functionKeys: [UInt32: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]

    private static let specialKeys: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 114: "Help", 115: "↖", 116: "⇞",
        117: "⌦", 119: "↘", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    private static let keypadKeys: [UInt32: String] = [
        65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Clear", 75: "Keypad /", 78: "Keypad -",
        81: "Keypad =", 82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4",
        87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9",
    ]

    private static let spokenKeyNames: [UInt32: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape", 76: "Enter", 115: "Home",
        116: "Page Up", 117: "Forward Delete", 119: "End", 121: "Page Down", 123: "Left Arrow",
        124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow",
    ]
}
