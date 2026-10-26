import Combine
import Foundation
import MemeMeCore
import os

private let popoverLog = Logger(subsystem: "com.mememe.app", category: "stickers")

/// Source photos of sticker batches that combine several dropped photos, so "Keep as photo only" keeps all of them.
/// A batch made from one photo needs no entry: its `sourceURL` is the photo.
@MainActor enum StickerBatchSources {
    private static var sourcesByBatch: [UUID: [URL]] = [:]

    static func register(_ urls: [URL], for batchID: UUID) {
        sourcesByBatch[batchID] = urls
    }

    static func sources(for batch: StickerBatch) -> [URL] {
        sourcesByBatch[batch.id] ?? [batch.sourceURL]
    }

    static func forget(_ batchID: UUID) {
        sourcesByBatch[batchID] = nil
    }
}

/// State of the popover under the menu-bar icon after a drop: made stickers, or kept memes.
@MainActor final class StickerPopoverModel: ObservableObject {
    @Published var stickerBatch: StickerBatch?
    @Published var keptBatch: IndexBatch?
    @Published private(set) var askGrouping: Bool = false

    let friends: FriendService
    let indexer: LibraryIndexer
    var onClose: (() -> Void)?

    /// Set by the app delegate so "Keep as photo only" can file the photo as a maybe-tier item
    /// (found by typed search, never offered as a face reaction).
    var store: LibraryStore?

    private var isKeepingPhoto = false

    private static let keptSource = "Kept"

    init(friends: FriendService, indexer: LibraryIndexer) {
        self.friends = friends
        self.indexer = indexer
    }

    func present(stickers: StickerBatch) {
        stickerBatch = stickers
        keptBatch = nil
        // The consent question is asked once, the first time stickers are made.
        askGrouping = friends.needsGroupingConsent && !stickers.undone && !stickers.stickers.isEmpty
    }

    func present(kept: IndexBatch) {
        keptBatch = kept
        stickerBatch = nil
        askGrouping = false
    }

    func groupYes() {
        stickerBatch = friends.setGrouping(true, batch: stickerBatch)
        askGrouping = false
    }

    func groupNo() {
        _ = friends.setGrouping(false, batch: stickerBatch)
        askGrouping = false
    }

    /// The popover closed (outside click, idle timeout) with "Group stickers by person?" unanswered: that
    /// counts as "Not now", so the question is asked only once. The menu can still turn grouping on.
    func dismissGroupingQuestionIfUnanswered() {
        guard askGrouping else { return }
        groupNo()
    }

    func confirm(stickerID: UUID, personID: UUID) {
        guard let batch = stickerBatch else { return }
        stickerBatch = friends.confirm(stickerID: stickerID, personID: personID, in: batch)
    }

    func toggle(stickerID: UUID) {
        guard let batch = stickerBatch else { return }
        stickerBatch = friends.toggleRemoved(stickerID: stickerID, in: batch)
    }

    func undoAll() {
        guard let batch = stickerBatch, !batch.undone else { return }
        stickerBatch = friends.undo(batch)
        askGrouping = false
    }

    /// Undoes the stickers and keeps the photo as a normal (maybe-tier) item via `indexer.keep`.
    func keepAsPhotoOnly() {
        guard let batch = stickerBatch, !isKeepingPhoto else { return }
        isKeepingPhoto = true
        let photos = StickerBatchSources.sources(for: batch)
        StickerBatchSources.forget(batch.id)
        stickerBatch = batch.undone ? batch : friends.undo(batch)
        askGrouping = false

        Task { [weak self] in
            guard let self else { return }
            let kept = await self.indexer.keep(urls: photos, source: StickerPopoverModel.keptSource)
            self.fileAsMaybe(kept.addedIDs)
            self.isKeepingPhoto = false
            self.keptBatch = kept
            self.stickerBatch = nil
        }
    }

    func undoKept() {
        guard let batch = keptBatch else { return }
        indexer.undo(batch)
        keptBatch = nil
        if stickerBatch == nil {
            close()
        }
    }

    func close() {
        onClose?()
    }

    /// A photo of people kept on purpose is searchable by words but never offered as a face reaction.
    private func fileAsMaybe(_ ids: [UUID]) {
        guard let store = store, !ids.isEmpty else { return }
        var changed = false
        for id in ids {
            guard var item = store.item(id: id), item.tier == .meme else { continue }
            item.tier = .maybe
            store.update(item)
            changed = true
        }
        guard changed else { return }
        do {
            try store.save()
        } catch {
            popoverLog.error("Saving the library failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
