import Foundation

/// One meme's hybrid features: CLIP of the whole image (first frame of a GIF), whether a face was found, HSEmotion
/// on the face crop, and CLIP zero-shot from the whole image.
public struct HybridIndexEntry: Codable, Equatable, Sendable {
    public var key: String           // a library item's id (uuidString), or "imgflip:<id>" for a classic meme
    public var contentHash: String   // the item's contentHash, or the template's image URL: a change re-indexes it
    public var clipFull: [Float]     // 512, L2-normalized; JSON: FloatCoding (base64 of little-endian Float32)
    public var hasFace: Bool
    public var emo: [Double]?        // 8 HSEmotion probabilities; nil without a face
    public var zs: [Double]          // 7 zero-shot probabilities

    public init(key: String, contentHash: String, clipFull: [Float], hasFace: Bool, emo: [Double]?, zs: [Double]) {
        self.key = key
        self.contentHash = contentHash
        self.clipFull = clipFull
        self.hasFace = hasFace
        self.emo = hasFace ? emo : nil
        self.zs = zs
    }

    private enum CodingKeys: String, CodingKey { case key, contentHash, clipFull, hasFace, emo, zs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        contentHash = try c.decode(String.self, forKey: .contentHash)
        let encoded = try c.decode(String.self, forKey: .clipFull)
        guard let vector = FloatCoding.decode(encoded) else {
            throw DecodingError.dataCorruptedError(forKey: .clipFull, in: c, debugDescription: "clipFull is not base64 Float32")
        }
        clipFull = vector
        hasFace = try c.decode(Bool.self, forKey: .hasFace)
        emo = try c.decodeIfPresent([Double].self, forKey: .emo)
        zs = try c.decode([Double].self, forKey: .zs)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(contentHash, forKey: .contentHash)
        try c.encode(FloatCoding.encode(clipFull), forKey: .clipFull)
        try c.encode(hasFace, forKey: .hasFace)
        try c.encodeIfPresent(emo, forKey: .emo)
        try c.encode(zs, forKey: .zs)
    }

    /// The sizes the matcher needs: 512 numbers, 7 zero-shot probabilities, 8 emotions when there is a face.
    public var isWellFormed: Bool {
        clipFull.count == HybridMatcher.embeddingSize && zs.count == EmotionPrompts.expectedClasses.count
            && (!hasFace || emo?.count == HSEmotionClass.allCases.count)
    }
}

/// The meme index the app loads at startup (`hybrid-index.json` beside library.json): one entry per meme, sticker
/// and classic meme. An index made by another model (`modelRevision`) is dropped and rebuilt.
public struct HybridIndex: Codable, Equatable, Sendable {
    public static let currentModelRevision = "clip-vit-b-32-quickgelu-laion400m-e32+hsemotion-enet-b0-8-vgaf/1"
    public static let fileName = "hybrid-index.json"

    public var modelRevision: String
    public private(set) var entries: [String: HybridIndexEntry]

    public init(modelRevision: String = HybridIndex.currentModelRevision, entries: [HybridIndexEntry] = []) {
        self.modelRevision = modelRevision
        self.entries = [:]
        for entry in entries { self.entries[entry.key] = entry }
    }

    public subscript(key: String) -> HybridIndexEntry? { entries[key] }
    public var count: Int { entries.count }

    public mutating func upsert(_ entry: HybridIndexEntry) { entries[entry.key] = entry }
    @discardableResult public mutating func remove(_ key: String) -> HybridIndexEntry? { entries.removeValue(forKey: key) }

    /// Drops every entry whose key isn't in `keys`; returns how many went.
    @discardableResult public mutating func retain(keys: Set<String>, where belongs: (String) -> Bool) -> Int {
        let gone = entries.keys.filter { belongs($0) && !keys.contains($0) }
        for key in gone { entries.removeValue(forKey: key) }
        return gone.count
    }

    /// Whether `key` needs (re)indexing: no entry, or one made from other content.
    public func needsIndexing(key: String, contentHash: String) -> Bool {
        entries[key]?.contentHash != contentHash
    }

    public static func templateKey(_ id: String) -> String { "imgflip:" + id }
    public static func isTemplateKey(_ key: String) -> Bool { key.hasPrefix("imgflip:") }

    private enum CodingKeys: String, CodingKey { case modelRevision, entries }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelRevision = try c.decode(String.self, forKey: .modelRevision)
        let list = try c.decode([HybridIndexEntry].self, forKey: .entries)
        entries = [:]
        for entry in list where entry.isWellFormed { entries[entry.key] = entry }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(modelRevision, forKey: .modelRevision)
        try c.encode(entries.values.sorted { $0.key < $1.key }, forKey: .entries)
    }

    /// The index at `url`; an empty one when the file is missing, unreadable or from another model.
    public static func load(from url: URL) -> HybridIndex {
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(HybridIndex.self, from: data),
              index.modelRevision == currentModelRevision else { return HybridIndex() }
        return index
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
