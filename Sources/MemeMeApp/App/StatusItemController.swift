import AppKit
import Combine
import MemeMeCore
import QuartzCore
import SwiftUI

/// The menu-bar icon: its menu, its drop target (dropped files are kept or turned into stickers),
/// the popover that reports what a drop did and the dot that says an update is ready.
@MainActor final class StatusItemController: NSObject {
    private let model: AppModel
    private let popoverModel: StickerPopoverModel
    private let openPanel: @MainActor () -> Void
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let menuDelegate: StatusMenuDelegate

    private var dropView: DropTargetView?
    private var updateObservation: AnyCancellable?
    private var popover: NSPopover?
    private var popoverWatch: Task<Void, Never>?
    private var popoverCloseObserver: NSObjectProtocol?
    private var lastPopoverHover: TimeInterval = 0

    /// The popover closes after this long without the pointer over it.
    private static let popoverIdleTimeout: TimeInterval = 8
    private static let popoverPollNanoseconds: UInt64 = 250_000_000
    private static let pauseInterval: TimeInterval = 3600
    private static let defaultToolTip = "MemeMe (⌃⌘M). Drop images here to keep them."
    private static let updateToolTip = "MemeMe (⌃⌘M). An update is ready."

    init(model: AppModel, popoverModel: StickerPopoverModel, openPanel: @escaping @MainActor () -> Void) {
        self.model = model
        self.popoverModel = popoverModel
        self.openPanel = openPanel
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.menu = NSMenu(title: "MemeMe")
        self.menuDelegate = StatusMenuDelegate()
        super.init()

        menu.autoenablesItems = false
        menuDelegate.onNeedsUpdate = { [weak self] in
            self?.rebuildMenu()
        }
        menu.delegate = menuDelegate
        statusItem.menu = menu
        configureButton()
        rebuildMenu()

        updateObservation = model.updates.$available
            .receive(on: RunLoop.main)
            .sink { [weak self] manifest in
                MainActor.assumeIsolated {
                    guard let controller = self else { return }
                    controller.showUpdateBadge(manifest != nil)
                }
            }

        popoverModel.onClose = { [weak self] in
            self?.closePopover()
        }
    }

    // MARK: - Button and drop target

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = StatusItemController.statusImage(badged: false)
        button.imagePosition = .imageOnly
        button.toolTip = StatusItemController.defaultToolTip

        let dropView = DropTargetView(frame: button.bounds)
        dropView.autoresizingMask = [.width, .height]
        dropView.toolTip = button.toolTip
        dropView.onDrop = { [weak self] urls in
            self?.handleDrop(urls)
        }
        button.addSubview(dropView)
        self.dropView = dropView
    }

    /// The dot on the icon while an update is available; the drop view's tooltip mirrors the button's.
    private func showUpdateBadge(_ badged: Bool) {
        guard let button = statusItem.button else { return }
        button.image = StatusItemController.statusImage(badged: badged)
        button.toolTip = badged ? StatusItemController.updateToolTip : StatusItemController.defaultToolTip
        dropView?.toolTip = button.toolTip
    }

    /// `face.smiling` as a template image. Badged, a small dot sits in the top-right corner with a gap
    /// cut around it; one template image, so the menu bar tints the face and the dot alike.
    private static func statusImage(badged: Bool) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "MemeMe") else { return nil }
        symbol.isTemplate = true
        guard badged else { return symbol }

        let size = symbol.size
        let diameter = (min(size.width, size.height) * 0.34).rounded()
        let gap: CGFloat = 1.5
        let image = NSImage(size: size, flipped: false) { rect in
            let dot = NSRect(x: rect.maxX - diameter, y: rect.maxY - diameter, width: diameter, height: diameter)
            // Even-odd clip: the face is drawn everywhere except a ring around the dot.
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath(rect: rect)
            clip.appendOval(in: dot.insetBy(dx: -gap, dy: -gap))
            clip.windingRule = .evenOdd
            clip.addClip()
            symbol.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MemeMe. An update is ready."
        return image
    }

    private func handleDrop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.model.handleMenuBarDrop(urls: urls)
            self.present(outcome)
        }
    }

    private func present(_ outcome: DropOutcome) {
        switch outcome {
        case .kept(let batch):
            popoverModel.present(kept: batch)
            showPopover()
        case .stickers(let batch):
            popoverModel.present(stickers: batch)
            showPopover()
        case .nothing:
            break
        }
    }

    // MARK: - Popover

    private func showPopover() {
        guard let button = statusItem.button else { return }
        let popover = self.popover ?? makePopover()
        self.popover = popover
        if !popover.isShown {
            // The user just dropped something on the icon: make MemeMe active so the popover's
            // buttons respond to the first click.
            NSApplication.shared.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        lastPopoverHover = CACurrentMediaTime()
        watchPopover()
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let controller = NSHostingController(rootView: StickerPopoverView(model: popoverModel))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popoverCloseObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification,
            object: popover,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let controller = self else { return }
                controller.popoverDidClose()
            }
        }
        return popover
    }

    /// However the popover closed (outside click, idle timeout, its own buttons).
    private func popoverDidClose() {
        // A drop during the closing animation shows it again; that new content stays as it is.
        if let popover = popover, popover.isShown { return }
        popoverWatch?.cancel()
        popoverWatch = nil
        popoverModel.dismissGroupingQuestionIfUnanswered()
    }

    /// Polls the pointer: hovering keeps the popover open, 8 s without hover closes it.
    private func watchPopover() {
        popoverWatch?.cancel()
        popoverWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: StatusItemController.popoverPollNanoseconds)
                guard let self, !Task.isCancelled else { return }
                if !self.popoverStillOpen() { return }
            }
        }
    }

    /// Returns false once the popover is closed (by outside click, its own buttons or the idle timeout).
    private func popoverStillOpen() -> Bool {
        guard let popover = popover, popover.isShown else { return false }
        let now = CACurrentMediaTime()
        if let window = popover.contentViewController?.view.window, window.frame.contains(NSEvent.mouseLocation) {
            lastPopoverHover = now
        }
        if now - lastPopoverHover >= StatusItemController.popoverIdleTimeout {
            popover.close()
            return false
        }
        return true
    }

    private func closePopover() {
        popoverWatch?.cancel()
        popoverWatch = nil
        if let popover = popover, popover.isShown {
            popover.close()
        }
    }

    // MARK: - Menu

    /// Rebuilt every time the menu opens, so checkmarks always reflect the current settings.
    private func rebuildMenu() {
        menu.removeAllItems()
        let settings = model.store.settings
        let updates = model.updates

        if updates.phase == .downloading || updates.phase == .installing {
            menu.addItem(makeHeader("Updating MemeMe…"))
            menu.addItem(.separator())
        } else if let manifest = updates.available {
            menu.addItem(makeItem("Update to MemeMe \(manifest.displayVersion)…", action: #selector(installUpdate(_:))))
            menu.addItem(.separator())
        }

        let open = makeItem("Open MemeMe", action: #selector(openMemeMe(_:)))
        open.keyEquivalent = "m"
        open.keyEquivalentModifierMask = [.control, .command]
        menu.addItem(open)

        menu.addItem(.separator())
        menu.addItem(makeHeader("Collecting from"))
        var listedPaths = Set<String>()
        for url in model.indexer.defaultFolders() {
            let path = url.standardizedFileURL.path
            listedPaths.insert(path)
            let item = makeItem(defaultFolderName(forPath: path), action: #selector(toggleFolder(_:)))
            item.representedObject = url
            item.state = model.indexer.isWatching(url) ? .on : .off
            item.indentationLevel = 1
            item.toolTip = path
            menu.addItem(item)
        }
        for path in settings.watchedFolders where !listedPaths.contains(path) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let name = url.lastPathComponent.isEmpty ? path : url.lastPathComponent
            let item = makeItem(name, action: #selector(toggleFolder(_:)))
            item.representedObject = url
            item.state = .on
            item.indentationLevel = 1
            item.toolTip = path
            menu.addItem(item)
        }
        menu.addItem(makeItem("Add Folder…", action: #selector(addFolder(_:))))
        if settings.watchedFolders.isEmpty {
            menu.addItem(makeItem("Find Memes on This Mac", action: #selector(findMemes(_:))))
        }
        if isCollectingPaused(settings) {
            menu.addItem(makeItem("Resume Collecting", action: #selector(resumeCollecting(_:))))
        } else {
            menu.addItem(makeItem("Pause Collecting for 1 Hour", action: #selector(pauseCollecting(_:))))
        }

        menu.addItem(.separator())
        // Without a key Web Discover can't search, so it shows as off until one is set. When GIPHY refuses
        // searches, the item says why.
        let hasGiphyKey = model.web.hasAPIKey
        var webTitle = "Web Discover (GIPHY)"
        switch hasGiphyKey ? model.web.status : .noKey {
        case .noKey: webTitle += ": No API Key"
        case .keyRejected: webTitle += ": Key Not Accepted"
        case .limitReached: webTitle += ": Hourly Limit Reached"
        case .off, .ready: break
        }
        let webDiscover = makeItem(webTitle, action: #selector(toggleWebDiscover(_:)))
        webDiscover.state = settings.webDiscoverEnabled && hasGiphyKey ? .on : .off
        webDiscover.isEnabled = hasGiphyKey
        menu.addItem(webDiscover)
        menu.addItem(makeItem("Set GIPHY API Key…", action: #selector(setGiphyAPIKey(_:))))

        menu.addItem(.separator())
        let photosMenu = NSMenu(title: "Photos with People")
        photosMenu.autoenablesItems = false
        let policies: [(title: String, policy: StickerPolicy)] = [
            (title: "Make Stickers Automatically", policy: .automatic),
            (title: "Ask Each Time", policy: .ask),
            (title: "Never", policy: .never),
        ]
        for entry in policies {
            let item = makeItem(entry.title, action: #selector(setStickerPolicy(_:)))
            item.representedObject = entry.policy.rawValue
            item.state = settings.stickerPolicy == entry.policy ? .on : .off
            photosMenu.addItem(item)
        }
        let photos = NSMenuItem(title: "Photos with People", action: nil, keyEquivalent: "")
        photos.submenu = photosMenu
        menu.addItem(photos)
        let groupFaces = makeItem("Group Friends’ Faces", action: #selector(toggleGroupFaces(_:)))
        groupFaces.state = settings.groupFaces == true ? .on : .off
        menu.addItem(groupFaces)
        menu.addItem(makeItem("Forget My Resting Face", action: #selector(forgetRestingFace(_:))))

        menu.addItem(.separator())
        let login = makeItem("Open at Login", action: #selector(toggleOpenAtLogin(_:)))
        login.state = settings.openAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(makeItem("Show Library in Finder", action: #selector(showLibrary(_:))))

        if updates.isEnabled {
            menu.addItem(.separator())
            let check = makeItem("Check for Updates…", action: #selector(checkForUpdates(_:)))
            check.isEnabled = updates.phase != .downloading && updates.phase != .installing
            menu.addItem(check)
            menu.addItem(makeHeader("Version \(updates.installedDisplayVersion)"))
        }

        menu.addItem(.separator())
        let quitItem = makeItem("Quit MemeMe", action: #selector(quit(_:)))
        quitItem.keyEquivalent = "q"
        menu.addItem(quitItem)
    }

    private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func makeHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// `LibraryIndexer.defaultFolders()` lists Downloads, Desktop, then the screenshot folder when it differs.
    private func defaultFolderName(forPath path: String) -> String {
        if path == StatusItemController.standardPath(for: .downloadsDirectory) { return "Downloads" }
        if path == StatusItemController.standardPath(for: .desktopDirectory) { return "Desktop" }
        return "Screenshots"
    }

    private static func standardPath(for directory: FileManager.SearchPathDirectory) -> String? {
        FileManager.default.urls(for: directory, in: .userDomainMask).first?.standardizedFileURL.path
    }

    private func isCollectingPaused(_ settings: AppSettings) -> Bool {
        guard let until = settings.collectingPausedUntil else { return false }
        return until > Date()
    }

    // MARK: - Menu actions

    @objc private func openMemeMe(_ sender: Any?) {
        openPanel()
    }

    @objc private func toggleFolder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if model.indexer.isWatching(url) {
            model.indexer.removeWatchedFolder(url)
        } else {
            model.indexer.addWatchedFolders([url])
        }
    }

    @objc private func addFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Collect"
        panel.message = "Choose folders with memes. MemeMe indexes them in place; files are never copied or moved."
        NSApplication.shared.activate()
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        model.indexer.addWatchedFolders(panel.urls)
    }

    @objc private func findMemes(_ sender: Any?) {
        model.findMyMemes()
    }

    @objc private func pauseCollecting(_ sender: Any?) {
        model.indexer.pauseCollecting(for: StatusItemController.pauseInterval)
    }

    @objc private func resumeCollecting(_ sender: Any?) {
        model.indexer.resumeCollecting()
    }

    @objc private func toggleWebDiscover(_ sender: Any?) {
        var settings = model.store.settings
        settings.webDiscoverEnabled.toggle()
        model.store.settings = settings
        model.saveSoon()
    }

    @objc private func setGiphyAPIKey(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "GIPHY API Key"
        alert.informativeText = "Paste a key from developers.giphy.com to find reaction GIFs on the web. Only the mood word for your face is ever sent. Leave it empty to use the key this build came with, if any."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "API key"
        field.stringValue = model.store.settings.giphyAPIKey ?? ""
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApplication.shared.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var settings = model.store.settings
        settings.giphyAPIKey = key.isEmpty ? nil : key
        model.store.settings = settings
        model.saveSoon()
    }

    @objc private func setStickerPolicy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let policy = StickerPolicy(rawValue: raw) else { return }
        var settings = model.store.settings
        settings.stickerPolicy = policy
        model.store.settings = settings
        model.saveSoon()
    }

    @objc private func toggleGroupFaces(_ sender: Any?) {
        let enable = model.store.settings.groupFaces != true
        _ = model.friends.setGrouping(enable, batch: nil)
    }

    @objc private func forgetRestingFace(_ sender: Any?) {
        model.forgetRestingFace()
        HUDController.shared.show("Resting face forgotten. MemeMe relearns it as you go.")
    }

    @objc private func toggleOpenAtLogin(_ sender: Any?) {
        model.toggleOpenAtLogin()
    }

    @objc private func showLibrary(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([model.store.rootURL])
    }

    @objc private func installUpdate(_ sender: Any?) {
        model.installUpdate()
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        model.updates.checkFromMenu()
    }

    @objc private func quit(_ sender: Any?) {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Menu delegate

/// Forwards `menuNeedsUpdate` so the menu is rebuilt right before it opens.
private final class StatusMenuDelegate: NSObject, NSMenuDelegate {
    var onNeedsUpdate: (() -> Void)?

    func menuNeedsUpdate(_ menu: NSMenu) {
        onNeedsUpdate?()
    }
}

// MARK: - Drop target

/// Transparent view covering the status bar button that accepts dragged files, file promises, links and
/// image data.
///
/// Clicks must still reach the button underneath (it opens the menu), so `hitTest` returns nil while a
/// mouse-button event is being dispatched. Drags are different: AppKit routes a drag session to views
/// registered for dragged types, and no mouse-button event is being dispatched in this app while
/// something is dragged in from another app, so `hitTest` answers normally then and the drop lands
/// here whichever way AppKit looks up the destination. Should a click ever reach this view anyway,
/// NSView's default mouse handling passes it up the responder chain to the button.
private final class DropTargetView: NSView {
    var onDrop: (([URL]) -> Void)?

    private var isTargeted = false {
        didSet {
            if isTargeted != oldValue {
                needsDisplay = true
            }
        }
    }

    /// Photos, Mail and browsers often offer a dragged file only as a promise, which the source writes
    /// when the destination asks for it.
    private static let draggedTypes: [NSPasteboard.PasteboardType] = {
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .png, .tiff]
        types.append(contentsOf: NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        return types
    }()
    private static let imageExtensions: Set<String> = ["gif", "png", "jpg", "jpeg", "webp", "heic", "heif", "tif", "tiff", "bmp"]
    /// How old the current event may be and still count as the click being dispatched right now.
    private static let clickRecency: TimeInterval = 1
    /// Promised files are written, and reported back, on this queue.
    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.mememe.app.menu-bar-drop-promises"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(DropTargetView.draggedTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(DropTargetView.draggedTypes)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let event = NSApplication.shared.currentEvent,
           DropTargetView.isMouseButtonEvent(event.type),
           ProcessInfo.processInfo.systemUptime - event.timestamp < DropTargetView.clickRecency {
            return nil
        }
        return super.hitTest(point)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = DropTargetView.operation(for: sender)
        isTargeted = !operation.isEmpty
        return operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = DropTargetView.operation(for: sender)
        isTargeted = !operation.isEmpty
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isTargeted = false
    }

    /// Files, image links and image data first; then file promises; then any other web link
    /// (the indexer downloads it and skips it if it isn't an image).
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isTargeted = false
        let pasteboard = sender.draggingPasteboard
        let urls = DropTargetView.droppedURLs(from: pasteboard)
        if !urls.isEmpty {
            onDrop?(urls)
            return true
        }
        if receiveFilePromises(from: pasteboard) {
            return true
        }
        let links = DropTargetView.webLinks(from: pasteboard)
        guard !links.isEmpty else { return false }
        onDrop?(links)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isTargeted else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        NSColor.controlAccentColor.withAlphaComponent(0.45).setFill()
        path.fill()
    }

    /// Asks the drag's source to write its promised files into a fresh temporary folder; they are reported
    /// as one drop once they have arrived. False when the pasteboard holds no file promises.
    private func receiveFilePromises(from pasteboard: NSPasteboard) -> Bool {
        guard let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
              !receivers.isEmpty,
              let destination = DropTargetView.makeDropDirectory() else {
            return false
        }
        // The reader is called once per promised file, with an error when that file could not be written.
        let expectedCount = receivers.reduce(0) { count, receiver in
            count + max(1, receiver.fileTypes.count)
        }
        let collector = PromisedFilesCollector(expectedCount: expectedCount) { [weak self] urls in
            self?.onDrop?(urls)
        }
        for receiver in receivers {
            receiver.receivePromisedFiles(
                atDestination: destination,
                options: [:],
                operationQueue: DropTargetView.promiseQueue
            ) { @Sendable fileURL, error in
                let received: URL? = error == nil ? fileURL : nil
                Task { @MainActor in
                    collector.fileArrived(received)
                }
            }
        }
        return true
    }

    /// Press and release only: the button tracks the rest of a click itself, and drag events must never count as clicks.
    private static func isMouseButtonEvent(_ type: NSEvent.EventType) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return true
        default:
            return false
        }
    }

    private static func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        let hasURL = pasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
        let hasImage = pasteboard.availableType(from: [.png, .tiff]) != nil
        let hasPromise = pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
        return hasURL || hasImage || hasPromise ? .copy : []
    }

    /// Files first; then links that look like images; then raw image data (written to a temp file).
    private static func droppedURLs(from pasteboard: NSPasteboard) -> [URL] {
        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL], !files.isEmpty {
            return files
        }

        let imageLinks = DropTargetView.webLinks(from: pasteboard).filter { link in
            DropTargetView.imageExtensions.contains(link.pathExtension.lowercased())
        }
        if !imageLinks.isEmpty {
            return imageLinks
        }

        if let type = pasteboard.availableType(from: [.png, .tiff]),
           let data = pasteboard.data(forType: type),
           let file = writeTemporaryImage(data, fileExtension: type == .png ? "png" : "tiff") {
            return [file]
        }
        return []
    }

    /// The http(s) links on the pasteboard.
    private static func webLinks(from pasteboard: NSPasteboard) -> [URL] {
        guard let links = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else { return [] }
        return links.filter { link in
            let scheme = link.scheme?.lowercased() ?? ""
            return scheme == "http" || scheme == "https"
        }
    }

    private static func writeTemporaryImage(_ data: Data, fileExtension: String) -> URL? {
        guard !data.isEmpty else { return nil }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("MemeMeMenuBarDrops", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            let url = directory.appendingPathComponent("dropped-" + UUID().uuidString + "." + fileExtension, isDirectory: false)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// A new folder per promise drop, so promised files keep their own names without colliding.
    private static func makeDropDirectory() -> URL? {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("MemeMeMenuBarDrops", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            return directory
        } catch {
            return nil
        }
    }
}

// MARK: - File promises

/// The files of one file-promise drop arrive one by one; they are reported together once every promise
/// has answered. Should some never answer, what has arrived is reported after a pause, and anything
/// arriving later is reported on its own.
@MainActor private final class PromisedFilesCollector {
    private var outstanding: Int
    private var urls: [URL] = []
    private var isReported = false
    private var fallbackTask: Task<Void, Never>?
    private let report: ([URL]) -> Void

    /// How long to wait for the next promised file before reporting what has arrived.
    private static let fallbackNanoseconds: UInt64 = 10_000_000_000

    init(expectedCount: Int, report: @escaping ([URL]) -> Void) {
        self.outstanding = max(1, expectedCount)
        self.report = report
        scheduleFallback()
    }

    /// `url` is nil when the promised file could not be written.
    func fileArrived(_ url: URL?) {
        guard !isReported else {
            if let url {
                report([url])
            }
            return
        }
        if let url {
            urls.append(url)
        }
        outstanding -= 1
        if outstanding <= 0 {
            finish()
        } else {
            scheduleFallback()
        }
    }

    private func scheduleFallback() {
        fallbackTask?.cancel()
        // Holds the collector strongly until it fires or is cancelled, so files that did arrive are reported.
        fallbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: PromisedFilesCollector.fallbackNanoseconds)
            guard !Task.isCancelled else { return }
            self.finish()
        }
    }

    private func finish() {
        guard !isReported else { return }
        isReported = true
        fallbackTask?.cancel()
        fallbackTask = nil
        let arrived = urls
        urls = []
        if !arrived.isEmpty {
            report(arrived)
        }
    }
}
