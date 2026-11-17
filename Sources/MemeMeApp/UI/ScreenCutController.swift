import AppKit
import CoreGraphics
import MemeMeCore
import os
import SwiftUI

private let cutLog = Logger(subsystem: "com.mememe.app", category: "screen-cut")

/// What the screen cut is doing.
enum ScreenCutStatus: Equatable {
    case finding
    case ready
    case failed(String)
}

/// The screen cut (⌥S, or ✂ in the panel): the screen freezes under a dim layer, the subject under the pointer lights
/// up, and a click takes it (⇧-click adds another, ⌥-click takes one away); a box dragged around something lifts what is
/// inside it. A card beside it names the sticker, ticks the groups to file it in, and saves it to My Stickers, or copies
/// it.
@MainActor final class ScreenCutModel: ObservableObject {
    @Published private(set) var status: ScreenCutStatus = .finding
    /// What the pointer is over, lit up but not taken.
    @Published private(set) var hovered: ScreenPiece?
    /// What was taken.
    @Published private(set) var selection: ScreenPiece?
    /// The box being dragged (normalized, origin top-left).
    @Published private(set) var dragBox: CGRect?
    @Published var name: String = "" {
        didSet {
            if !isSettingName { nameEdited = true }
        }
    }
    @Published private(set) var isWorking = false
    /// How many subjects stand out on the screen (none: only a dragged box takes something).
    @Published private(set) var subjectCount = 0

    let screenshot: NSImage
    /// The app the screen was cut from, for the card and the sticker's source.
    let sourceApp: String?
    /// Your groups, the latest used first: chips on the card.
    let groups: [StickerGroup]
    /// The groups Save files the sticker in.
    @Published private(set) var tickedGroupIDs: Set<UUID> = []
    /// Groups named on the card (+), ticked: made when it is saved.
    @Published private(set) var newGroupNames: [String] = []
    /// The name being typed for a new group; nil while + isn't open.
    @Published var groupDraft: String?

    /// The piece, its name, the ticked groups and the new groups' names.
    var onSave: ((ScreenPiece, String, Set<UUID>, [String]) -> Void)?
    var onCopy: ((ScreenPiece) -> Void)?
    var onCancel: (() -> Void)?

    private var subjects: ScreenSubjects?
    private var selectedInstances = IndexSet()
    private var hoveredInstance: Int?
    private var pieces: [IndexSet: ScreenPiece] = [:]
    private var nameEdited = false
    private var isSettingName = false
    private var generation = 0

    init(image: CGImage, sourceApp: String?, groups: [StickerGroup] = []) {
        screenshot = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        self.sourceApp = sourceApp
        self.groups = groups
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { ScreenSubjects(image: image) }.value
            guard let self else { return }
            self.subjects = found
            self.subjectCount = found.instanceCount
            self.status = .ready
        }
    }

    // MARK: Pointer

    func hover(at point: CGPoint) {
        guard status == .ready, dragBox == nil, let subjects else { return }
        let instance = subjects.instance(at: point)
        guard instance != hoveredInstance else { return }
        hoveredInstance = instance
        guard let instance, !selectedInstances.contains(instance) else {
            hovered = nil
            return
        }
        piece(for: IndexSet(integer: instance)) { [weak self] piece in
            guard let self, self.hoveredInstance == instance else { return }
            self.hovered = piece
        }
    }

    /// A click: takes the subject under it (⇧ adds it, ⌥ takes it away); on the background, nothing is taken.
    func click(at point: CGPoint, adding: Bool, removing: Bool) {
        guard status == .ready, let subjects else { return }
        guard let instance = subjects.instance(at: point) else {
            if !adding && !removing { clearSelection() }
            return
        }
        var wanted = (adding || removing) ? selectedInstances : IndexSet()
        if removing {
            wanted.remove(instance)
        } else {
            wanted.insert(instance)
        }
        select(wanted)
    }

    func drag(from start: CGPoint, to end: CGPoint) {
        guard status == .ready else { return }
        dragBox = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                         width: abs(end.x - start.x), height: abs(end.y - start.y))
        hovered = nil
        hoveredInstance = nil
    }

    /// A box let go: the subjects inside it, or the box itself.
    func endDrag() {
        guard let box = dragBox, let subjects else {
            dragBox = nil
            return
        }
        dragBox = nil
        guard box.width > 0.005, box.height > 0.005 else { return }
        selectedInstances = IndexSet()
        generation += 1
        let current = generation
        isWorking = true
        Task { [weak self] in
            let piece = await Task.detached(priority: .userInitiated) { try? subjects.piece(inBox: box) }.value
            guard let self, current == self.generation else { return }
            self.isWorking = false
            self.setSelection(piece)
        }
    }

    func save() {
        guard let selection, !isWorking else { return }
        onSave?(selection, name, tickedGroupIDs, newGroupNames)
    }

    // MARK: Groups

    func toggleGroup(_ id: UUID) {
        if tickedGroupIDs.contains(id) {
            tickedGroupIDs.remove(id)
        } else {
            tickedGroupIDs.insert(id)
        }
    }

    /// A group named on the card, clicked again: it won't be made.
    func removeNewGroup(named name: String) {
        newGroupNames.removeAll { $0 == name }
    }

    /// + on the card: a field for the new group's name.
    func beginGroupDraft() {
        if groupDraft == nil { groupDraft = "" }
    }

    /// ↩ in the new group's field: the name is ticked (an existing group's name ticks that group).
    func commitGroupDraft() {
        guard let draft = groupDraft else { return }
        groupDraft = nil
        guard let name = StickerGroup.cleanName(draft) else { return }
        let matches: (String) -> Bool = { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        if let existing = groups.first(where: { matches($0.name) }) {
            tickedGroupIDs.insert(existing.id)
        } else if !newGroupNames.contains(where: matches) {
            newGroupNames.append(name)
        }
    }

    func cancelGroupDraft() {
        groupDraft = nil
    }

    func copy() {
        guard let selection, !isWorking else { return }
        onCopy?(selection)
    }

    func cancel() {
        onCancel?()
    }

    // MARK: Private

    private func clearSelection() {
        generation += 1
        selectedInstances = IndexSet()
        selection = nil
        isWorking = false
    }

    private func select(_ instances: IndexSet) {
        selectedInstances = instances
        generation += 1
        guard !instances.isEmpty else {
            selection = nil
            return
        }
        let current = generation
        isWorking = true
        if hoveredInstance.map({ instances.contains($0) }) == true { hovered = nil }
        piece(for: instances) { [weak self] piece in
            guard let self, current == self.generation else { return }
            self.isWorking = false
            self.setSelection(piece)
        }
    }

    private func setSelection(_ piece: ScreenPiece?) {
        selection = piece
        guard let piece, !nameEdited else { return }
        Task { [weak self] in
            let suggested = await Task.detached(priority: .utility) { ScreenSubjects.suggestedName(for: piece) }.value
            guard let self, !self.nameEdited, self.selection?.cutout === piece.cutout else { return }
            self.isSettingName = true
            self.name = suggested ?? "Sticker"
            self.isSettingName = false
        }
    }

    private func piece(for instances: IndexSet, then deliver: @escaping @MainActor (ScreenPiece?) -> Void) {
        if let cached = pieces[instances] {
            deliver(cached)
            return
        }
        guard let subjects else { return }
        Task { [weak self] in
            let piece = await Task.detached(priority: .userInitiated) { try? subjects.piece(forInstances: instances) }.value
            if let piece { self?.pieces[instances] = piece }
            deliver(piece)
        }
    }
}

/// A borderless panel over the whole screen that takes the keyboard without activating MemeMe.
private final class ScreenCutPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Opens the screen cut over the screen the pointer is on and closes it when the sticker is saved, copied, or
/// cancelled (Esc).
@MainActor final class ScreenCutController {
    private let model: AppModel
    private var panel: ScreenCutPanel?
    private var cut: ScreenCutModel?
    private var keyMonitor: Any?
    private var isStarting = false

    init(model: AppModel) {
        self.model = model
    }

    var isOpen: Bool { panel != nil }

    /// Groups offered on the card: the latest used.
    private static let groupLimit = 8

    /// Asks for Screen Recording access the first time (macOS then asks you to allow it in System Settings).
    func start() {
        guard panel == nil, !isStarting else { return }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            HUDController.shared.show("Allow MemeMe to record the screen in System Settings › Privacy & Security, then press ⌥S again.")
            return
        }
        isStarting = true
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            isStarting = false
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let sourceApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? nil : frontmost?.localizedName
        Task { [weak self] in
            // The panel (if open) is ordered out first, so the screenshot is of what is under it.
            try? await Task.sleep(nanoseconds: 120_000_000)
            do {
                let image = try await ScreenSubjects.capture(screen)
                self?.present(image, on: screen, sourceApp: sourceApp)
            } catch {
                cutLog.error("Capturing the screen failed: \(error.localizedDescription, privacy: .public)")
                HUDController.shared.show("Couldn’t capture the screen. Check Screen Recording in System Settings.")
            }
            self?.isStarting = false
        }
    }

    private func present(_ image: CGImage, on screen: NSScreen, sourceApp: String?) {
        let groups = model.store.recents.recentGroups(limit: ScreenCutController.groupLimit)
        let cut = ScreenCutModel(image: image, sourceApp: sourceApp, groups: groups)
        cut.onCancel = { [weak self] in self?.close() }
        cut.onCopy = { [weak self] piece in self?.copy(piece) }
        cut.onSave = { [weak self] piece, name, groupIDs, newGroups in
            self?.save(piece, name: name, sourceApp: sourceApp, groupIDs: groupIDs, newGroupNames: newGroups)
        }
        let panel = ScreenCutPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ScreenCutView(cut: cut))
        panel.setFrame(screen.frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        self.cut = cut
        self.panel = panel
        installKeyMonitor()
    }

    func close() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
        cut = nil
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let cut = self.cut, event.window === self.panel else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            switch event.keyCode {
            case 53 where cut.groupDraft != nil:       // Esc while naming a group: just the name goes
                cut.cancelGroupDraft()
                return nil
            case 53:                                   // Esc
                cut.cancel()
                return nil
            case 36 where cut.groupDraft != nil, 76 where cut.groupDraft != nil:   // ↵ names the group
                cut.commitGroupDraft()
                return nil
            case 36, 76:                               // ↵
                cut.save()
                return nil
            case 8 where flags == .command:            // ⌘C
                guard cut.selection != nil else { return event }
                cut.copy()
                return nil
            default:
                return event
            }
        }
    }

    private func copy(_ piece: ScreenPiece) {
        close()
        do {
            let png = try ScreenSubjects.stickerPNG(of: piece)
            let url = try Clipboard.copy(data: png, fileName: "sticker.png")
            HUDController.shared.showCopied(thumbnail: url)
        } catch {
            HUDController.shared.show("Couldn’t copy that one. Try again.")
        }
    }

    private func save(_ piece: ScreenPiece, name: String, sourceApp: String?, groupIDs: Set<UUID>,
                      newGroupNames: [String]) {
        close()
        let friends = model.friends
        let model = self.model
        Task {
            do {
                let png = try ScreenSubjects.stickerPNG(of: piece)
                let made = try await friends.makeScreenSticker(png: png, name: name, sourceApp: sourceApp)
                // Filed in the ticked groups even when it was already one of your stickers.
                let filed = model.fileSticker(made.item.id, inGroups: groupIDs, newGroupNames: newGroupNames)
                guard made.isNew else {
                    HUDController.shared.show(filed.isEmpty ? "Already one of your stickers"
                                                            : "Already one of your stickers · in \(ScreenCutController.list(filed))",
                                              thumbnail: made.item.fileURL)
                    return
                }
                let undo = HUDAction(title: "Undo") {
                    friends.removeOwnSticker(id: made.item.id)
                    HUDController.shared.show("Sticker removed")
                }
                let place = filed.isEmpty ? "My Stickers" : ScreenCutController.list(filed)
                HUDController.shared.show("Saved “\(made.item.displayName)” to \(place)",
                                          thumbnail: made.item.fileURL, action: undo)
            } catch {
                cutLog.error("Saving a screen sticker failed: \(error.localizedDescription, privacy: .public)")
                HUDController.shared.show("Couldn’t save that sticker. Try again.")
            }
        }
    }
}

extension ScreenCutController {
    /// "Cats", "Cats and Work", "3 groups".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names.count) groups"
        }
    }
}

// MARK: - The view

/// The frozen screen, dimmed; the subject under the pointer and the one taken lit up with an outline in the signal
/// color; the hint hanging from the top; the card beside what was taken.
private struct ScreenCutView: View {
    @ObservedObject var cut: ScreenCutModel

    @State private var dragStart: CGPoint?
    @FocusState private var nameFocused: Bool
    @FocusState private var groupDraftFocused: Bool

    init(cut: ScreenCutModel) {
        _cut = ObservedObject(wrappedValue: cut)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                canvas(size: size)
                if let hovered = cut.hovered {
                    pieceView(hovered, size: size)
                        .opacity(0.85)
                        .allowsHitTesting(false)
                }
                if let selection = cut.selection {
                    pieceView(selection, size: size)
                        .allowsHitTesting(false)
                }
                if let box = cut.dragBox {
                    Rectangle()
                        .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .frame(width: box.width * size.width, height: box.height * size.height)
                        .offset(x: box.minX * size.width, y: box.minY * size.height)
                        .allowsHitTesting(false)
                }
                hint
                    .frame(width: size.width, alignment: .top)
                if let selection = cut.selection {
                    card(for: selection)
                        .offset(cardOffset(for: selection, in: size))
                }
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    /// The screen, dimmed; it takes the pointer.
    private func canvas(size: CGSize) -> some View {
        ZStack {
            Image(nsImage: cut.screenshot)
                .resizable()
                .interpolation(.high)
            Color.black.opacity(0.55)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            NSCursor.crosshair.set()
            if case let .active(location) = phase {
                cut.hover(at: normalized(location, in: size))
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStart == nil { dragStart = value.startLocation }
                    let distance = hypot(value.translation.width, value.translation.height)
                    if distance > 6 {
                        cut.drag(from: normalized(value.startLocation, in: size), to: normalized(value.location, in: size))
                    }
                }
                .onEnded { value in
                    dragStart = nil
                    if cut.dragBox != nil {
                        cut.endDrag()
                    } else {
                        let flags = NSEvent.modifierFlags
                        cut.click(at: normalized(value.location, in: size), adding: flags.contains(.shift),
                                  removing: flags.contains(.option))
                    }
                }
        )
        .accessibilityLabel("Your screen. Click what you want as a sticker, or drag a box around it.")
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: size.width > 0 ? point.x / size.width : 0, y: size.height > 0 ? point.y / size.height : 0)
    }

    /// A piece where it sits on the screen: its outline under it, the cut-out on top.
    private func pieceView(_ piece: ScreenPiece, size: CGSize) -> some View {
        let scale = size.width / max(1, cut.screenshot.size.width)
        let frame = CGRect(x: piece.rect.minX * size.width, y: piece.rect.minY * size.height,
                           width: piece.rect.width * size.width, height: piece.rect.height * size.height)
        let outlineWidth = CGFloat(piece.outline.width) * scale
        let outlineHeight = CGFloat(piece.outline.height) * scale
        return ZStack(alignment: .topLeading) {
            Image(decorative: piece.outline, scale: 1)
                .resizable()
                .frame(width: outlineWidth, height: outlineHeight)
                .offset(x: frame.minX - (outlineWidth - frame.width) / 2, y: frame.minY - (outlineHeight - frame.height) / 2)
            Image(decorative: piece.cutout, scale: 1)
                .resizable()
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
        }
    }

    /// Hangs from the top of the screen: what to do, and the keys.
    private var hint: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "scissors")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.accent)
                Text(verbatim: hintText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.text)
            }
            HStack(spacing: 12) {
                keyHint(["⇧"], "click to add")
                keyHint(["⌥"], "click to remove")
                keyHint(["esc"], "cancel")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 34)
        .padding(.bottom, 14)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20, style: .continuous)
                .fill(Color.black)
        )
        .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
    }

    private var hintText: String {
        switch cut.status {
        case .finding: return "Finding what’s on your screen…"
        case .ready:
            return cut.subjectCount == 0
                ? "Drag a box around what you want as a sticker"
                : "Click what you want as a sticker, or drag a box around it"
        case let .failed(message): return message
        }
    }

    private func keyHint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 5) {
            ForEach(keys, id: \.self) { Keycap($0) }
            Text(verbatim: label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.mutedText)
        }
    }

    // MARK: Card

    private static let cardSize = CGSize(width: 260, height: 420)

    private func card(for piece: ScreenPiece) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("New sticker")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.mutedText)
                Spacer()
                if let app = cut.sourceApp {
                    Text(verbatim: "from \(app)")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.mutedText)
                        .lineLimit(1)
                }
            }
            ZStack {
                Checkerboard()
                Image(decorative: piece.cutout, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(14)
                    .shadow(color: .white, radius: 0.8)
                    .shadow(color: .white, radius: 0.8)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                if cut.isWorking {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 176)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text("Name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.mutedText)
                TextField("", text: $cut.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.text)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.glassFill))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.glassEdge, lineWidth: 1))
                    .focused($nameFocused)
                    .accessibilityLabel("Sticker name")
            }
            groupRow
            HStack(spacing: 8) {
                Button {
                    cut.save()
                } label: {
                    HStack(spacing: 8) {
                        Text("Save")
                            .font(.system(size: 13, weight: .semibold))
                        Text(verbatim: "↩")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 5)
                            .frame(height: 18)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.14)))
                    }
                    .foregroundColor(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.accent))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(cut.isWorking)
                Button {
                    cut.copy()
                } label: {
                    HStack(spacing: 6) {
                        Text("Copy")
                            .font(.system(size: 13, weight: .medium))
                        Text(verbatim: "⌘C")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.softTitle)
                    }
                    .foregroundColor(Theme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.glassFillStrong))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(cut.isWorking)
            }
        }
        .padding(14)
        .frame(width: ScreenCutView.cardSize.width)
        .glass(cornerRadius: 16, shadow: false)
        .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
        .onAppear { nameFocused = true }
    }

    /// The groups Save files the sticker in: your latest used, those named here (+), then + for another.
    private var groupRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Group")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.mutedText)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(cut.groups) { group in
                    let ticked = cut.tickedGroupIDs.contains(group.id)
                    Button {
                        cut.toggleGroup(group.id)
                    } label: {
                        GroupChipLabel(title: group.name, isOn: ticked, ticks: true, compact: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(ticked ? .isSelected : [])
                }
                ForEach(cut.newGroupNames, id: \.self) { name in
                    Button {
                        cut.removeNewGroup(named: name)
                    } label: {
                        GroupChipLabel(title: name, isOn: true, ticks: true, compact: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isSelected)
                }
                if cut.groupDraft == nil {
                    Button {
                        cut.beginGroupDraft()
                    } label: {
                        NewGroupChipLabel(title: cut.groups.isEmpty && cut.newGroupNames.isEmpty ? "New group" : nil,
                                          compact: true)
                    }
                    .buttonStyle(.plain)
                    .help("New group")
                    .accessibilityLabel("New group")
                }
            }
            if cut.groupDraft != nil {
                TextField("Group name, then ↩", text: Binding(get: { cut.groupDraft ?? "" },
                                                              set: { cut.groupDraft = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.text)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(Theme.glassFill))
                    .overlay(Capsule().strokeBorder(Theme.glassEdge, lineWidth: 1))
                    .focused($groupDraftFocused)
                    .onAppear { groupDraftFocused = true }
                    .accessibilityLabel("New group name")
            }
        }
    }

    /// Beside what was taken: on its right when there is room, else on its left; kept on screen.
    private func cardOffset(for piece: ScreenPiece, in size: CGSize) -> CGSize {
        let card = ScreenCutView.cardSize
        let frame = CGRect(x: piece.rect.minX * size.width, y: piece.rect.minY * size.height,
                           width: piece.rect.width * size.width, height: piece.rect.height * size.height)
        var x = frame.maxX + 24
        if x + card.width > size.width - 16 {
            x = frame.minX - 24 - card.width
        }
        x = min(max(16, x), size.width - card.width - 16)
        let y = min(max(90, frame.midY - card.height / 2), size.height - card.height - 16)
        return CGSize(width: x, height: y)
    }
}

/// The transparent-background checkerboard behind a sticker.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 7
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.checkerDark))
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : cell
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(Theme.checkerLight))
                    x += 2 * cell
                }
                y += cell
                row += 1
            }
        }
        .accessibilityHidden(true)
    }
}
