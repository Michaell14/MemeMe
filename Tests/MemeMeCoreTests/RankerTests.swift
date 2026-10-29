import Foundation
import XCTest
@testable import MemeMeCore

final class RankerTests: XCTestCase {
    private let ranker = Ranker()

    private func sample(_ face: FaceFeatures?, pose: PoseFeatures? = nil) -> ExpressionSample {
        ExpressionSample(face: face, pose: pose, timestamp: 0)
    }

    private func intensity(_ face: FaceFeatures) -> Double {
        RestingBaseline().intensity(of: face)
    }

    private func names(_ results: [RankedResult]) -> [String] {
        results.map { $0.item.displayName }
    }

    // MARK: Expression

    func testExpressionOrdersByFaceSimilarity() {
        let surprise = makeItem(name: "surprise", face: TestFaces.surprise, intensity: intensity(TestFaces.surprise))
        let mild = makeItem(name: "mild", face: TestFaces.mildSurprise, intensity: intensity(TestFaces.mildSurprise))
        let smile = makeItem(name: "smile", face: TestFaces.smile, intensity: intensity(TestFaces.smile))
        let neutral = makeItem(name: "neutral", face: TestFaces.neutral, intensity: 0)
        let faceless = makeItem(name: "faceless", intensity: 0.5)

        let results = ranker.rank([faceless, neutral, smile, mild, surprise],
                                  query: .expression(sample(TestFaces.surprise), weights: .uniform))
        XCTAssertEqual(names(results), ["surprise", "mild", "smile", "neutral", "faceless"])
        XCTAssertEqual(results[0].score, 1.02, accuracy: 1e-9)       // 1 + 0.02 own
        XCTAssertEqual(results[0].id, surprise.id)
        XCTAssertNil(results[0].section)
        for index in 1..<results.count {
            XCTAssertGreaterThan(results[index - 1].score, results[index].score)
        }
    }

    func testExpressionScoreFormula() {
        let target = intensity(TestFaces.surprise)
        let pack = makeItem(name: "pack", kind: .pack, face: TestFaces.surprise, intensity: target)
        // featureSim 1; no body on either side → poseSim 1 (unknown, and no gesture to miss); fit 1 → 0.7 × 1 + 0.3
        XCTAssertEqual(ranker.expressionScore(item: pack, sample: sample(TestFaces.surprise), weights: .uniform), 1.0, accuracy: 1e-9)

        let handsUp = PoseFeatures(handsRaised: 1, armsSpread: 0, bodyVisible: 1)
        let posed = makeItem(name: "posed", kind: .pack, face: TestFaces.surprise, pose: handsUp, intensity: target)
        XCTAssertEqual(ranker.expressionScore(item: posed, sample: sample(TestFaces.surprise, pose: handsUp), weights: .uniform), 1.0, accuracy: 1e-9)
    }

    func testExpressionScoreWithoutFaces() {
        // No sample face: target intensity 0.3, score = 0.25 + 0.3 × fit.
        let faceless = makeItem(name: "faceless", kind: .pack, intensity: 0.3)
        XCTAssertEqual(ranker.expressionScore(item: faceless, sample: sample(nil), weights: .uniform), 0.55, accuracy: 1e-9)
        let other = makeItem(name: "other", kind: .pack, intensity: 0.5)
        XCTAssertEqual(ranker.expressionScore(item: other, sample: sample(nil), weights: .uniform), 0.49, accuracy: 1e-9)
        // No item face: the target is the sample's intensity.
        let expected = 0.25 + 0.3 * (1 - abs(0.5 - intensity(TestFaces.surprise)))
        XCTAssertEqual(ranker.expressionScore(item: other, sample: sample(TestFaces.surprise), weights: .uniform), expected, accuracy: 1e-9)
    }

    func testOwnSentAndWebAdjustments() {
        let target = intensity(TestFaces.surprise)
        func score(_ kind: ItemKind, timesSent: Int = 0) -> Double {
            let item = makeItem(name: "x", kind: kind, face: TestFaces.surprise, intensity: target, timesSent: timesSent)
            return self.ranker.expressionScore(item: item, sample: self.sample(TestFaces.surprise), weights: .uniform)
        }
        let pack = score(.pack)
        XCTAssertEqual(score(.mine) - pack, 0.02, accuracy: 1e-9)
        XCTAssertEqual(score(.friend) - pack, 0.02, accuracy: 1e-9)
        XCTAssertEqual(score(.web) - pack, -0.01, accuracy: 1e-9)
        XCTAssertEqual(score(.pack, timesSent: 2) - pack, 0.004, accuracy: 1e-9)
        XCTAssertEqual(score(.pack, timesSent: 5) - pack, 0.01, accuracy: 1e-9)
        XCTAssertEqual(score(.pack, timesSent: 50) - pack, 0.01, accuracy: 1e-9)
    }

    func testWeightsDecideWhichRegionMatters() {
        let query = makeFace(mouth: 0.65)
        let target = intensity(query)
        let mouthMatch = makeItem(name: "mouth", face: makeFace(brow: 0.1, eye: 0.1, mouth: 0.65), intensity: target)
        let restMatch = makeItem(name: "rest", face: TestFaces.neutral, intensity: target)
        let items = [mouthMatch, restMatch]

        let uniform = ranker.rank(items, query: .expression(sample(query), weights: .uniform))
        XCTAssertEqual(names(uniform), ["rest", "mouth"])

        let pinned = ranker.rank(items, query: .expression(sample(query), weights: FeatureWeights.uniform.pinning([.mouth])))
        XCTAssertEqual(names(pinned), ["mouth", "rest"])

        let inferred = FeatureWeights.automatic(deviation: RestingBaseline().deviation(of: query), poseStrength: 0)
        let automatic = ranker.rank(items, query: .expression(sample(query), weights: inferred))
        XCTAssertEqual(names(automatic), ["mouth", "rest"])
    }

    func testAtMostTwoFriendStickersInFaceResults() {
        let friends = (1...4).map {
            makeItem(name: "friend\($0)", kind: .friend, isSticker: true, face: TestFaces.surprise, intensity: intensity(TestFaces.surprise))
        }
        let mine = (1...3).map {
            makeItem(name: "mine\($0)", face: TestFaces.mildSurprise, intensity: intensity(TestFaces.mildSurprise))
        }
        let query = SearchQuery.expression(sample(TestFaces.surprise), weights: .uniform)

        let window = ranker.rank(friends + mine, query: query, limit: 4)
        XCTAssertEqual(window.count, 4)
        XCTAssertEqual(window.map { $0.item.kind }, [.friend, .friend, .mine, .mine])

        let all = ranker.rank(friends + mine, query: query)
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(all.filter { $0.item.kind == .friend }.count, 2)
    }

    func testFriendStickersWinExactTiesInFaceSearchOnly() {
        let target = intensity(TestFaces.surprise)
        let mine = makeItem(name: "mine", addedAt: TestDates.march20, face: TestFaces.surprise, intensity: target)
        let friend = makeItem(name: "friend", kind: .friend, addedAt: TestDates.march2, isSticker: true,
                              face: TestFaces.surprise, intensity: target)

        let faceResults = ranker.rank([mine, friend], query: .expression(sample(TestFaces.surprise), weights: .uniform))
        XCTAssertEqual(names(faceResults), ["friend", "mine"])
        XCTAssertEqual(faceResults[0].score, faceResults[1].score)

        // Typed search without a face stays newest first.
        let textResults = ranker.rank([friend, mine], query: .text("mine", face: nil, weights: .uniform))
        XCTAssertEqual(names(textResults), ["mine", "friend"])
    }

    func testExpressionUsesMemeTierOnlyAndRespectsTheLimit() {
        let face = TestFaces.surprise
        let target = intensity(face)
        let meme = makeItem(name: "meme", face: face, intensity: target)
        let maybe = makeItem(name: "maybe", tier: .maybe, face: face, intensity: target)
        let skipped = makeItem(name: "skipped", tier: .skipped, face: face, intensity: target)
        XCTAssertEqual(names(ranker.rank([maybe, skipped, meme], query: .expression(sample(face), weights: .uniform))), ["meme"])

        let many = (0..<12).map { makeItem(name: "m\($0)", face: face, intensity: target) }
        XCTAssertEqual(ranker.rank(many, query: .expression(sample(face), weights: .uniform)).count, 10)
        XCTAssertEqual(ranker.rank(many, query: .expression(sample(face), weights: .uniform), limit: 3).count, 3)
        XCTAssertTrue(ranker.rank(many, query: .expression(sample(face), weights: .uniform), limit: 0).isEmpty)
    }

    func testExpressionUsesTheRankersBaseline() {
        // For a user whose resting face has wide eyes, a wide-eyed item is neutral, not surprised.
        let wideEyed = makeFace(eye: 0.65)
        let custom = Ranker(baseline: RestingBaseline(neutral: wideEyed))
        XCTAssertEqual(custom.baseline.neutral, wideEyed)
        let item = makeItem(name: "x", kind: .pack, face: TestFaces.neutral, intensity: 0)
        // Query = the user's resting face → deviation 0 and target 0, matching a neutral item perfectly.
        XCTAssertEqual(custom.expressionScore(item: item, sample: sample(wideEyed), weights: .uniform), 1.0, accuracy: 1e-9)
    }

    // MARK: Face cues

    /// Tongue out: a tongue share of 0.6 reads as tongueOut 1 against fixed values (0.3 only as 0.4, not clear).
    private let tongueShape = FaceShape(tongue: 0.6)

    /// A pack item (no own bonus) whose `faceShape` shows `tongue` (nil: no shape).
    private func cueItem(_ name: String, face: FaceFeatures?, tongue: Double?, intensity: Double) -> LibraryItem {
        var item = makeItem(name: name, kind: .pack, face: face, intensity: intensity)
        item.faceShape = tongue.map { FaceShape(tongue: $0) }
        return item
    }

    func testATongueOutQueryPrefersMemesShowingATongue() {
        let openMouth = makeFace(mouth: 0.35)
        let target = intensity(openMouth)
        // The tongue meme's mouth is a little less open, so by the seven numbers alone the plain open mouth wins. (Its
        // name has none of the cue's words, so only its shape counts.)
        let tongue = cueItem("showing", face: makeFace(mouth: 0.2), tongue: 0.5, intensity: target)
        let plain = cueItem("plain", face: openMouth, tongue: 0.05, intensity: target)
        let unread = cueItem("unread", face: openMouth, tongue: nil, intensity: target)

        let plainQuery = ExpressionSample(face: openMouth, timestamp: 0)
        XCTAssertEqual(names(ranker.rank([tongue, plain], query: .expression(plainQuery, weights: .uniform))), ["plain", "showing"])

        let tongueQuery = ExpressionSample(face: openMouth, shape: tongueShape, timestamp: 0)
        let results = ranker.rank([plain, unread, tongue], query: .expression(tongueQuery, weights: .uniform))
        XCTAssertEqual(names(results), ["showing", "unread", "plain"])
        // v = 0.45 × 1; face similarity 29/30 (mouth 0.9) for the tongue, 1 for the others; pose 1; fit 1:
        // 0.7 × (0.85 × 0.55 × face + 0.15 + 0.85 × 0.45 × cue) + 0.3 with cue 1, unknown 0.5, 0.
        let tongueFace: Double = 29.0 / 30.0
        XCTAssertEqual(results[0].score, 0.7 * (0.4675 * tongueFace + 0.15 + 0.3825) + 0.3, accuracy: 1e-9)
        XCTAssertEqual(results[1].score, 0.866125, accuracy: 1e-9)
        XCTAssertEqual(results[2].score, 0.73225, accuracy: 1e-9)
    }

    func testATongueOutQueryPrefersMemesNamedForIt() {
        let openMouth = makeFace(mouth: 0.35)
        let target = intensity(openMouth)
        let cat = cueItem("cat", face: openMouth, tongue: nil, intensity: target)
        let named = cueItem("Tongue out", face: openMouth, tongue: nil, intensity: target)
        var tagged = cueItem("dog", face: openMouth, tongue: nil, intensity: target)
        tagged.labels = ["BLEP"]
        let tongueQuery = ExpressionSample(face: openMouth, shape: tongueShape, timestamp: 0)

        let catScore = ranker.expressionScore(item: cat, sample: tongueQuery, weights: .uniform)
        XCTAssertEqual(ranker.expressionScore(item: named, sample: tongueQuery, weights: .uniform) - catScore, 0.05, accuracy: 1e-9)
        XCTAssertEqual(ranker.expressionScore(item: tagged, sample: tongueQuery, weights: .uniform) - catScore, 0.05, accuracy: 1e-9)
        XCTAssertEqual(names(ranker.rank([cat, named], query: .expression(tongueQuery, weights: .uniform))), ["Tongue out", "cat"])
        // A meme without a readable face too: 0.25 + 0.3 × fit + 0.05.
        let faceless = cueItem("tongue out gif", face: nil, tongue: nil, intensity: 0.5)
        XCTAssertEqual(ranker.expressionScore(item: faceless, sample: tongueQuery, weights: .uniform),
                       0.25 + 0.3 * (1 - abs(0.5 - target)) + 0.05, accuracy: 1e-9)
        // Without the cue the name doesn't count.
        let plainQuery = ExpressionSample(face: openMouth, timestamp: 0)
        XCTAssertEqual(ranker.expressionScore(item: named, sample: plainQuery, weights: .uniform),
                       ranker.expressionScore(item: cat, sample: plainQuery, weights: .uniform))
    }

    func testWithoutAClearCueScoresAreUnchanged() {
        let openMouth = makeFace(mouth: 0.35)
        let target = intensity(openMouth)
        let items = [cueItem("tongue out", face: makeFace(mouth: 0.2), tongue: 0.5, intensity: target),
                     cueItem("plain", face: openMouth, tongue: 0.05, intensity: target),
                     cueItem("faceless", face: nil, tongue: nil, intensity: 0.5)]
        let plainQuery = ExpressionSample(face: openMouth, timestamp: 0)
        // A little tongue (0.4) isn't a clear cue; nor is 0.6 for someone whose resting face already reads 0.55.
        let littleTongue = ExpressionSample(face: openMouth, shape: FaceShape(tongue: 0.3), timestamp: 0)
        let tongueQuery = ExpressionSample(face: openMouth, shape: tongueShape, timestamp: 0)
        let rested = Ranker(baseline: RestingBaseline(restShape: FaceShape(tongue: 0.55)))
        for item in items {
            let plain = ranker.expressionScore(item: item, sample: plainQuery, weights: .uniform)
            XCTAssertEqual(ranker.expressionScore(item: item, sample: littleTongue, weights: .uniform), plain, item.displayName)
            XCTAssertEqual(rested.expressionScore(item: item, sample: tongueQuery, weights: .uniform), plain, item.displayName)
        }
    }

    func testCueWordsInNamesTextAndLabels() {
        XCTAssertTrue(Ranker.mentions(.tongueOut, in: makeItem(name: "dog blep")))
        XCTAssertTrue(Ranker.mentions(.wink, in: makeItem(name: "x", text: "WINKING")))
        XCTAssertTrue(Ranker.mentions(.raisedBrow, in: makeItem(name: "Raised Eyebrows")))
        XCTAssertTrue(Ranker.mentions(.pucker, in: makeItem(name: "kissy face")))
        XCTAssertTrue(Ranker.mentions(.smirk, in: makeItem(name: "x", labels: ["smirking"])))
        XCTAssertTrue(Ranker.mentions(.eyeRoll, in: makeItem(name: "Rolling eyes")))
        XCTAssertFalse(Ranker.mentions(.eyeRoll, in: makeItem(name: "roll safe")))
        XCTAssertFalse(Ranker.mentions(.wink, in: makeItem(name: "cat", source: "wink folder")))
    }

    // MARK: Text

    /// A small library spanning months, kinds and tiers.
    private struct TextLibrary {
        let sam: Person
        let dancingCat: LibraryItem
        let yawningCat: LibraryItem
        let sleepyCat: LibraryItem
        let catFacts: LibraryItem
        let samSticker: LibraryItem
        let packCat: LibraryItem
        let webCat: LibraryItem
        let catPhoto: LibraryItem

        var all: [LibraryItem] {
            [webCat, catPhoto, packCat, samSticker, catFacts, sleepyCat, yawningCat, dancingCat]
        }

        init() {
            let sam = Person(name: "Sam")
            self.sam = sam
            dancingCat = makeItem(name: "dancing cat", source: "Downloads", sourceDetail: "from reddit.com",
                                  modified: TestDates.march15, isAnimated: true)
            yawningCat = makeItem(name: "cat yawn", source: "Desktop", modified: TestDates.march2,
                                  face: TestFaces.surprise, intensity: RestingBaseline().intensity(of: TestFaces.surprise))
            sleepyCat = makeItem(name: "sleepy cat", source: "Screenshots", modified: TestDates.february10, text: "OMG so tired")
            catFacts = makeItem(name: "facts", tier: .maybe, source: "Downloads", modified: TestDates.january20, text: "cat facts")
            samSticker = makeItem(name: "Sam — happy", kind: .friend, source: "Friend sticker", sourceDetail: "IMG_2207.HEIC",
                                  addedAt: TestDates.march20, isSticker: true, labels: ["person"], personID: sam.id)
            packCat = makeItem(name: "cat pack", kind: .pack, source: "Starter pack")
            webCat = makeItem(name: "cat jump", kind: .web, source: "GIPHY", isAnimated: true, attribution: "via GIPHY")
            catPhoto = makeItem(name: "cat photo", tier: .skipped, source: "Desktop", modified: TestDates.march15)
        }
    }

    private func textSearch(_ text: String, in library: TextLibrary, face: FaceFeatures? = nil, limit: Int = 10) -> [RankedResult] {
        let faceSample = face.map { sample($0) }
        return ranker.rank(library.all, query: .text(text, face: faceSample, weights: .uniform), people: [library.sam], limit: limit)
    }

    func testTextGroupsOwnByMonthThenPacksThenWeb() {
        let library = TextLibrary()
        let results = textSearch("cat", in: library)
        XCTAssertEqual(names(results), ["dancing cat", "cat yawn", "sleepy cat", "facts", "cat pack", "cat jump"])
        XCTAssertEqual(results.map { $0.section ?? "" },
                       ["March 2026", "March 2026", "February 2026", "January 2026", "Packs", "From GIPHY"])
        XCTAssertFalse(results.contains { $0.item.tier == .skipped })     // enough hits: no fallback
    }

    func testTextOrdersByExpressionWhenAFaceIsHeld() {
        let library = TextLibrary()
        let results = textSearch("cat", in: library, face: TestFaces.surprise)
        // Inside March the surprised cat now wins over the newer one; the groups keep their order.
        XCTAssertEqual(names(results), ["cat yawn", "dancing cat", "sleepy cat", "facts", "cat pack", "cat jump"])
        XCTAssertEqual(results[0].score, 1.02, accuracy: 1e-9)
        XCTAssertEqual(results[0].section, "March 2026")
    }

    func testTextLimit() {
        let results = textSearch("cat", in: TextLibrary(), limit: 3)
        XCTAssertEqual(names(results), ["dancing cat", "cat yawn", "sleepy cat"])
    }

    func testTextFilterMine() {
        let results = textSearch("mine", in: TextLibrary())
        XCTAssertEqual(names(results), ["Sam — happy", "dancing cat", "cat yawn", "sleepy cat", "facts"])
        XCTAssertTrue(results.allSatisfy { $0.item.isOwn })
    }

    func testTextFilterGIFs() {
        let library = TextLibrary()
        let results = textSearch("gif", in: library)
        XCTAssertEqual(names(results), ["dancing cat", "cat jump"])
        XCTAssertEqual(results.map { $0.section ?? "" }, ["March 2026", "From GIPHY"])
        XCTAssertEqual(names(textSearch("cat gifs", in: library)), ["dancing cat", "cat jump"])
        XCTAssertEqual(names(textSearch("dancing GIF", in: library)), ["dancing cat"])
    }

    func testTextFilterStickers() {
        XCTAssertEqual(names(textSearch("stickers", in: TextLibrary())), ["Sam — happy"])
    }

    func testTextFilterByPersonName() {
        let library = TextLibrary()
        XCTAssertEqual(names(textSearch("sam", in: library)), ["Sam — happy"])
        XCTAssertEqual(names(textSearch("SAM happy", in: library)), ["Sam — happy"])
        XCTAssertTrue(textSearch("sam cat", in: library).isEmpty)
    }

    func testTextMatchesOCRLabelsSourcesAndDetails() {
        let library = TextLibrary()
        XCTAssertEqual(names(textSearch("omg", in: library)), ["sleepy cat"])
        XCTAssertEqual(names(textSearch("person", in: library)), ["Sam — happy"])
        XCTAssertEqual(names(textSearch("screenshots", in: library)), ["sleepy cat"])
        XCTAssertEqual(names(textSearch("reddit", in: library)), ["dancing cat"])
        XCTAssertEqual(names(textSearch("img_2207", in: library)), ["Sam — happy"])
        XCTAssertTrue(textSearch("zebra", in: library).isEmpty)
    }

    func testTextMatchesAPersonsNameOnTheirStickers() {
        let jordan = Person(name: "Jordan")
        let sticker = makeItem(name: "New face — happy", kind: .friend, isSticker: true, personID: jordan.id)
        let other = makeItem(name: "other")
        let results = ranker.rank([other, sticker], query: .text("jord", face: nil, weights: .uniform), people: [jordan])
        XCTAssertEqual(names(results), ["New face — happy"])
    }

    func testTextFallsBackToSkippedPhotosWhenThereAreFewHits() {
        let library = TextLibrary()
        let photos = textSearch("photo", in: library)
        XCTAssertEqual(names(photos), ["cat photo"])
        XCTAssertEqual(photos.first?.section, "From your photos")

        let day = makeItem(name: "beach day", modified: TestDates.march15)
        let older = makeItem(name: "beach 1", tier: .skipped, modified: TestDates.january20)
        let newer = makeItem(name: "beach 2", tier: .skipped, modified: TestDates.february10)
        let few = ranker.rank([older, day, newer], query: .text("beach", face: nil, weights: .uniform))
        XCTAssertEqual(names(few), ["beach day", "beach 2", "beach 1"])
        XCTAssertEqual(few.map { $0.section ?? "" }, ["March 2026", "From your photos", "From your photos"])

        let plenty = [day,
                      makeItem(name: "beach night", modified: TestDates.march2),
                      makeItem(name: "beach dog", modified: TestDates.march20),
                      older, newer]
        let many = ranker.rank(plenty, query: .text("beach", face: nil, weights: .uniform))
        XCTAssertEqual(names(many), ["beach dog", "beach day", "beach night"])
    }

    // MARK: Image and more-like-this

    func testImageQueryUsesFingerprints() {
        let close = makeItem(name: "close", kind: .pack, featurePrint: [1, 0, 0])
        let orthogonal = makeItem(name: "orthogonal", kind: .pack, featurePrint: [0, 1, 0])
        let opposite = makeItem(name: "opposite", kind: .pack, featurePrint: [-1, 0, 0])
        let unknown = makeItem(name: "unknown", kind: .web)
        let skipped = makeItem(name: "skipped", tier: .skipped, featurePrint: [1, 0, 0])

        let results = ranker.rank([opposite, unknown, orthogonal, close, skipped],
                                  query: .image(featurePrint: [1, 0, 0], face: nil, intensity: 0))
        XCTAssertEqual(names(results), ["close", "orthogonal", "unknown", "opposite"])
        let scores = results.map { $0.score }
        XCTAssertEqual(scores[0], 0.85, accuracy: 1e-9)    // 0.7 × 1 + 0.3 × 0.5
        XCTAssertEqual(scores[1], 0.5, accuracy: 1e-9)     // 0.7 × 0.5 + 0.15
        XCTAssertEqual(scores[2], 0.49, accuracy: 1e-9)    // no print: 0.5, web −0.01
        XCTAssertEqual(scores[3], 0.15, accuracy: 1e-9)
    }

    func testImageQueryFaceSimilarityBreaksFingerprintTies() {
        let same = makeItem(name: "same", kind: .pack, face: TestFaces.surprise, featurePrint: [1, 0])
        let other = makeItem(name: "other", kind: .pack, face: TestFaces.smile, featurePrint: [1, 0])
        let results = ranker.rank([other, same], query: .image(featurePrint: [1, 0], face: TestFaces.surprise, intensity: 0.5))
        XCTAssertEqual(names(results), ["same", "other"])
        // Face similarity of surprise vs smile: regions brows 0.6, eyes 0.8, mouth 2/15 → mean 23/45.
        let faceSimilarity: Double = 23.0 / 45.0
        XCTAssertEqual(results[0].score, 1.0, accuracy: 1e-9)
        XCTAssertEqual(results[1].score, 0.7 + 0.3 * faceSimilarity, accuracy: 1e-9)
    }

    func testMoreLikeThisExcludesTheReference() {
        let surpriseIntensity = intensity(TestFaces.surprise)
        let reference = makeItem(name: "reference", face: TestFaces.surprise, intensity: surpriseIntensity, featurePrint: [1, 0, 0])
        let twin = makeItem(name: "twin", kind: .pack, face: TestFaces.surprise, intensity: surpriseIntensity, featurePrint: [1, 0, 0])
        let different = makeItem(name: "different", kind: .pack, face: TestFaces.smile, intensity: intensity(TestFaces.smile), featurePrint: [0, 1, 0])
        let bare = makeItem(name: "bare", kind: .pack)
        let maybe = makeItem(name: "maybe", tier: .maybe, face: TestFaces.surprise, intensity: surpriseIntensity, featurePrint: [1, 0, 0])

        let results = ranker.rank([reference, maybe, different, twin, bare], query: .moreLike(reference))
        XCTAssertFalse(results.contains { $0.id == reference.id })
        XCTAssertEqual(names(results), ["twin", "different", "bare"])
        let faceSimilarity: Double = 23.0 / 45.0
        let differentFit: Double = 1 - abs(intensity(TestFaces.smile) - surpriseIntensity)
        let differentScore: Double = 0.3 + 0.3 * faceSimilarity + 0.1 * differentFit     // fingerprint 0.5 × 0.6 = 0.3
        let bareScore: Double = 0.3 + 0.15 + 0.1 * (1 - surpriseIntensity)                 // no print, no face: 0.5 each
        XCTAssertEqual(results[0].score, 1.0, accuracy: 1e-9)
        XCTAssertEqual(results[1].score, differentScore, accuracy: 1e-9)
        XCTAssertEqual(results[2].score, bareScore, accuracy: 1e-9)
    }

    // MARK: Recent

    func testRecentListsRecentsThenNewestOwnMemes() {
        let a = makeItem(name: "a", addedAt: TestDates.january20)
        let b = makeItem(name: "b", addedAt: TestDates.january20, lastSentAt: TestDates.february10)
        let c = makeItem(name: "c", tier: .maybe, addedAt: TestDates.january20)
        let d = makeItem(name: "d", kind: .web, addedAt: TestDates.september5)
        let e = makeItem(name: "e", tier: .skipped)
        let f = makeItem(name: "f", addedAt: TestDates.march20)
        let g = makeItem(name: "g", addedAt: TestDates.march2)
        let h = makeItem(name: "h", kind: .friend, addedAt: TestDates.march15, isSticker: true)
        let items = [a, b, c, d, e, f, g, h]
        let recents = [c.id, e.id, UUID(), a.id, c.id]

        let results = ranker.rank(items, query: .recent(appBundleID: "com.apple.MobileSMS"), recents: recents)
        XCTAssertEqual(names(results), ["c", "a", "b", "f", "h", "g"])
        XCTAssertTrue(results.allSatisfy { $0.score == 1 })
        XCTAssertTrue(results.allSatisfy { $0.section == nil })

        XCTAssertEqual(names(ranker.rank(items, query: .recent(appBundleID: nil), recents: recents, limit: 3)), ["c", "a", "b"])
        XCTAssertEqual(names(ranker.rank(items, query: .recent(appBundleID: nil), recents: recents, limit: 1)), ["c"])
    }

    func testRecentWithoutHistoryShowsNewestOwnMemes() {
        let older = makeItem(name: "older", addedAt: TestDates.february10)
        let newer = makeItem(name: "newer", addedAt: TestDates.march15)
        let web = makeItem(name: "web", kind: .web, addedAt: TestDates.september5)
        XCTAssertEqual(names(ranker.rank([older, web, newer], query: .recent(appBundleID: nil))), ["newer", "older"])
        XCTAssertTrue(ranker.rank([], query: .recent(appBundleID: nil), recents: [UUID()]).isEmpty)
    }

    func testRankedResultIdentity() {
        let item = makeItem(name: "x")
        let result = RankedResult(item: item, score: 0.7)
        XCTAssertEqual(result.id, item.id)
        XCTAssertNil(result.section)
        XCTAssertEqual(RankedResult(item: item, score: 0.7, section: "Packs").section, "Packs")
    }
}
