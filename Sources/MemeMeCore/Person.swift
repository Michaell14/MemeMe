import Foundation

/// A friend the user made stickers of. Face data never leaves the Mac.
public struct Person: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String?            // nil = unnamed ("New face")
    public var embeddings: [[Float]]    // up to 20, FloatCoding in JSON
    public var createdAt: Date

    /// Newest embeddings kept per person.
    private static let maximumEmbeddings = 20

    public init(id: UUID = UUID(), name: String? = nil, embeddings: [[Float]] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.embeddings = Array(embeddings.suffix(Person.maximumEmbeddings))
        self.createdAt = createdAt
    }

    /// name ?? "New face" (a blank name counts as no name).
    public var displayName: String {
        if let name = name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        return "New face"
    }

    /// Appends `e`, keeping the newest 20.
    public mutating func addEmbedding(_ e: [Float]) {
        embeddings.append(e)
        if embeddings.count > Person.maximumEmbeddings {
            embeddings.removeFirst(embeddings.count - Person.maximumEmbeddings)
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, embeddings, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = container.decodeLenientIfPresent(String.self, forKey: .name)
        var decoded: [[Float]] = []
        if let encoded = container.decodeLenientIfPresent([String].self, forKey: .embeddings) {
            decoded = encoded.compactMap { FloatCoding.decode($0) }
        } else if let raw = container.decodeLenientIfPresent([[Float]].self, forKey: .embeddings) {
            decoded = raw
        }
        embeddings = Array(decoded.suffix(Person.maximumEmbeddings))
        createdAt = container.decodeLenient(Date.self, forKey: .createdAt, default: Date(timeIntervalSince1970: 0))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(embeddings.map { FloatCoding.encode($0) }, forKey: .embeddings)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

public enum PersonMatch: Equatable, Sendable {
    case confident(UUID)
    case likely(UUID, Double)
    case newFace
}

/// Compares a sticker's face embedding against the user's earlier stickers only.
public struct FriendMatcher: Sendable {
    public var confidentThreshold: Double
    public var likelyThreshold: Double

    public init(confidentThreshold: Double = 0.90, likelyThreshold: Double = 0.80) {
        self.confidentThreshold = confidentThreshold
        self.likelyThreshold = likelyThreshold
    }

    /// Score per person = mean of the top-3 cosine similarities to its embeddings. Best person ≥ confident → .confident; ≥ likely → .likely; else .newFace.
    public func match(_ embedding: [Float], among people: [Person]) -> PersonMatch {
        var bestID: UUID?
        var bestScore = -Double.infinity
        for person in people {
            guard let score = FriendMatcher.score(embedding, against: person.embeddings) else { continue }
            if score > bestScore {
                bestScore = score
                bestID = person.id
            }
        }
        guard let id = bestID else { return .newFace }
        if bestScore >= confidentThreshold { return .confident(id) }
        if bestScore >= likelyThreshold { return .likely(id, bestScore) }
        return .newFace
    }

    /// Mean of the top-3 similarities; nil when the person has no embeddings.
    private static func score(_ embedding: [Float], against embeddings: [[Float]]) -> Double? {
        guard !embeddings.isEmpty else { return nil }
        let similarities = embeddings.map { VectorMath.cosine(embedding, $0) }.sorted(by: >)
        let top = similarities.prefix(3)
        var total = 0.0
        for similarity in top { total += similarity }
        return total / Double(top.count)
    }
}
