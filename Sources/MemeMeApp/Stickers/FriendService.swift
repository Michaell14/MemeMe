import Combine
import Foundation
import MemeMeCore
import os

private let friendLog = Logger(subsystem: "com.mememe.app", category: "friends")

struct MadeSticker: Identifiable, Equatable {
    let id: UUID              // the sticker's LibraryItem id
    var fileURL: URL
    var match: PersonMatch
    var personName: String?   // for .confident / .likely
    var removed: Bool
}

struct StickerBatch: Identifiable, Equatable {
    let id: UUID
    let sourceURL: URL
    var stickers: [MadeSticker]
    var skippedFaces: Int     // detected faces below the size threshold
    var undone: Bool
}

/// Off-main sticker work handed back to the main actor (plain values and file URLs only).
private struct StickerWorkResult: @unchecked Sendable {
    let facts: ImageFacts
    let eligibleCount: Int
    let cuts: [StickerCut]
}

/// The cut of a camera capture, handed back to the main actor.
private struct OwnStickerWork: @unchecked Sendable {
    let cut: StickerCut
    let pose: PoseFeatures?
}

/// A sticker removed with ×, kept in memory so + can restore it.
private struct RemovedSticker {
    let item: LibraryItem
    let pngData: Data?
    /// The person record as it was, when removing the sticker also removed its (unnamed, now empty) person.
    let removedPerson: Person?
}

/// What one `process(photo:)` call returned. A batch can list stickers that already existed
/// (the same cut was made from an earlier photo); only `createdIDs` belong to it.
private struct BatchRecord {
    let batchID: UUID
    let sourceURL: URL
    let stickerIDs: Set<UUID>
    let createdIDs: Set<UUID>
}

/// Turns dropped photos of people into friend stickers and, only with consent, groups them by person.
/// Face embeddings are compared against the user's own earlier stickers only and never leave the Mac.
@MainActor final class FriendService: ObservableObject {
    private let store: LibraryStore
    private let matcher = FriendMatcher()
    private var removedStickers: [UUID: RemovedSticker] = [:]
    /// Batches made by `process(photo:)`, oldest first, so `undo` removes only stickers they created.
    private var batchRecords: [BatchRecord] = []

    private static let maximumBatchRecords = 1000

    init(store: LibraryStore) {
        self.store = store
    }

    var needsGroupingConsent: Bool {
        store.settings.groupFaces == nil
    }

    /// nil when the file isn't a photo of people (caller keeps it as a meme) or the policy is .never.
    /// Under `.ask` the caller asks the user before calling this; a call means the user said yes.
    func process(photo url: URL) async throws -> StickerBatch? {
        guard store.settings.stickerPolicy != .never else { return nil }
        let directory = store.stickersDirectory

        let work = try await Task.detached(priority: .userInitiated) { () async throws -> StickerWorkResult? in
            let eligible = try StickerMaker.eligibleFaces(in: url)
            guard !eligible.faces.isEmpty else { return nil }
            let cuts = try StickerMaker.makeStickers(from: url, into: directory, faces: eligible.faces)
            return StickerWorkResult(facts: eligible.facts, eligibleCount: eligible.faces.count, cuts: cuts)
        }.value
        guard let work = work, !work.cuts.isEmpty else { return nil }

        let grouping = store.settings.groupFaces == true
        let sourceName = url.lastPathComponent
        var stickers: [MadeSticker] = []
        var created = Set<UUID>()

        for cut in work.cuts {
            let embedding: [Float]? = cut.faceEmbedding.isEmpty ? nil : cut.faceEmbedding
            let item = LibraryItem(
                fileURL: cut.pngURL,
                displayName: FriendService.displayName(personName: nil, face: cut.face, shape: cut.faceShape),
                kind: .friend,
                tier: .meme,
                source: "Friend sticker",
                sourceDetail: sourceName.isEmpty ? nil : sourceName,
                fileSize: FriendService.fileSize(of: cut.pngURL),
                contentHash: cut.contentHash,
                isSticker: true,
                isAnimated: false,
                face: cut.face,
                pose: nil,
                intensity: cut.intensity,
                featurePrint: cut.featurePrint,
                featurePrintRevision: cut.featurePrint == nil ? 0 : ImageAnalyzer.featurePrintRevision,
                text: "",
                labels: [],
                faceEmbedding: embedding,
                faceShape: cut.faceShape,
                faceRevision: LibraryItem.currentFaceRevision
            )

            if store.add(item) {
                created.insert(item.id)
                var made = MadeSticker(id: item.id, fileURL: item.fileURL, match: .newFace, personName: nil, removed: false)
                if grouping {
                    let result = assignPerson(toItemID: item.id)
                    made.match = result.match
                    made.personName = result.personName
                }
                stickers.append(made)
            } else {
                // The same sticker was made before: drop the new file and show the existing one.
                try? FileManager.default.removeItem(at: cut.pngURL)
                if let existing = store.items.first(where: { $0.contentHash == cut.contentHash }),
                   !stickers.contains(where: { $0.id == existing.id }) {
                    stickers.append(madeSticker(for: existing))
                }
            }
        }
        guard !stickers.isEmpty else { return nil }

        saveStore()
        let batch = StickerBatch(
            id: UUID(),
            sourceURL: url,
            stickers: stickers,
            skippedFaces: max(0, work.facts.faceCount - work.eligibleCount),
            undone: false
        )
        batchRecords.append(BatchRecord(
            batchID: batch.id,
            sourceURL: url,
            stickerIDs: Set(stickers.map { $0.id }),
            createdIDs: created
        ))
        if batchRecords.count > FriendService.maximumBatchRecords {
            batchRecords.removeFirst(batchRecords.count - FriendService.maximumBatchRecords)
        }
        return batch
    }

    /// "Save as sticker" on a camera capture: your face (the largest one) cut out as a die-cut sticker, kept as one
    /// of your own memes (source "Camera"). No sticker policy, size rule or grouping: it's you, saved on purpose.
    /// nil when no face or person could be cut out. A capture saved before returns that sticker.
    func makeOwnSticker(fromCapture url: URL) async throws -> (item: LibraryItem, isNew: Bool)? {
        let directory = store.stickersDirectory
        let work = try await Task.detached(priority: .userInitiated) { () async throws -> OwnStickerWork? in
            let analysis = try ImageAnalyzer.analyze(url: url, includeText: false)
            guard let face = analysis.faceBoxes.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
            guard let cut = try StickerMaker.makeStickers(from: url, into: directory, faces: [face]).first else { return nil }
            return OwnStickerWork(cut: cut, pose: analysis.pose)
        }.value
        guard let work else { return nil }
        let cut = work.cut
        let mood = MoodClassifier.mood(for: cut.face, pose: work.pose, shape: cut.faceShape, baseline: RestingBaseline())
        let item = LibraryItem(
            fileURL: cut.pngURL,
            displayName: "You — " + mood.label,
            kind: .mine,
            tier: .meme,
            source: "Camera",
            fileSize: FriendService.fileSize(of: cut.pngURL),
            contentHash: cut.contentHash,
            isSticker: true,
            isAnimated: false,
            face: cut.face,
            pose: work.pose,
            poseRevision: LibraryItem.currentPoseRevision,
            intensity: cut.intensity,
            featurePrint: cut.featurePrint,
            featurePrintRevision: cut.featurePrint == nil ? 0 : ImageAnalyzer.featurePrintRevision,
            faceShape: cut.faceShape,
            faceRevision: LibraryItem.currentFaceRevision
        )
        guard store.add(item) else {
            try? FileManager.default.removeItem(at: cut.pngURL)
            return store.items.first(where: { $0.contentHash == cut.contentHash }).map { (item: $0, isNew: false) }
        }
        saveStore()
        return (item: item, isNew: true)
    }

    /// Undo for Save as sticker: forgets the sticker and deletes its file.
    func removeOwnSticker(id: UUID) {
        store.remove(ids: [id])
        saveStore()
    }

    /// Persists consent. When enabled, matches the batch's stickers (and earlier unmatched stickers) and returns the updated batch.
    func setGrouping(_ enabled: Bool, batch: StickerBatch?) -> StickerBatch? {
        var settings = store.settings
        settings.groupFaces = enabled
        store.settings = settings
        guard enabled else {
            saveStore()
            return batch
        }

        let batchIDs = Set(batch?.stickers.map { $0.id } ?? [])
        let earlier = store.items
            .filter { $0.isSticker && $0.kind == .friend && $0.personID == nil && $0.faceEmbedding != nil && !batchIDs.contains($0.id) }
            .sorted { $0.addedAt < $1.addedAt }
        for item in earlier {
            assignPerson(toItemID: item.id)
        }

        guard var updated = batch else {
            saveStore()
            return nil
        }
        if !updated.undone {
            for index in updated.stickers.indices where !updated.stickers[index].removed {
                let stickerID = updated.stickers[index].id
                // Already assigned (a sticker that existed before this batch): keep what the batch shows.
                guard let item = store.item(id: stickerID), item.personID == nil else { continue }
                let result = assignPerson(toItemID: stickerID)
                updated.stickers[index].match = result.match
                updated.stickers[index].personName = result.personName
            }
        }
        saveStore()
        return updated
    }

    func confirm(stickerID: UUID, personID: UUID, in batch: StickerBatch) -> StickerBatch {
        var updated = batch
        guard var item = store.item(id: stickerID), var person = findPerson(id: personID) else { return updated }

        let previousPersonID = item.personID
        if let embedding = item.faceEmbedding, !embedding.isEmpty, !person.embeddings.contains(embedding) {
            person.addEmbedding(embedding)
            store.upsert(person)
        }
        item.personID = personID
        item.displayName = FriendService.displayName(personName: person.name, face: item.face, shape: item.faceShape)
        store.update(item)
        if let previous = previousPersonID, previous != personID {
            detach(embedding: item.faceEmbedding, fromPerson: previous)
        }

        if let index = updated.stickers.firstIndex(where: { $0.id == stickerID }) {
            updated.stickers[index].match = .confident(personID)
            updated.stickers[index].personName = person.name
        }
        saveStore()
        return updated
    }

    /// Removing deletes the item and its file; restoring re-adds it.
    func toggleRemoved(stickerID: UUID, in batch: StickerBatch) -> StickerBatch {
        var updated = batch
        guard !updated.undone, let index = updated.stickers.firstIndex(where: { $0.id == stickerID }) else { return updated }

        if updated.stickers[index].removed {
            guard let record = removedStickers[stickerID], restore(record) else { return updated }
            removedStickers[stickerID] = nil
            updated.stickers[index].removed = false
            if let restored = store.item(id: stickerID) {
                updated.stickers[index].fileURL = restored.fileURL
            }
        } else {
            if let item = store.item(id: stickerID) {
                removedStickers[stickerID] = removeSticker(item)
            }
            updated.stickers[index].removed = true
        }
        saveStore()
        return updated
    }

    /// Removes all of the batch's stickers. Stickers that existed before the batch (an earlier photo made
    /// the same cut) are left in the library; a sticker whose origin can't be established is never deleted.
    func undo(_ batch: StickerBatch) -> StickerBatch {
        var updated = batch
        guard !updated.undone else { return updated }
        let parts = records(behind: batch)
        var created = Set<UUID>()
        for record in parts {
            created.formUnion(record.createdIDs)
        }

        for index in updated.stickers.indices {
            let stickerID = updated.stickers[index].id
            removedStickers[stickerID] = nil
            if !updated.stickers[index].removed, created.contains(stickerID), let item = store.item(id: stickerID) {
                _ = removeSticker(item)
            }
            updated.stickers[index].removed = true
        }
        updated.undone = true
        let finished = Set(parts.map { $0.batchID })
        batchRecords.removeAll { finished.contains($0.batchID) }
        saveStore()
        return updated
    }

    func unnamedPeople(limit: Int) -> [(person: Person, stickerCount: Int, sample: LibraryItem?)] {
        guard limit > 0 else { return [] }
        var counts: [UUID: Int] = [:]
        var samples: [UUID: LibraryItem] = [:]
        for item in store.items where item.isSticker {
            guard let personID = item.personID else { continue }
            counts[personID, default: 0] += 1
            if let current = samples[personID], current.addedAt >= item.addedAt { continue }
            samples[personID] = item
        }

        let unnamed = store.people.filter { FriendService.isUnnamed($0) && (counts[$0.id] ?? 0) > 0 }
        let sorted = unnamed.sorted { first, second in
            let firstCount = counts[first.id] ?? 0
            let secondCount = counts[second.id] ?? 0
            if firstCount != secondCount { return firstCount > secondCount }
            return first.createdAt > second.createdAt
        }
        return sorted.prefix(limit).map { person in
            (person: person, stickerCount: counts[person.id] ?? 0, sample: samples[person.id])
        }
    }

    func name(personID: UUID, as name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var person = findPerson(id: personID) else { return }
        person.name = trimmed
        store.upsert(person)
        for item in store.items where item.personID == personID {
            var renamed = item
            renamed.displayName = FriendService.displayName(personName: trimmed, face: item.face, shape: item.faceShape)
            store.update(renamed)
        }
        saveStore()
    }

    /// Removes the person's embeddings and unlinks stickers (their face embeddings are dropped too, so they are not regrouped).
    func forget(personID: UUID) {
        let stickerIDs = store.items.filter { $0.personID == personID }.map { $0.id }
        store.removePerson(id: personID)
        for stickerID in stickerIDs {
            guard var item = store.item(id: stickerID) else { continue }
            item.personID = nil
            item.faceEmbedding = nil
            item.displayName = FriendService.displayName(personName: nil, face: item.face, shape: item.faceShape)
            store.update(item)
        }
        saveStore()
    }

    // MARK: - Matching

    /// Matches one sticker against the people built from earlier stickers.
    /// `.confident` assigns it (and learns the embedding); `.likely` waits for `confirm`; `.newFace` creates an unnamed person.
    @discardableResult
    private func assignPerson(toItemID itemID: UUID) -> (match: PersonMatch, personName: String?) {
        guard var item = store.item(id: itemID), let embedding = item.faceEmbedding, !embedding.isEmpty else {
            return (match: .newFace, personName: nil)
        }
        let candidates = store.people.filter { !$0.embeddings.isEmpty }
        let match = matcher.match(embedding, among: candidates)

        switch match {
        case .confident(let personID):
            guard var person = findPerson(id: personID) else { return (match: .newFace, personName: nil) }
            person.addEmbedding(embedding)
            store.upsert(person)
            item.personID = personID
            item.displayName = FriendService.displayName(personName: person.name, face: item.face, shape: item.faceShape)
            store.update(item)
            return (match: match, personName: person.name)
        case .likely(let personID, _):
            return (match: match, personName: findPerson(id: personID)?.name)
        case .newFace:
            let person = Person(embeddings: [embedding])
            store.upsert(person)
            item.personID = person.id
            item.displayName = FriendService.displayName(personName: nil, face: item.face, shape: item.faceShape)
            store.update(item)
            return (match: .newFace, personName: nil)
        }
    }

    private func madeSticker(for item: LibraryItem) -> MadeSticker {
        if let personID = item.personID, let person = findPerson(id: personID), !FriendService.isUnnamed(person) {
            return MadeSticker(id: item.id, fileURL: item.fileURL, match: .confident(personID), personName: person.name, removed: false)
        }
        return MadeSticker(id: item.id, fileURL: item.fileURL, match: .newFace, personName: nil, removed: false)
    }

    // MARK: - Removal

    /// The `process(photo:)` records behind `batch`: its own record, or, for a batch that shows the stickers
    /// of several photos dropped together (made by the caller under a new id, named after the first photo),
    /// the newest records from that photo onward whose stickers it lists. Empty when they can't be found.
    private func records(behind batch: StickerBatch) -> [BatchRecord] {
        if let own = batchRecords.last(where: { $0.batchID == batch.id }) {
            return [own]
        }
        let listed = Set(batch.stickers.map { $0.id })
        guard !listed.isEmpty else { return [] }

        var parts: [BatchRecord] = []
        var covered = Set<UUID>()
        var foundFirstPhoto = false
        for record in batchRecords.reversed() where record.stickerIDs.isSubset(of: listed) {
            parts.append(record)
            covered.formUnion(record.stickerIDs)
            // Records older than the drop's first photo belong to earlier drops, even when they made
            // the same stickers.
            if record.sourceURL == batch.sourceURL {
                foundFirstPhoto = true
                break
            }
        }
        guard foundFirstPhoto, covered == listed else { return [] }
        return parts
    }

    private func removeSticker(_ item: LibraryItem) -> RemovedSticker {
        let data = try? Data(contentsOf: item.fileURL)
        store.remove(ids: [item.id])
        var removedPerson: Person?
        if let personID = item.personID {
            removedPerson = detach(embedding: item.faceEmbedding, fromPerson: personID)
        }
        return RemovedSticker(item: item, pngData: data, removedPerson: removedPerson)
    }

    /// Forgets `embedding` for the person; an unnamed person left without stickers is removed (returns its previous record).
    @discardableResult
    private func detach(embedding: [Float]?, fromPerson personID: UUID) -> Person? {
        guard var person = findPerson(id: personID) else { return nil }
        let original = person
        if let embedding = embedding {
            person.embeddings.removeAll { $0 == embedding }
        }
        if FriendService.isUnnamed(person) && store.stickerCount(personID: personID) == 0 {
            store.removePerson(id: personID)
            return original
        }
        store.upsert(person)
        return nil
    }

    /// Writes the file back and re-adds the item. false when there is nothing to restore.
    private func restore(_ record: RemovedSticker) -> Bool {
        var item = record.item
        let fileManager = FileManager.default
        if let data = record.pngData {
            do {
                try fileManager.createDirectory(at: item.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
                try data.write(to: item.fileURL, options: .atomic)
            } catch {
                friendLog.error("Restoring sticker failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        } else if !fileManager.fileExists(atPath: item.fileURL.path) {
            return false
        }

        if let snapshot = record.removedPerson, findPerson(id: snapshot.id) == nil {
            store.upsert(snapshot)
        } else if let personID = item.personID {
            if var person = findPerson(id: personID) {
                if let embedding = item.faceEmbedding, !embedding.isEmpty, !person.embeddings.contains(embedding) {
                    person.addEmbedding(embedding)
                    store.upsert(person)
                }
            } else {
                item.personID = nil
                item.displayName = FriendService.displayName(personName: nil, face: item.face, shape: item.faceShape)
            }
        }
        return store.add(item)
    }

    // MARK: - Helpers

    private func findPerson(id: UUID) -> Person? {
        store.people.first { $0.id == id }
    }

    private func saveStore() {
        do {
            try store.save()
        } catch {
            friendLog.error("Saving library failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Person name (or "New face") + " — " + the mood label of the sticker's face (and its shape: a tongue out, a
    /// wink...).
    private static func displayName(personName: String?, face: FaceFeatures?, shape: FaceShape?) -> String {
        var name = "New face"
        if let personName = personName {
            let trimmed = personName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { name = trimmed }
        }
        let mood = MoodClassifier.mood(for: face, pose: nil, shape: shape, baseline: RestingBaseline())
        return name + " — " + mood.label
    }

    private static func isUnnamed(_ person: Person) -> Bool {
        guard let name = person.name else { return true }
        return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func fileSize(of url: URL) -> Int64 {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Int64(size)
    }
}
