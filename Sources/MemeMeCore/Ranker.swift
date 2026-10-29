import Foundation

public enum SearchQuery: Sendable {
    case recent(appBundleID: String?)
    /// A held face or pose. `words` name it when it was described in words (a clear gesture with no word of its own:
    /// "flexing", "rock on"); memes whose name, text or labels say them rank a little higher (`expressionScore`).
    case expression(ExpressionSample, weights: FeatureWeights, words: [String] = [])
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
    public var personIDs: Set<UUID>      // terms equal (case-insensitive) to a person's name, or its possessive ("sam's"), are removed from terms and become filters

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
                if let ids = peopleByName[term] ?? possessiveBase(of: term).flatMap({ peopleByName[$0] }) {
                    query.personIDs.formUnion(ids)
                } else {
                    query.terms.append(term)
                }
            }
        }
        return query
    }

    /// "sam's" / "sam’s" → "sam"; nil for any other word.
    private static func possessiveBase(of term: String) -> String? {
        for suffix in ["'s", "’s"] where term.hasSuffix(suffix) && term.count > suffix.count {
            return String(term.dropLast(suffix.count))
        }
        return nil
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
    /// A query without a face is still matched by its pose from this gesture strength on.
    public static let gestureWithoutFace = 0.4
    /// Share of the face match a query's clear cue takes at full strength (`expressionScore`).
    private static let cueShare = 0.45
    /// Added once for an item whose name, text or labels say the query's clear cue ("tongue out", "wink"...) or the
    /// words its pose was described by ("flexing"), even when they say both.
    private static let cueWordBonus = 0.05

    public init(baseline: RestingBaseline = RestingBaseline()) {
        self.baseline = baseline
    }

    public func rank(_ items: [LibraryItem], query: SearchQuery, people: [Person] = [], recents: [UUID] = [], limit: Int = 10) -> [RankedResult] {
        guard limit > 0 else { return [] }
        switch query {
        case .recent:
            return rankRecent(items, recents: recents, limit: limit)
        case let .expression(sample, weights, words):
            return rankExpression(items, sample: sample, weights: weights, words: words, limit: limit)
        case let .text(raw, sample, weights):
            return rankText(items, raw: raw, sample: sample, weights: weights, people: people, limit: limit)
        case let .image(featurePrint, face, _):
            return rankImage(items, featurePrint: featurePrint, face: face, limit: limit)
        case let .moreLike(reference):
            return rankMoreLike(items, reference: reference, limit: limit)
        }
    }

    /// Both faces: 0.7 × ((1 − w) × face similarity + w × pose similarity) + 0.3 × intensity fit, w = weights.pose.
    /// When the query shows a clear cue (`FaceCues.clearCue` of its `shape` against the baseline's resting shape: tongue
    /// out, wink, one raised brow, pucker, smirk, eye roll) of strength u, v = 0.45 × u of the face part is how
    /// strongly the item shows that cue (its `faceShape`'s `FaceCues` against fixed values; 0.5, unknown, without
    /// one): 0.7 × ((1 − w) × (1 − v) × face similarity + w × pose similarity + (1 − w) × v × cue similarity) + 0.3 ×
    /// fit, so a face the seven features can't tell from a plain one finds the memes that show it.
    /// A face hidden behind a clear gesture (or a meme without a readable face) when the item's arms were measured: the
    /// face part counts 0.5 and the pose carries the match. Otherwise 0.25 + 0.3 × fit.
    /// An item whose name, text or labels say the clear cue (`mentions(_:in:)`) or name one of `words` (what a pose
    /// with no word of its own was described by: `mentions(words:in:)`) gets +0.05: once, even when both do.
    public func expressionScore(item: LibraryItem, sample: ExpressionSample, weights: FeatureWeights,
                                words: [String] = []) -> Double {
        let target = sample.face.map { baseline.intensity(of: $0) } ?? 0.3
        let fit = 1 - abs(item.intensity - target)
        let poseWeight = VectorMath.clampUnit(weights.pose)
        let cues = baseline.cues(of: sample.shape)
        let clearCue = cues.clearCue
        var score: Double
        if let itemFace = item.face, let queryFace = sample.face {
            let queryDeviation = baseline.signedDeviation(of: queryFace)
            let itemDeviation = Ranker.populationDeviation(of: itemFace)
            let featureSim = Ranker.featureSimilarity(queryDeviation, itemDeviation, weights: weights)
            let poseSim = PoseFeatures.similarity(query: sample.pose, item: item.pose)
            var faceScore = (1 - poseWeight) * featureSim + poseWeight * poseSim
            if let cue = clearCue {
                let share = Ranker.cueShare * cues[cue]
                // Unknown (0.5) without a shape, or when the item's shape lacks what the cue is read from (colors
                // that couldn't tell a tongue, say).
                let cueSim = item.faceShape.flatMap { $0.measures(cue) ? FaceCues(shape: $0, rest: nil)[cue] : nil } ?? 0.5
                faceScore = (1 - poseWeight) * (1 - share) * featureSim + poseWeight * poseSim
                    + (1 - poseWeight) * share * cueSim
            }
            score = 0.7 * faceScore + 0.3 * fit
        } else if let queryPose = sample.pose, queryPose.gestureStrength >= Ranker.gestureWithoutFace, item.pose?.descriptor?.showsArms == true {
            let poseSim = PoseFeatures.similarity(query: queryPose, item: item.pose)
            let faceScore = (1 - poseWeight) * 0.5 + poseWeight * poseSim
            score = 0.7 * faceScore + 0.3 * fit
        } else {
            score = 0.25 + 0.3 * fit
        }
        score += Ranker.adjustment(for: item)
        let namesCue = clearCue.map { Ranker.mentions($0, in: item) } ?? false
        if namesCue || Ranker.mentions(words: words, in: item) {
            score += Ranker.cueWordBonus
        }
        return score.isFinite ? score : 0
    }

    // MARK: Modes

    private func rankExpression(_ items: [LibraryItem], sample: ExpressionSample, weights: FeatureWeights,
                                words: [String], limit: Int) -> [RankedResult] {
        var scored: [RankedResult] = []
        for item in items where item.tier == .meme {
            let score = expressionScore(item: item, sample: sample, weights: weights, words: words)
            scored.append(RankedResult(item: item, score: score))
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

    /// Words a meme showing `cue` is named or tagged with.
    static func words(for cue: FaceCues.Cue) -> [String] {
        switch cue {
        case .tongueOut: return ["tongue", "blep"]
        case .wink: return ["wink"]
        case .raisedBrow: return ["eyebrow"]
        case .pucker: return ["duck face", "duckface", "kiss", "pout"]
        case .smirk: return ["smirk"]
        case .eyeRoll: return ["eye roll", "eyeroll", "rolling eyes"]
        }
    }

    /// Whether the item's name, text or labels contain one of `cue`'s words (any case).
    static func mentions(_ cue: FaceCues.Cue, in item: LibraryItem) -> Bool {
        let text = [item.displayName, item.text, item.labels.joined(separator: " ")].joined(separator: " ").lowercased()
        return words(for: cue).contains { text.contains($0) }
    }

    /// Whether the item's name, text or labels name one of `words` (a described pose's phrase, "flexing", "rock on"),
    /// any case, by `DescribedWords`: whole words, or words of 4 letters or more starting one ("flex" finds "flexing",
    /// "arm" never finds "farm"); stopwords and body and side words never count. Own memes have no table of words, so
    /// a word ending in "ing" also finds its stem ("flexing" finds a meme named "flex", "thinking" one named "think").
    public static func mentions(words: [String], in item: LibraryItem) -> Bool {
        let terms = DescribedWords.terms(in: words)
        guard !terms.isEmpty else { return false }
        let text = [item.displayName, item.text, item.labels.joined(separator: " ")].joined(separator: " ")
        let itemWords = DescribedWords.words(in: text)
        let wanted = terms + terms.compactMap(DescribedWords.stem(of:))
        return wanted.contains { term in itemWords.contains { DescribedWords.term(term, matches: $0) } }
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

/// The words a pose with no word of its own was described by (`PoseDescription.phrase`, or the on-device model's name
/// for it: "flexing", "rock on"), matched against what memes are named, say and are tagged with. A word matches a whole
/// word, or from `minimumPrefix` letters on the start of one ("flex" finds "flexing"), never the inside of one ("arm"
/// isn't "farm"). Stopwords and body and side words say nothing about which meme fits ("on" isn't One Does Not Simply,
/// "hand" isn't Epic Handshake, and the describer never says "left" or "right"), so they never count.
enum DescribedWords {
    /// Shorter words match whole words only.
    static let minimumPrefix = 4

    /// Never matched: stopwords, and body and side words.
    static let ignored: Set<String> = [
        "a", "an", "the", "my", "on", "at", "of", "in", "by", "with", "to", "up", "out", "one", "both",
        "and", "is", "it", "for", "his", "her", "their", "your",
        "left", "right", "arm", "arms", "hand", "hands", "head", "face", "pose", "strike",
    ]

    /// Lowercased words, split on anything but letters and digits.
    static func words(in text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// The words of `phrases` that count, in order: lowercased and split, without ignored words or single letters.
    static func terms(in phrases: [String]) -> [String] {
        phrases.flatMap { words(in: $0) }.filter { $0.count >= 2 && !ignored.contains($0) }
    }

    /// Whether `term` names `word`: the same word, or a term of `minimumPrefix` letters or more starting it.
    static func term(_ term: String, matches word: String) -> Bool {
        word == term || (term.count >= minimumPrefix && word.hasPrefix(term))
    }

    /// A word ending in "ing" without it ("flexing" → "flex", "thinking" → "think"), when that leaves `minimumPrefix`
    /// letters or more; nil for any other word ("sing", "bring", "flex").
    static func stem(of term: String) -> String? {
        guard term.hasSuffix("ing"), term.count - 3 >= minimumPrefix else { return nil }
        return String(term.dropLast(3))
    }
}
