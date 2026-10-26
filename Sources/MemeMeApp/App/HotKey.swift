import Carbon
import Foundation
import os

private let hotKeyLog = Logger(subsystem: "com.mememe.app", category: "hotkey")

/// 'MMHK': marks MemeMe's hot keys in Carbon events.
private let hotKeySignature: OSType = 0x4D4D_484B

/// kEventHotKeyExclusive: registration fails when another process already holds the combination,
/// so "⌃⌘M is taken by another app" can be reported instead of silently sharing it.
private let exclusiveHotKeyOption: OptionBits = 1

/// Converts a byte count to whatever integer type the Carbon signature expects.
private func carbonCount<T: BinaryInteger>(_ value: Int) -> T {
    T(value)
}

/// Carbon callback for kEventHotKeyPressed. A C function pointer cannot capture context,
/// so the press is routed by identifier through `HotKey`'s registry on the main actor.
private func hotKeyEventHandler(_ callRef: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event = event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        carbonCount(MemoryLayout<EventHotKeyID>.size),
        nil,
        &hotKeyID
    )
    guard status == OSStatus(noErr), hotKeyID.signature == hotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }
    let identifier = hotKeyID.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            HotKey.handlePress(identifier: identifier)
        }
    }
    return OSStatus(noErr)
}

/// A system-wide shortcut registered with Carbon (`RegisterEventHotKey`), which needs no permission.
@MainActor final class HotKey {
    let keyCode: UInt32
    let modifiers: UInt32

    private let identifier: UInt32
    private let action: @MainActor () -> Void
    private var hotKeyRef: EventHotKeyRef?

    private static var registered: [UInt32: HotKey] = [:]
    private static var nextIdentifier: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    /// `keyCode` is a virtual key code (kVK_*), `modifiers` Carbon modifier flags (cmdKey, controlKey, …).
    init(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.action = action
        self.identifier = HotKey.nextIdentifier
        HotKey.nextIdentifier += 1
    }

    var isRegistered: Bool {
        hotKeyRef != nil
    }

    /// Returns false when the shortcut could not be registered (for example, another app holds it).
    @discardableResult
    func register() -> Bool {
        if hotKeyRef != nil { return true }
        guard HotKey.installEventHandlerIfNeeded() else { return false }

        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: identifier)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), exclusiveHotKeyOption, &reference)
        guard status == OSStatus(noErr), let registeredRef = reference else {
            hotKeyLog.error("Registering the hot key failed (OSStatus \(status, privacy: .public))")
            return false
        }
        hotKeyRef = registeredRef
        HotKey.registered[identifier] = self
        return true
    }

    func unregister() {
        guard let reference = hotKeyRef else { return }
        let status = UnregisterEventHotKey(reference)
        if status != OSStatus(noErr) {
            hotKeyLog.error("Unregistering the hot key failed (OSStatus \(status, privacy: .public))")
        }
        hotKeyRef = nil
        HotKey.registered[identifier] = nil
    }

    static func handlePress(identifier: UInt32) {
        registered[identifier]?.action()
    }

    /// One application-level handler serves every hot key.
    private static func installEventHandlerIfNeeded() -> Bool {
        if eventHandler != nil { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var handler: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &eventType, nil, &handler)
        guard status == OSStatus(noErr), let installed = handler else {
            hotKeyLog.error("Installing the hot key handler failed (OSStatus \(status, privacy: .public))")
            return false
        }
        eventHandler = installed
        return true
    }
}
