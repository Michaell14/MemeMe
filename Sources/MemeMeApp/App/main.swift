import AppKit

// Top-level code runs on the main thread, so it may assume main-actor isolation to build the
// @MainActor delegate and drive NSApplication.

/// Strong reference for the life of the process (`NSApplication.delegate` is weak).
let appDelegate: AppDelegate = MainActor.assumeIsolated {
    AppDelegate()
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    // Menu-bar app: no Dock icon and no visible menu bar (LSUIElement also says so in the bundle's
    // Info.plist). The delegate installs a hidden Edit menu so ⌘C/⌘V work in text fields.
    application.setActivationPolicy(.accessory)
    application.delegate = appDelegate
    application.run()
}
