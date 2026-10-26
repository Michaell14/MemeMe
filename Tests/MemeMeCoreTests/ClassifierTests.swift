import Foundation
import XCTest
@testable import MemeMeCore

final class ClassifierTests: XCTestCase {
    private func facts(width: Int = 500, height: Int = 500, animated: Bool = false, camera: Bool = false,
                       screenshot: Bool = false, text: Int = 0, faces: Int = 0, faceHeight: Double = 0,
                       labels: [String] = []) -> ImageFacts {
        ImageFacts(pixelWidth: width, pixelHeight: height, isAnimated: animated, isCameraPhoto: camera,
                   isScreenshot: screenshot, textCharacterCount: text, faceCount: faces,
                   largestFaceHeightFraction: faceHeight, labels: labels)
    }

    private func tier(_ facts: ImageFacts) -> ItemTier {
        MemeTierClassifier.tier(for: facts)
    }

    func testRule1TinyImagesAreSkipped() {
        XCTAssertEqual(tier(facts(width: 63, height: 500, animated: true)), .skipped)
        XCTAssertEqual(tier(facts(width: 500, height: 40, faces: 1)), .skipped)
        XCTAssertEqual(tier(facts(width: 64, height: 64, faces: 1)), .meme)
    }

    func testRule2AnimatedImagesAreMemes() {
        XCTAssertEqual(tier(facts(animated: true, camera: true)), .meme)
        XCTAssertEqual(tier(facts(animated: true, screenshot: true, text: 1_000)), .meme)
    }

    func testRule3TextHeavyScreenshotsWithoutFacesAreSkipped() {
        XCTAssertEqual(tier(facts(screenshot: true, text: 281)), .skipped)
        XCTAssertEqual(tier(facts(screenshot: true, text: 280)), .meme)              // rule 5: text ≥ 8
        XCTAssertEqual(tier(facts(screenshot: true, text: 500, faces: 1)), .meme)    // has a face
        XCTAssertEqual(tier(facts(text: 500)), .meme)                                 // not a screenshot
    }

    func testRule4CameraPhotosAreSkipped() {
        XCTAssertEqual(tier(facts(camera: true, faces: 2, faceHeight: 0.4)), .skipped)
        XCTAssertEqual(tier(facts(camera: true, labels: ["cat"])), .skipped)
    }

    func testRule5FacesOrTextMakeAMeme() {
        XCTAssertEqual(tier(facts(faces: 1)), .meme)
        XCTAssertEqual(tier(facts(text: 8)), .meme)
        XCTAssertEqual(tier(facts(text: 7)), .maybe)
    }

    func testRule6MemeLikeLabels() {
        for label in ["Cartoon", "domestic_cat", "DOG", "Illustrations", "comic_book", "internet meme", "animal", "drawing"] {
            XCTAssertEqual(tier(facts(labels: ["sky", label])), .meme, label)
        }
        XCTAssertEqual(tier(facts(labels: ["structure", "sky", "document"])), .maybe)
    }

    func testRule7EverythingElseIsMaybe() {
        XCTAssertEqual(tier(facts()), .maybe)
    }

    func testStickerEligibility() {
        XCTAssertEqual(StickerEligibility.minimumFaceHeightFraction, 0.06)
        let photo = facts(faces: 3)
        XCTAssertEqual(StickerEligibility.eligibleFaceIndices(facts: photo, faceHeightFractions: [0.05, 0.06, 0.2]), [1, 2])
        XCTAssertEqual(StickerEligibility.eligibleFaceIndices(facts: photo, faceHeightFractions: []), [])
        XCTAssertEqual(StickerEligibility.eligibleFaceIndices(facts: facts(text: 7, faces: 1), faceHeightFractions: [0.3]), [0])
        XCTAssertEqual(StickerEligibility.eligibleFaceIndices(facts: facts(text: 8, faces: 1), faceHeightFractions: [0.3]), [])
        XCTAssertEqual(StickerEligibility.eligibleFaceIndices(facts: facts(animated: true, faces: 1), faceHeightFractions: [0.3]), [])
    }

    func testStickerPolicy() {
        XCTAssertEqual(StickerPolicy.allCases, [.automatic, .ask, .never])
        XCTAssertEqual(StickerPolicy.automatic.rawValue, "automatic")
    }

    func testImageFactsCodable() throws {
        let original = facts(width: 640, height: 480, screenshot: true, text: 12, faces: 1, faceHeight: 0.25, labels: ["cat"])
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(ImageFacts.self, from: data), original)
    }
}
