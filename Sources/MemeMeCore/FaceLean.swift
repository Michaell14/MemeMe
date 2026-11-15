import Foundation

/// Leaning the face search on one part of your face: a click on your brows, eyes or mouth in the camera. The part you
/// lean on counts most when your things are ranked, and the search's word is read from it alone (the other parts as
/// they are at rest), so GIPHY and the classic memes follow it too.
public enum FaceLean {
    /// How much the part leaned on counts, and the others, in the ranker's weights (the automatic ones run 1...3).
    public static let leanedWeight: Double = 3
    public static let otherWeight: Double = 0.5

    /// `base` with the part leaned on counting most and the others little; the pose's share stays.
    public static func weights(_ base: FeatureWeights, leaningOn region: FaceRegion) -> FeatureWeights {
        var regions: [FaceRegion: Double] = [:]
        for part in FaceRegion.allCases {
            regions[part] = part == region ? leanedWeight : otherWeight
        }
        return base.overriding(regions)
    }

    /// The face the search's word is read from: `face`'s values for the part leaned on, `rest`'s for the others (and
    /// for the head's tilt, which belongs to no part).
    public static func face(_ face: FaceFeatures, leaningOn region: FaceRegion, rest: FaceFeatures) -> FaceFeatures {
        var values = rest.vector
        let own = face.vector
        for index in FaceFeatures.indices(for: region) where index < values.count && index < own.count {
            values[index] = own[index]
        }
        return FaceFeatures(browRaise: values[0], eyeOpenness: values[1], mouthOpenness: values[2],
                            mouthWidth: values[3], smile: values[4], headTilt: values[5], gazeSide: values[6])
    }

    /// The part of the face a detail is read from: a wink and an eye roll from the eyes, one raised brow from the
    /// brows, the tongue, pursed lips and a smirk from the mouth.
    public static func region(of cue: FaceCues.Cue) -> FaceRegion {
        switch cue {
        case .wink, .eyeRoll: return .eyes
        case .raisedBrow: return .brows
        case .tongueOut, .pucker, .smirk: return .mouth
        }
    }

    /// The face's details when leaning on `region`: kept when the clear one is in that part (or none is clear), else
    /// dropped, so a wink doesn't name a search that leans on the mouth.
    public static func shape(_ shape: FaceShape?, leaningOn region: FaceRegion, baseline: RestingBaseline) -> FaceShape? {
        guard let shape else { return nil }
        guard let cue = baseline.cues(of: shape).clearCue else { return shape }
        return FaceLean.region(of: cue) == region ? shape : nil
    }

    /// The sample whose word the search goes by when leaning on `region`. Without a face, the sample as it is.
    public static func sample(_ sample: ExpressionSample, leaningOn region: FaceRegion,
                              baseline: RestingBaseline) -> ExpressionSample {
        guard let face = sample.face else { return sample }
        return ExpressionSample(face: FaceLean.face(face, leaningOn: region, rest: baseline.neutral),
                                pose: sample.pose,
                                shape: FaceLean.shape(sample.shape, leaningOn: region, baseline: baseline),
                                timestamp: sample.timestamp,
                                sharpness: sample.sharpness)
    }
}
