import AppKit

extension NSWindow.Level {
    /// The panel and the HUD: over every app's windows and the menu bar, like Spotlight.
    static let overMenuBar = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
}

/// Runs alerts and open panels in front of everything, MemeMe's own windows included. The panel and the HUD sit at
/// `.overMenuBar`, far above the modal level, so a plain `runModal()` would open behind them; and runModal sets the
/// alert's level as it shows it, so raising the alert doesn't hold. Instead, while a modal is up, those windows drop
/// to `.floating` (under it) and go back up once it closes. The panel sits below the menu bar, so nothing moves.
@MainActor
enum FrontModal {
    static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        withOwnWindowsLowered { alert.runModal() }
    }

    static func run(_ panel: NSSavePanel) -> NSApplication.ModalResponse {
        withOwnWindowsLowered { panel.runModal() }
    }

    private static func withOwnWindowsLowered<T>(_ body: () -> T) -> T {
        let raised = NSApp.windows.filter { $0.level == .overMenuBar }
        for window in raised { window.level = .floating }
        defer {
            for window in raised where window.level == .floating { window.level = .overMenuBar }
        }
        NSApp.activate(ignoringOtherApps: true)
        return body()
    }
}
