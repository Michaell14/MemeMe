import Foundation

/// Cheap facts about an image, gathered by the analyzer, that decide its tier and sticker eligibility.
public struct ImageFacts: Codable, Hashable, Sendable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var isAnimated: Bool
    public var isCameraPhoto: Bool        // EXIF/TIFF Make or Model present and not a screenshot
    public var isScreenshot: Bool         // file name starts with "Screenshot"/"Screen Shot"/"CleanShot", or EXIF UserComment == "Screenshot"
    public var textCharacterCount: Int
    public var faceCount: Int
    public var largestFaceHeightFraction: Double
    public var labels: [String]

    public init(pixelWidth: Int, pixelHeight: Int, isAnimated: Bool, isCameraPhoto: Bool, isScreenshot: Bool, textCharacterCount: Int, faceCount: Int, largestFaceHeightFraction: Double, labels: [String]) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isAnimated = isAnimated
        self.isCameraPhoto = isCameraPhoto
        self.isScreenshot = isScreenshot
        self.textCharacterCount = textCharacterCount
        self.faceCount = faceCount
        self.largestFaceHeightFraction = largestFaceHeightFraction
        self.labels = labels
    }
}

/// Silent sorter: meme (in results), maybe (typed search only), skipped (personal photos, chat screenshots).
public enum MemeTierClassifier {
    /// Vision label fragments that make an otherwise plain image meme-like.
    private static let memeLabelFragments = ["cat", "dog", "animal", "cartoon", "illustration", "drawing", "comic", "meme"]

    /// 1. min(w, h) < 64 → skipped   2. animated → meme   3. screenshot && faceCount == 0 && text > 280 → skipped
    /// 4. camera photo → skipped     5. faceCount > 0 || text ≥ 8 → meme
    /// 6. any label contains cat, dog, animal, cartoon, illustration, drawing, comic, meme (case-insensitive) → meme   7. else → maybe
    public static func tier(for facts: ImageFacts) -> ItemTier {
        if min(facts.pixelWidth, facts.pixelHeight) < 64 { return .skipped }
        if facts.isAnimated { return .meme }
        if facts.isScreenshot && facts.faceCount == 0 && facts.textCharacterCount > 280 { return .skipped }
        if facts.isCameraPhoto { return .skipped }
        if facts.faceCount > 0 || facts.textCharacterCount >= 8 { return .meme }
        for label in facts.labels {
            let lowered = label.lowercased()
            for fragment in memeLabelFragments where lowered.contains(fragment) {
                return .meme
            }
        }
        return .maybe
    }
}

/// "Photos with people" setting for menu-bar drops.
public enum StickerPolicy: String, Codable, CaseIterable, Sendable {
    case automatic, ask, never
}

public enum StickerEligibility {
    /// Faces smaller than this fraction of the image height are not cut out.
    public static let minimumFaceHeightFraction: Double = 0.06

    /// [] when animated or text ≥ 8 characters (it's a meme, not a photo of people); else indices of faces with height fraction ≥ minimum.
    public static func eligibleFaceIndices(facts: ImageFacts, faceHeightFractions: [Double]) -> [Int] {
        if facts.isAnimated || facts.textCharacterCount >= 8 { return [] }
        var indices: [Int] = []
        for (index, fraction) in faceHeightFractions.enumerated() where fraction >= minimumFaceHeightFraction {
            indices.append(index)
        }
        return indices
    }
}
