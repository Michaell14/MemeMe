import Foundation

public enum ItemKind: String, Codable, Sendable {
    case mine, friend, pack, web
}

public enum ItemTier: String, Codable, Sendable {
    case meme, maybe, skipped
}

/// One searchable image: an indexed file, a kept hand-in, a friend sticker or a cached web GIF.
public struct LibraryItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var fileURL: URL               // local file (web items: the cached still)
    public var displayName: String        // file name without extension, or the web title
    public var kind: ItemKind
    public var tier: ItemTier
    public var source: String             // "Downloads", "Desktop", "Screenshots", "Kept", "Friend sticker", "GIPHY", or a folder name
    public var sourceDetail: String?      // e.g. "from reddit.com" (kMDItemWhereFroms host), "IMG_2207.HEIC"
    public var addedAt: Date
    public var fileModifiedAt: Date?
    public var fileSize: Int64
    public var contentHash: String        // SHA-256 hex of the file bytes (web: "giphy:<id>")
    public var isSticker: Bool
    public var isAnimated: Bool
    public var face: FaceFeatures?
    public var pose: PoseFeatures?
    /// The pose analysis this item's `pose` comes from: 0 before poses were described in detail. Items behind
    /// `currentPoseRevision` are measured again in the background.
    public var poseRevision: Int
    public var intensity: Double          // 0...1 against FaceFeatures.populationNeutral
    public var featurePrint: [Float]?     // JSON: base64 of little-endian Float32 (FloatCoding)
    public var featurePrintRevision: Int
    public var text: String               // OCR, ≤ 200 chars
    public var labels: [String]
    public var personID: UUID?
    public var faceEmbedding: [Float]?    // stickers only; JSON like featurePrint
    public var remoteURL: URL?            // web: full GIF to download on commit
    public var previewURL: URL?           // web: small animated GIF for the focused tile
    public var attribution: String?       // web: "via GIPHY"
    public var timesSent: Int
    public var lastSentAt: Date?

    /// Pose analysis with `PoseDescriptor`: 1 arms, elbows and hand sign; 2 also how far each wrist crosses the body,
    /// where the elbows are and the torso (hips); 3 also how the forearms rise, and no peace sign with its fingers on
    /// the face.
    public static let currentPoseRevision = 3

    public init(id: UUID = UUID(), fileURL: URL, displayName: String, kind: ItemKind, tier: ItemTier = .meme, source: String, sourceDetail: String? = nil, addedAt: Date = Date(), fileModifiedAt: Date? = nil, fileSize: Int64 = 0, contentHash: String, isSticker: Bool = false, isAnimated: Bool = false, face: FaceFeatures? = nil, pose: PoseFeatures? = nil, poseRevision: Int = 0, intensity: Double = 0, featurePrint: [Float]? = nil, featurePrintRevision: Int = 0, text: String = "", labels: [String] = [], personID: UUID? = nil, faceEmbedding: [Float]? = nil, remoteURL: URL? = nil, previewURL: URL? = nil, attribution: String? = nil, timesSent: Int = 0, lastSentAt: Date? = nil) {
        self.id = id
        self.fileURL = fileURL
        self.displayName = displayName
        self.kind = kind
        self.tier = tier
        self.source = source
        self.sourceDetail = sourceDetail
        self.addedAt = addedAt
        self.fileModifiedAt = fileModifiedAt
        self.fileSize = fileSize
        self.contentHash = contentHash
        self.isSticker = isSticker
        self.isAnimated = isAnimated
        self.face = face
        self.pose = pose
        self.poseRevision = poseRevision
        self.intensity = intensity
        self.featurePrint = featurePrint
        self.featurePrintRevision = featurePrintRevision
        self.text = text
        self.labels = labels
        self.personID = personID
        self.faceEmbedding = faceEmbedding
        self.remoteURL = remoteURL
        self.previewURL = previewURL
        self.attribution = attribution
        self.timesSent = timesSent
        self.lastSentAt = lastSentAt
    }

    public var isOwn: Bool { kind == .mine || kind == .friend }

    /// "March 2026" (en_US_POSIX "LLLL yyyy", UTC) of fileModifiedAt ?? addedAt
    public var monthKey: String {
        let parts = UTCMonth.yearAndMonth(of: referenceDate)
        return "\(UTCMonth.fullNames[parts.month - 1]) \(parts.year)"
    }

    /// Own: "Downloads · from reddit.com · Mar 2026"; friend: "Friend sticker · Sep 2026"; web: "via GIPHY"
    public var provenance: String {
        switch kind {
        case .web:
            if let attribution = attribution, !attribution.isEmpty { return attribution }
            return "via " + (source.isEmpty ? "GIPHY" : source)
        case .friend:
            return (source.isEmpty ? "Friend sticker" : source) + " · " + shortMonth
        case .mine, .pack:
            var parts: [String] = []
            if !source.isEmpty { parts.append(source) }
            if let detail = sourceDetail, !detail.isEmpty { parts.append(detail) }
            parts.append(shortMonth)
            return parts.joined(separator: " · ")
        }
    }

    /// The date shown and grouped by: when the file changed, else when it was added.
    var referenceDate: Date { fileModifiedAt ?? addedAt }

    /// "Mar 2026" (en_US_POSIX "MMM yyyy", UTC).
    private var shortMonth: String {
        let parts = UTCMonth.yearAndMonth(of: referenceDate)
        return "\(UTCMonth.shortNames[parts.month - 1]) \(parts.year)"
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, fileURL, displayName, kind, tier, source, sourceDetail, addedAt, fileModifiedAt, fileSize, contentHash
        case isSticker, isAnimated, face, pose, poseRevision, intensity, featurePrint, featurePrintRevision, text, labels, personID
        case faceEmbedding, remoteURL, previewURL, attribution, timesSent, lastSentAt
    }

    /// `id`, `fileURL` and `contentHash` are required; every other key falls back to a default so older JSON keeps loading.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decode(UUID.self, forKey: .id)
        let decodedURL = try container.decode(URL.self, forKey: .fileURL)
        let decodedHash = try container.decode(String.self, forKey: .contentHash)
        let modified = container.decodeLenientIfPresent(Date.self, forKey: .fileModifiedAt)

        id = decodedID
        fileURL = decodedURL
        contentHash = decodedHash
        displayName = container.decodeLenient(String.self, forKey: .displayName,
                                              default: decodedURL.deletingPathExtension().lastPathComponent)
        kind = container.decodeLenient(ItemKind.self, forKey: .kind, default: .mine)
        tier = container.decodeLenient(ItemTier.self, forKey: .tier, default: .meme)
        source = container.decodeLenient(String.self, forKey: .source, default: "")
        sourceDetail = container.decodeLenientIfPresent(String.self, forKey: .sourceDetail)
        addedAt = container.decodeLenient(Date.self, forKey: .addedAt, default: modified ?? Date(timeIntervalSince1970: 0))
        fileModifiedAt = modified
        fileSize = container.decodeLenient(Int64.self, forKey: .fileSize, default: 0)
        isSticker = container.decodeLenient(Bool.self, forKey: .isSticker, default: false)
        isAnimated = container.decodeLenient(Bool.self, forKey: .isAnimated, default: false)
        face = container.decodeLenientIfPresent(FaceFeatures.self, forKey: .face)
        pose = container.decodeLenientIfPresent(PoseFeatures.self, forKey: .pose)
        poseRevision = container.decodeLenient(Int.self, forKey: .poseRevision, default: 0)
        intensity = container.decodeLenient(Double.self, forKey: .intensity, default: 0)
        featurePrint = container.decodeFloatVector(forKey: .featurePrint)
        featurePrintRevision = container.decodeLenient(Int.self, forKey: .featurePrintRevision, default: 0)
        text = container.decodeLenient(String.self, forKey: .text, default: "")
        labels = container.decodeLenient([String].self, forKey: .labels, default: [])
        personID = container.decodeLenientIfPresent(UUID.self, forKey: .personID)
        faceEmbedding = container.decodeFloatVector(forKey: .faceEmbedding)
        remoteURL = container.decodeLenientIfPresent(URL.self, forKey: .remoteURL)
        previewURL = container.decodeLenientIfPresent(URL.self, forKey: .previewURL)
        attribution = container.decodeLenientIfPresent(String.self, forKey: .attribution)
        timesSent = container.decodeLenient(Int.self, forKey: .timesSent, default: 0)
        lastSentAt = container.decodeLenientIfPresent(Date.self, forKey: .lastSentAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(fileURL, forKey: .fileURL)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(kind, forKey: .kind)
        try container.encode(tier, forKey: .tier)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(sourceDetail, forKey: .sourceDetail)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encodeIfPresent(fileModifiedAt, forKey: .fileModifiedAt)
        try container.encode(fileSize, forKey: .fileSize)
        try container.encode(contentHash, forKey: .contentHash)
        try container.encode(isSticker, forKey: .isSticker)
        try container.encode(isAnimated, forKey: .isAnimated)
        try container.encodeIfPresent(face, forKey: .face)
        try container.encodeIfPresent(pose, forKey: .pose)
        try container.encode(poseRevision, forKey: .poseRevision)
        try container.encode(intensity, forKey: .intensity)
        try container.encodeIfPresent(featurePrint.map { FloatCoding.encode($0) }, forKey: .featurePrint)
        try container.encode(featurePrintRevision, forKey: .featurePrintRevision)
        try container.encode(text, forKey: .text)
        try container.encode(labels, forKey: .labels)
        try container.encodeIfPresent(personID, forKey: .personID)
        try container.encodeIfPresent(faceEmbedding.map { FloatCoding.encode($0) }, forKey: .faceEmbedding)
        try container.encodeIfPresent(remoteURL, forKey: .remoteURL)
        try container.encodeIfPresent(previewURL, forKey: .previewURL)
        try container.encodeIfPresent(attribution, forKey: .attribution)
        try container.encode(timesSent, forKey: .timesSent)
        try container.encodeIfPresent(lastSentAt, forKey: .lastSentAt)
    }
}

/// Compact JSON representation of float vectors: base64 of little-endian Float32 values.
public enum FloatCoding {
    /// Base64 of little-endian Float32.
    public static func encode(_ values: [Float]) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(values.count * 4)
        for value in values {
            // The in-memory bytes of the little-endian representation are least-significant first on any host.
            var littleEndianBits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &littleEndianBits) { bytes.append(contentsOf: $0) }
        }
        return Data(bytes).base64EncodedString()
    }

    /// nil when the string is not base64 or its length is not a multiple of 4 bytes.
    public static func decode(_ string: String) -> [Float]? {
        if string.isEmpty { return [] }
        guard let data = Data(base64Encoded: string), data.count % 4 == 0 else { return nil }
        let bytes = [UInt8](data)
        var values: [Float] = []
        values.reserveCapacity(bytes.count / 4)
        var index = 0
        while index + 3 < bytes.count {
            // Little-endian: the first byte is the least significant.
            var raw = UInt32(bytes[index])
            raw |= UInt32(bytes[index + 1]) << 8
            raw |= UInt32(bytes[index + 2]) << 16
            raw |= UInt32(bytes[index + 3]) << 24
            values.append(Float(bitPattern: raw))
            index += 4
        }
        return values
    }
}

/// Gregorian year and month in UTC, with fixed English month names (same output as en_US_POSIX).
enum UTCMonth {
    static let fullNames = ["January", "February", "March", "April", "May", "June",
                            "July", "August", "September", "October", "November", "December"]
    static let shortNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        if let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) {
            calendar.timeZone = utc
        }
        return calendar
    }()

    /// Month is always 1...12.
    static func yearAndMonth(of date: Date) -> (year: Int, month: Int) {
        let components = calendar.dateComponents([.year, .month], from: date)
        let month = min(12, max(1, components.month ?? 1))
        return (components.year ?? 1970, month)
    }
}

extension KeyedDecodingContainer {
    /// The value for `key`, or `fallback` when the key is missing, null, or holds the wrong type.
    func decodeLenient<T: Decodable>(_ type: T.Type, forKey key: Key, default fallback: T) -> T {
        if let value = try? decodeIfPresent(type, forKey: key) {
            return value
        }
        return fallback
    }

    /// The value for `key`, or nil when the key is missing, null, or holds the wrong type.
    func decodeLenientIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        if let value = try? decodeIfPresent(type, forKey: key) {
            return value
        }
        return nil
    }

    /// A FloatCoding base64 string, or (older files) a plain JSON number array.
    func decodeFloatVector(forKey key: Key) -> [Float]? {
        if let encoded = try? decodeIfPresent(String.self, forKey: key) {
            return FloatCoding.decode(encoded)
        }
        if let values = try? decodeIfPresent([Float].self, forKey: key) {
            return values
        }
        return nil
    }
}
