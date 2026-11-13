import Foundation

/// What the camera reads in a face being held, in words: each change from your resting face that the search goes by,
/// 0...5, for the panel's "Reading your face" list and the big mirror's glow while you hold a face.
public enum HeldFaceReading {
    public struct Cue: Equatable, Hashable, Sendable {
        /// "Brows up", "Wink".
        public let label: String
        /// The part of the face it is on; nil for the head.
        public let region: FaceRegion?
        /// 0 (not there) ... 5 (as far as it goes).
        public let level: Int

        public init(label: String, region: FaceRegion?, level: Int) {
            self.label = label
            self.region = region
            self.level = min(5, max(0, level))
        }
    }

    /// One of the seven numbers read both ways: its index in `FaceFeatures.vector`, a word each way (nil: that way
    /// isn't a cue) and the change from rest that reads as 5.
    private struct Measure {
        let index: Int
        let up: String
        let down: String?
        let region: FaceRegion?
        let fullScale: Double
    }

    /// In the order ties are listed.
    private static let measures: [Measure] = [
        Measure(index: 0, up: "Brows up", down: "Brows down", region: .brows, fullScale: 0.3),
        Measure(index: 1, up: "Eyes wide", down: "Eyes narrowed", region: .eyes, fullScale: 0.3),
        Measure(index: 2, up: "Mouth open", down: nil, region: .mouth, fullScale: 0.4),
        Measure(index: 4, up: "Smile", down: "Frown", region: .mouth, fullScale: 0.25),
        Measure(index: 3, up: "Mouth wide", down: "Lips pressed", region: .mouth, fullScale: 0.25),
        Measure(index: 6, up: "Side-eye", down: nil, region: .eyes, fullScale: 0.3),
        Measure(index: 5, up: "Head tilted", down: nil, region: nil, fullScale: 0.3),
    ]

    /// The clear cues (`FaceCues`), for the small changes the seven numbers miss.
    private static func label(_ cue: FaceCues.Cue) -> (String, FaceRegion) {
        switch cue {
        case .tongueOut: return ("Tongue out", .mouth)
        case .wink: return ("Wink", .eyes)
        case .raisedBrow: return ("One brow up", .brows)
        case .pucker: return ("Pucker", .mouth)
        case .smirk: return ("Smirk", .mouth)
        case .eyeRoll: return ("Eye roll", .eyes)
        }
    }

    /// The `limit` strongest cues in `face` (and `shape`, when measured) against `baseline`, strongest first; ties keep
    /// a fixed order (brows, eyes, mouth, then the clear cues). Each of the seven numbers reads its own way: brows
    /// up or down, a smile or a frown. Level = round(5 × min(1, |change| / full scale)); a clear cue's level is
    /// round(5 × its strength). Cues that read 0 fill the list when fewer are there, so it never jumps in length.
    public static func cues(face: FaceFeatures, shape: FaceShape? = nil, baseline: RestingBaseline,
                            limit: Int = 4) -> [Cue] {
        guard limit > 0 else { return [] }
        let change = baseline.signedDeviation(of: face)
        var all: [Cue] = []
        for measure in measures where measure.index < change.count {
            let value = change[measure.index]
            let label = value < 0 ? (measure.down ?? measure.up) : measure.up
            let reads = value < 0 && measure.down == nil ? 0 : abs(value)
            let level = Int((5 * min(1, reads / measure.fullScale)).rounded())
            all.append(Cue(label: label, region: measure.region, level: level))
        }
        if let shape {
            let cues = FaceCues(shape: shape, rest: baseline.restShape)
            for cue in FaceCues.Cue.allCases where shape.measures(cue) {
                let level = Int((5 * min(1, max(0, cues[cue]))).rounded())
                guard level > 0 else { continue }
                let (text, region) = label(cue)
                all.append(Cue(label: text, region: region, level: level))
            }
        }
        // A stable sort: strongest first, ties in the order above.
        let ordered = all.enumerated().sorted { lhs, rhs in
            lhs.element.level != rhs.element.level ? lhs.element.level > rhs.element.level : lhs.offset < rhs.offset
        }
        return Array(ordered.prefix(limit).map(\.element))
    }

    /// How much each part of the face shows in `cues`: its strongest cue's level (the mirror's glow while you hold a
    /// face). Parts with nothing (level 0) are left out.
    public static func glow(of cues: [Cue]) -> [FaceRegion: Double] {
        var result: [FaceRegion: Double] = [:]
        for cue in cues where cue.level > 0 {
            guard let region = cue.region else { continue }
            result[region] = max(result[region] ?? 0, Double(cue.level))
        }
        return result
    }
}
