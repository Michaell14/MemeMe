import AppKit
import MemeMeCore
import os

private let launchLog = Logger(subsystem: "com.mememe.app", category: "app")

/// Builds the app at launch: library store, model, panel, menu-bar item and the panel's hot key (⌥M unless changed).
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var panel: PanelController?
    private var statusItem: StatusItemController?
    private var popoverModel: StickerPopoverModel?
    /// The panel's (⌥M) and the screen cut's (⌥S) hot keys, as picked in Change Shortcut…, and what each does.
    private var hotKeys: [HotKeyRole: HotKey] = [:]
    private var hotKeyActions: [HotKeyRole: @MainActor () -> Void] = [:]
    private var screenCut: ScreenCutController?

    /// Set once the first-run panel has opened by itself, so later launches (login) stay quiet until ⌥M.
    /// AppModel.syncLoginItem reads it too: only that first launch registers Open at Login by itself.
    static let firstRunPanelShownKey = "firstRunPanelShown"

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        guard let store = openStore() else {
            reportStoreFailureAndQuit()
            return
        }

        let model = AppModel(store: store)
        let panel = PanelController(model: model)
        let popoverModel = StickerPopoverModel(friends: model.friends, indexer: model.indexer)
        popoverModel.store = store
        let statusItem = StatusItemController(model: model, popoverModel: popoverModel, openPanel: { [weak panel] in
            panel?.show()
        })

        let screenCut = ScreenCutController(model: model)
        let startScreenCut: @MainActor () -> Void = { [weak panel, weak screenCut] in
            panel?.hide()
            screenCut?.start()
        }
        model.onRequestScreenCut = startScreenCut
        hotKeyActions[.panel] = { [weak panel] in
            panel?.toggle()
        }
        // ⌥S: Clip me while the panel's face search reads you (a still sticker of your reaction); else a cut from
        // the screen.
        hotKeyActions[.screenCut] = { [weak model] in
            guard let model else { return }
            if model.isPanelVisible && model.faceSearchOn {
                model.clipTap()
            } else {
                startScreenCut()
            }
        }

        self.model = model
        self.panel = panel
        self.screenCut = screenCut
        self.popoverModel = popoverModel
        self.statusItem = statusItem

        for role in HotKeyRole.allCases {
            let shortcut = store.settings.shortcut(for: role)
            let hotKey = makeHotKey(role, shortcut)
            hotKeys[role] = hotKey
            let registered = hotKey.register()
            if !registered && role == .screenCut {
                launchLog.error("The screen cut's shortcut is taken by another app: it opens from the panel's ✂ only")
            }
            model.setHotKey(shortcut, available: registered, for: role)
        }
        model.onChangeHotKey = { [weak self] role, shortcut in
            self?.rebindHotKey(role, to: shortcut) ?? false
        }
        model.onSuspendHotKeys = { [weak self] suspended in
            self?.suspendHotKeys(suspended) ?? []
        }
        model.start()

        // First run: the panel opens by itself, under the menu bar, once per install. Later launches (login item)
        // stay quiet until ⌥M; the You're-set card still appears on the first pick (AppModel).
        let defaults = UserDefaults.standard
        if !store.settings.hasCompletedFirstRun,
           !defaults.bool(forKey: AppDelegate.firstRunPanelShownKey) {
            defaults.set(true, forKey: AppDelegate.firstRunPanelShownKey)
            panel.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        for hotKey in hotKeys.values {
            hotKey.unregister()
        }
        model?.saveNow()
    }

    /// Opening the app again (Finder, Spotlight) while it runs shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.show()
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Private

    private func makeHotKey(_ role: HotKeyRole, _ shortcut: HotKeyShortcut) -> HotKey {
        let action = hotKeyActions[role]
        return HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, action: {
            action?()
        })
    }

    /// Change Shortcut…: the new shortcut replaces `role`'s hot key only once it is registered; when another app
    /// holds it, the old one stays (registered again unless the hot keys are suspended meanwhile).
    private func rebindHotKey(_ role: HotKeyRole, to shortcut: HotKeyShortcut) -> Bool {
        let old = hotKeys[role]
        let oldWasRegistered = old?.isRegistered ?? false
        old?.unregister()
        let new = makeHotKey(role, shortcut)
        if new.register() {
            hotKeys[role] = new
            return true
        }
        if oldWasRegistered {
            old?.register()
        }
        return false
    }

    /// Lets go of the hot keys while Change Shortcut… records keys, so they reach its alert; after, takes them back
    /// and returns the roles whose hot key is registered.
    private func suspendHotKeys(_ suspended: Bool) -> Set<HotKeyRole> {
        if suspended {
            for hotKey in hotKeys.values {
                hotKey.unregister()
            }
            return []
        }
        var registered = Set<HotKeyRole>()
        for (role, hotKey) in hotKeys where hotKey.register() {
            registered.insert(role)
        }
        if !registered.contains(.screenCut) {
            launchLog.error("The screen cut's shortcut is taken by another app: it opens from the panel's ✂ only")
        }
        return registered
    }

    /// An accessory app shows no menu bar, but AppKit still resolves ⌘Z/⌘X/⌘C/⌘V/⌘A through the main menu.
    /// Without this hidden Edit menu, text fields in alerts and open panels (such as "Set GIPHY API Key…")
    /// can't paste. The panel's own key monitor still sees its keys first (⌘V with an image is a query).
    private func installEditMenu() {
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        // The first item of a main menu is the application menu; it stays empty (no ⌘Q that would quit
        // MemeMe while the panel has key focus over a chat).
        let appMenuItem = NSMenuItem(title: "MemeMe", action: nil, keyEquivalent: "")
        appMenuItem.submenu = NSMenu(title: "MemeMe")
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu

        let mainMenu = NSMenu(title: "Main Menu")
        mainMenu.addItem(appMenuItem)
        mainMenu.addItem(editMenuItem)
        NSApplication.shared.mainMenu = mainMenu
    }

    /// ~/Library/Application Support/MemeMe, or a temporary library when that can't be created.
    private func openStore() -> LibraryStore? {
        do {
            return try LibraryStore(rootURL: LibraryStore.defaultRootURL())
        } catch {
            launchLog.error("Opening the library failed: \(error.localizedDescription, privacy: .public)")
        }
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("MemeMe", isDirectory: true)
        do {
            return try LibraryStore(rootURL: fallback)
        } catch {
            launchLog.error("Opening a temporary library failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func reportStoreFailureAndQuit() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "MemeMe can’t open its library"
        alert.informativeText = "It couldn’t create a folder in Application Support or in the temporary folder. Check the disk’s free space and permissions, then open MemeMe again."
        alert.addButton(withTitle: "Quit")
        _ = FrontModal.run(alert)
        NSApplication.shared.terminate(nil)
    }
}
