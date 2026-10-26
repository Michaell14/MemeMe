import Foundation

/// Small numeric helpers shared by the baseline, tracker, ranker and friend matcher.
public enum VectorMath {
    /// Cosine similarity in Double precision; 0 when sizes differ, a vector is empty, or a norm is 0.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for index in 0..<a.count {
            let x = Double(a[index])
            let y = Double(b[index])
            dot += x * y
            normA += x * x
            normB += y * y
        }
        return finishCosine(dot: dot, normA: normA, normB: normB)
    }

    /// Cosine similarity; 0 when sizes differ, a vector is empty, or a norm is 0.
    public static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for index in 0..<a.count {
            let x = a[index]
            let y = b[index]
            dot += x * y
            normA += x * x
            normB += y * y
        }
        return finishCosine(dot: dot, normA: normA, normB: normB)
    }

    /// Unit-length copy of `v`; all zeros when the norm is below 1e-9 (or not finite).
    public static func normalized(_ v: [Double]) -> [Double] {
        var sumOfSquares = 0.0
        for x in v { sumOfSquares += x * x }
        let norm = sumOfSquares.squareRoot()
        guard norm.isFinite, norm >= 1e-9 else { return [Double](repeating: 0, count: v.count) }
        return v.map { $0 / norm }
    }

    /// Mean of |a[i] - b[i]| over the shared prefix; 0 when either vector is empty.
    public static func meanAbsDiff(_ a: [Double], _ b: [Double]) -> Double {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0 }
        var total = 0.0
        for index in 0..<count { total += abs(a[index] - b[index]) }
        return total / Double(count)
    }

    /// Clamps to 0...1 (NaN becomes 0).
    static func clampUnit(_ x: Double) -> Double {
        guard x.isFinite else { return x == .infinity ? 1 : 0 }
        return min(1, max(0, x))
    }

    private static func finishCosine(dot: Double, normA: Double, normB: Double) -> Double {
        guard normA > 0, normB > 0 else { return 0 }
        let value = dot / (normA.squareRoot() * normB.squareRoot())
        guard value.isFinite else { return 0 }
        return min(1, max(-1, value))
    }
}
