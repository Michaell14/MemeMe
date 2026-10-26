import Foundation

public enum SearchQuery: Sendable {
    case recent(appBundleID: String?)
    case expression(ExpressionSample, weights: FeatureWeights)
    case text(String, face: ExpressionSample?, weights: FeatureWeights)
    case image(featurePrint: [Float]?, face: FaceFeatures?, intensity: Double)
    case moreLike(LibraryItem)
}

public struct RankedResult: Identifiable, Hashable, Sendable {
    public var id: UUID { item.id }
    public let item: LibraryItem
    public let score: Double
    public let section: String?          // text search: month key, "From GIPHY", "From your photos"

    public init(item: LibraryItem, score: Double, section: String? = nil) {
        self.item = item
        self.score = score
        self.section = section
    }
}

/// A typed search split into substring terms and filter words.
public struct TextQuery: Equatable, Sendable {
    public var terms: [String]           // lowercased, filters removed
    public var onlyMine: Bool            // "mine"
    public var onlyGIFs: Bool            // "gif" / "gifs"
    public var onlyStickers: Bool        // "sticker" / "stickers"
    public var personIDs: Set<UUID>      // terms equal (case-insensitive) to a person's name are removed from terms and become filters

    public static func parse(_ raw: String, people: [Person]) -> TextQuery {
        var query = TextQuery(terms: [], onlyMine: false, onlyGIFs: false, onlyStickers: false, personIDs: [])

        var peopleByName: [String: [UUID]] = [:]
        for person in people {
            guard let name = person.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !name.isEmpty else { continue }
            peopleByName[name, default: []].append(person.id)
        }

        let words = raw.lowercased().split(whereSeparator: { $0.isWhitespace })
        for word in words {
            let term = String(word).trimmingCharacters(in: .punctuationCharacters)
            if term.isEmpty { continue }
            switch term {
            case "mine":
                query.onlyMine = true
            case "gif", "gifs":
                query.onlyGIFs = true
            case "sticker", "stickers":
                query.onlyStickers = true
            default:
                if let ids = peopleByName[term] {
                    query.personIDs.formUnion(ids)
                } else {
                    query.terms.append(term)
                }
            }
        }
        return query
    }

    /// The single remaining term when it is alphabetic, ≥ 3 letters and matched no person (used for "Is one of these Sam?").
    public var possibleName: String? {
        guard terms.count == 1, let term = terms.first, term.count >= 3 else { return nil }
        guard term.allSatisfy({ $0.isLetter }) else { return nil }
        return term
    }
}

/// Scores library and web items against a query. Pure and cheap; safe to run on any thread.
public struct Ranker: Sendable {
    public var baseline: RestingBaseline

    /// At most this many friend stickers in a face-search grid.
    private static let maximumFriendsInFaceResults = 2
    /// Text searches with fewer hits than this fall back to skipped items ("From your photos").
    private static let fewTextHits = 3

    public init(baseline: RestingBaseline = RestingBaseline()) {
        self.baseline = baseline
    }

    public func rank(_ items: [LibraryItem], query: SearchQuery, people: [Person] = [], recents: [UUID] = [], limit: Int = 10) -> [RankedResult] {
        guard limit > 0 else { return [] }
        switch query {
        case .recent:
            return rankRecent(items, recents: recents, limit: limit)
        case let .expression(sample, weights):
            return rankExpression(items, sample: sample, weights: weights, limit: limit)
        case let .text(raw, sample, weights):
            return rankText(items, raw: raw, sample: sample, weights: weights, people: people, limit: limit)
        case let .image(featurePrint, face, _):
            return rankImage(items, featurePrint: featurePrint, face: face, limit: limit)
        case let .moreLike(reference):
            return rankMoreLike(items, reference: reference, limit: limit)
        }
    }

    public func expressionScore(item: LibraryItem, sample: ExpressionSample, weights: FeatureWeights) -> Double {
        let target = sample.face.map { baseline.intensity(of: $0) } ?? 0.3
        let fit = 1 - abs(item.intensity - target)
        var score: Double
        if let itemFace = item.face, let queryFace = sample.face {
            let queryDeviation = baseline.signedDeviation(of: queryFace)
            let itemDeviation = Ranker.populationDeviation(of: itemFace)
            let featureSim = Ranker.featureSimilarity(queryDeviation, itemDeviation, weights: weights)
            let poseSim = 1 - abs((item.pose?.activity ?? 0.1) - (sample.pose?.activity ?? 0))
            let faceScore = (1 - weights.pose) * featureSim + weights.pose * poseSim
            score = 0.7 * faceScore + 0.3 * fit
        } else {
            score = 0.25 + 0.3 * fit
        }
        score += Ranker.adjustment(for: item)
        return score.isFinite ? score : 0
    }

    // MARK: Modes

    private func rankExpression(_ items: [LibraryItem], sample: ExpressionSample, weights: FeatureWeights, limit: Int) -> [RankedResult] {
        var scored: [RankedResult] = []
        for item in items where item.tier == .meme {
            scored.append(RankedResult(item: item, score: expressionScore(item: item, sample: sample, weights: weights)))
        }
        var results: [RankedResult] = []
        var friendCount = 0
        for result in Ranker.sortedByScore(scored, friendsWinTies: true) {
            if results.count >= limit { break }
            if result.item.kind == .friend {
                if friendCount >= Ranker.maximumFriendsInFaceResults { continue }
                friendCount += 1
            }
            results.append(result)
        }
        return results
    }

    private func rankText(_ items: [LibraryItem], raw: String, sample: ExpressionSample?, weights: FeatureWeights, people: [Person], limit: Int) -> [RankedResult] {
        let query = TextQuery.parse(raw, people: people)
        var namesByID: [UUID: String] = [:]
        for person in people {
            if let name = person.name { namesByID[person.id] = name }
        }

        var matching: [LibraryItem] = []
        for item in items where Ranker.passesFilters(item, query: query) {
            let personName = item.personID.flatMap { namesByID[$0] } ?? ""
            let haystack = Ranker.searchableText(of: item, personName: personName)
            if query.terms.allSatisfy({ haystack.contains($0) }) {
                matching.append(item)
            }
        }

        var ownByMonth: [String: [LibraryItem]] = [:]
        var newestInMonth: [String: Date] = [:]
        var packs: [LibraryItem] = []
        var web: [LibraryItem] = []
        var hitCount = 0
        for item in matching where item.tier == .meme || item.tier == .maybe {
            hitCount += 1
            switch item.kind {
            case .mine, .friend:
                let month = item.monthKey
                ownByMonth[month, default: []].append(item)
                let date = item.referenceDate
                if date > (newestInMonth[month] ?? .distantPast) { newestInMonth[month] = date }
            case .pack:
                packs.append(item)
            case .web:
                web.append(item)
            }
        }

        let months = ownByMonth.keys.sorted { lhs, rhs in
            let lhsDate = newestInMonth[lhs] ?? .distantPast
            let rhsDate = newestInMonth[rhs] ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs < rhs
        }

        var results: [RankedResult] = []
        for month in months {
            results += textGroup(ownByMonth[month] ?? [], section: month, sample: sample, weights: weights)
        }
        results += textGroup(packs, section: "Packs", sample: sample, weights: weights)
        results += textGroup(web, section: "From GIPHY", sample: sample, weights: weights)
        if hitCount < Ranker.fewTextHits {
            let skipped = matching.filter { $0.tier == .skipped }
            results += textGroup(skipped, section: "From your photos", sample: sample, weights: weights)
        }
        return Array(results.prefix(limit))
    }

    /// One section: by expression score when a face is held, else newest first.
    private func textGroup(_ items: [LibraryItem], section: String, sample: ExpressionSample?, weights: FeatureWeights) -> [RankedResult] {
        var group: [RankedResult] = []
        for item in items {
            let score = sample.map { expressionScore(item: item, sample: $0, weights: weights) } ?? 1
            group.append(RankedResult(item: item, score: score, section: section))
        }
        return Ranker.sortedByScore(group)
    }

    private func rankImage(_ items: [LibraryItem], featurePrint: [Float]?, face: FaceFeatures?, limit: Int) -> [RankedResult] {
        var scored: [RankedResult] = []
        for item in items where item.tier == .meme {
            let fp = Ranker.fingerprintSimilarity(featurePrint, item.featurePrint)
            let fs = Ranker.plainFaceSimilarity(face, item.face)
            let score = 0.7 * fp + 0.3 * fs + Ranker.adjustment(for: item)
            scored.append(RankedResult(item: item, score: score.isFinite ? score : 0))
        }
        return Array(Ranker.sortedByScore(scored).prefix(limit))
    }

    private func rankMoreLike(_ items: [LibraryItem], reference: LibraryItem, limit: Int) -> [RankedResult] {
        var scored: [RankedResult] = []
        for item in items where item.tier == .meme && item.id != reference.id {
            let fp = Ranker.fingerprintSimilarity(reference.featurePrint, item.featurePrint)
            let fs = Ranker.plainFaceSimilarity(reference.face, item.face)
            let fit = 1 - abs(item.intensity - reference.intensity)
            let score = 0.6 * fp + 0.3 * fs + 0.1 * fit
            scored.append(RankedResult(item: item, score: score.isFinite ? score : 0))
        }
        return Array(Ranker.sortedByScore(scored).prefix(limit))
    }

    private func rankRecent(_ items: [LibraryItem], recents: [UUID], limit: Int) -> [RankedResult] {
        var itemsByID: [UUID: LibraryItem] = [:]
        for item in items where itemsByID[item.id] == nil {
            itemsByID[item.id] = item
        }

        var results: [RankedResult] = []
        var included = Set<UUID>()
        for id in recents {
            if results.count >= limit { return results }
            guard !included.contains(id), let item = itemsByID[id] else { continue }
            guard item.tier == .meme || item.tier == .maybe else { continue }
            included.insert(id)
            results.append(RankedResult(item: item, score: 1))
        }

        let fill = items
            .filter { $0.isOwn && $0.tier == .meme && !included.contains($0.id) }
            .sorted { lhs, rhs in
                let lhsSent = lhs.lastSentAt ?? .distantPast
                let rhsSent = rhs.lastSentAt ?? .distantPast
                if lhsSent != rhsSent { return lhsSent > rhsSent }
                if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        for item in fill {
            if results.count >= limit { break }
            if included.contains(item.id) { continue }
            included.insert(item.id)
            results.append(RankedResult(item: item, score: 1))
        }
        return results
    }

    // MARK: Scoring helpers

    /// item.vector - populationNeutral.vector
    static func populationDeviation(of face: FaceFeatures) -> [Double] {
        let values = face.vector
        let neutral = FaceFeatures.populationNeutral.vector
        var deviation: [Double] = []
        deviation.reserveCapacity(values.count)
        for index in 0..<values.count {
            deviation.append(values[index] - neutral[index])
        }
        return deviation
    }

    /// Σ w_r·sim_r / Σ w_r with sim_r = max(0, 1 - meanAbsDiff(region) / 0.5).
    static func featureSimilarity(_ query: [Double], _ item: [Double], weights: FeatureWeights) -> Double {
        var weightedTotal = 0.0
        var weightSum = 0.0
        var plainTotal = 0.0
        for region in FaceRegion.allCases {
            var queryPart: [Double] = []
            var itemPart: [Double] = []
            for index in FaceFeatures.indices(for: region) where index < query.count && index < item.count {
                queryPart.append(query[index])
                itemPart.append(item[index])
            }
            let similarity = max(0, 1 - VectorMath.meanAbsDiff(queryPart, itemPart) / 0.5)
            let weight = max(0, weights[region])
            weightedTotal += weight * similarity
            weightSum += weight
            plainTotal += similarity
        }
        if weightSum > 0 { return weightedTotal / weightSum }
        return plainTotal / Double(FaceRegion.allCases.count)
    }

    /// Face similarity with uniform weights, both faces measured against the population neutral; 0.5 when either is missing.
    static func plainFaceSimilarity(_ a: FaceFeatures?, _ b: FaceFeatures?) -> Double {
        guard let a = a, let b = b else { return 0.5 }
        return featureSimilarity(populationDeviation(of: a), populationDeviation(of: b), weights: .uniform)
    }

    /// (cosine + 1) / 2 when both prints exist, else 0.5.
    static func fingerprintSimilarity(_ a: [Float]?, _ b: [Float]?) -> Double {
        guard let a = a, let b = b else { return 0.5 }
        return (VectorMath.cosine(a, b) + 1) / 2
    }

    /// +0.02 own, +0.01·min(timesSent, 5)/5, −0.01 web.
    static func adjustment(for item: LibraryItem) -> Double {
        var delta = 0.0
        if item.isOwn { delta += 0.02 }
        delta += 0.01 * Double(min(max(item.timesSent, 0), 5)) / 5
        if item.kind == .web { delta -= 0.01 }
        return delta
    }

    /// lowercased(displayName + " " + text + " " + labels + " " + source + " " + sourceDetail + " " + person name)
    static func searchableText(of item: LibraryItem, personName: String) -> String {
        let parts = [item.displayName, item.text, item.labels.joined(separator: " "), item.source, item.sourceDetail ?? "", personName]
        return parts.joined(separator: " ").lowercased()
    }

    static func passesFilters(_ item: LibraryItem, query: TextQuery) -> Bool {
        if query.onlyMine && !item.isOwn { return false }
        if query.onlyGIFs && !item.isAnimated { return false }
        if query.onlyStickers && !item.isSticker { return false }
        if !query.personIDs.isEmpty {
            guard let personID = item.personID, query.personIDs.contains(personID) else { return false }
        }
        return true
    }

    /// Score descending; ties: friend stickers first (face search only), then newer first, then a stable id order.
    static func sortedByScore(_ results: [RankedResult], friendsWinTies: Bool = false) -> [RankedResult] {
        results.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if friendsWinTies {
                let lhsIsFriend = lhs.item.kind == .friend
                let rhsIsFriend = rhs.item.kind == .friend
                if lhsIsFriend != rhsIsFriend { return lhsIsFriend }
            }
            let lhsDate = lhs.item.referenceDate
            let rhsDate = rhs.item.referenceDate
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.item.id.uuidString < rhs.item.id.uuidString
        }
    }
}
