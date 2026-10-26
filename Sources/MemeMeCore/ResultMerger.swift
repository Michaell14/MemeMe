import Foundation

/// Merges late (web) results into a grid without moving what the user is about to click.
public enum ResultMerger {
    /// Keeps current[0..<min(lockedCount, current.count)] in place, then fills from `incoming` (skipping ids already kept) up to `limit`.
    public static func merge(current: [RankedResult], incoming: [RankedResult], lockedCount: Int, limit: Int) -> [RankedResult] {
        guard limit > 0 else { return [] }
        let keptCount = min(max(0, lockedCount), current.count, limit)
        var merged = Array(current.prefix(keptCount))
        var seen = Set(merged.map { $0.id })
        for result in incoming {
            if merged.count >= limit { break }
            if seen.contains(result.id) { continue }
            seen.insert(result.id)
            merged.append(result)
        }
        return merged
    }

    /// Count of leading results that are own items with score ≥ threshold (default 0.6).
    public static func strongOwnPrefix(_ results: [RankedResult], threshold: Double = 0.6) -> Int {
        var count = 0
        for result in results {
            guard result.item.isOwn, result.score >= threshold else { break }
            count += 1
        }
        return count
    }
}
