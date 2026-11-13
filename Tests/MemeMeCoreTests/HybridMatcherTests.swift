import Foundation
import XCTest
@testable import MemeMeCore

final class HybridMatcherTests: XCTestCase {
    // MARK: prob_sim

    func testProbSimIsOneMinusTotalVariationDistance() {
        XCTAssertEqual(HybridMatcher.probSim([0.2, 0.3, 0.5], [0.2, 0.3, 0.5]), 1, accuracy: 1e-12)
        XCTAssertEqual(HybridMatcher.probSim([1, 0, 0], [0, 1, 0]), 0, accuracy: 1e-12)
        // |0.5 − 0.2| + |0.5 − 0.8| = 0.6 → 1 − 0.3
        XCTAssertEqual(HybridMatcher.probSim([0.5, 0.5], [0.2, 0.8]), 0.7, accuracy: 1e-12)
        XCTAssertEqual(HybridMatcher.probSim([0.1, 0.9], [0.9, 0.1]), HybridMatcher.probSim([0.9, 0.1], [0.1, 0.9]))
        XCTAssertEqual(HybridMatcher.probSim([0.5, 0.5], [1]), 0)
        XCTAssertEqual(HybridMatcher.probSim([], []), 0)
    }

    // MARK: score

    func testWeightIsTheBenchmarksW() {
        XCTAssertEqual(HybridMatcher.expressionWeight, 0.2)
    }

    func testScoreIsEightTenthsVisualPlusTwoTenthsExpression() {
        let q = unit(0)
        let m = normalized([1, 1])   // cosine with q: 1/√2
        let query = HybridQuery(full: q, emotion: oneHot(4, 8), zeroShot: oneHot(3, 7))
        let emo: [Double] = [0, 0, 0, 0, 0.6, 0.4, 0, 0]
        let entry = HybridIndexEntry(key: "a", contentHash: "h", clipFull: m, hasFace: true, emo: emo, zs: oneHot(0, 7))
        let visual = (1 / 2.0.squareRoot() + 1) / 2
        let expression = 1 - 0.5 * (0.4 + 0.4)   // q_emo vs emo
        XCTAssertEqual(HybridMatcher.visual(q, m), visual, accuracy: 1e-6)
        XCTAssertEqual(HybridMatcher.expression(query: query, entry: entry), expression, accuracy: 1e-12)
        XCTAssertEqual(HybridMatcher.score(query: query, entry: entry), 0.8 * visual + 0.2 * expression, accuracy: 1e-6)
        // Identical images and expressions score 1; opposite embeddings with disjoint expressions score 0.
        let same = HybridIndexEntry(key: "b", contentHash: "h", clipFull: q, hasFace: true, emo: oneHot(4, 8), zs: oneHot(3, 7))
        XCTAssertEqual(HybridMatcher.score(query: query, entry: same), 1, accuracy: 1e-6)
        let opposite = HybridIndexEntry(key: "c", contentHash: "h", clipFull: q.map { -$0 }, hasFace: true,
                                        emo: oneHot(0, 8), zs: oneHot(3, 7))
        XCTAssertEqual(HybridMatcher.score(query: query, entry: opposite), 0, accuracy: 1e-6)
    }

    func testRankSortsByScoreAndKeepsOrderOnTies() {
        let query = HybridQuery(full: unit(0), emotion: oneHot(4, 8), zeroShot: oneHot(3, 7))
        let near = HybridIndexEntry(key: "near", contentHash: "", clipFull: unit(0), hasFace: false, emo: nil, zs: oneHot(3, 7))
        let far = HybridIndexEntry(key: "far", contentHash: "", clipFull: unit(1), hasFace: false, emo: nil, zs: oneHot(3, 7))
        let twin = HybridIndexEntry(key: "twin", contentHash: "", clipFull: unit(1), hasFace: false, emo: nil, zs: oneHot(3, 7))
        let ranked = HybridMatcher.rank([far, near, twin], query: query)
        XCTAssertEqual(ranked.map(\.entry.key), ["near", "far", "twin"])
        XCTAssertGreaterThan(ranked[0].score, ranked[1].score)
    }

    // MARK: no face → zero-shot

    func testMemesWithoutAFaceUseTheZeroShotPath() {
        let query = HybridQuery(full: unit(0), emotion: oneHot(4, 8), zeroShot: oneHot(6, 7))   // happy face, zs: surprise
        // Emotion probabilities given for a meme without a face are ignored (and not stored).
        let noFace = HybridIndexEntry(key: "n", contentHash: "", clipFull: unit(0), hasFace: false, emo: oneHot(4, 8),
                                      zs: oneHot(6, 7))
        XCTAssertNil(noFace.emo)
        XCTAssertEqual(HybridMatcher.expression(query: query, entry: noFace), 1, accuracy: 1e-12)
        let noFaceOtherMood = HybridIndexEntry(key: "m", contentHash: "", clipFull: unit(0), hasFace: false, emo: nil,
                                               zs: oneHot(0, 7))
        XCTAssertEqual(HybridMatcher.expression(query: query, entry: noFaceOtherMood), 0, accuracy: 1e-12)
        // With a face the emotion model decides, whatever the zero-shot says.
        let face = HybridIndexEntry(key: "f", contentHash: "", clipFull: unit(0), hasFace: true, emo: oneHot(4, 8),
                                    zs: oneHot(0, 7))
        XCTAssertEqual(HybridMatcher.expression(query: query, entry: face), 1, accuracy: 1e-12)
        XCTAssertEqual(HybridMatcher.rank([noFaceOtherMood, noFace], query: query).first?.entry.key, "n")
    }

    // MARK: zero-shot and softmax

    func testSoftmaxAndZeroShot() {
        let p = HybridMatcher.softmax([1, 2, 3])
        XCTAssertEqual(p.reduce(0, +), 1, accuracy: 1e-12)
        XCTAssertEqual(p[2] / p[1], M_E, accuracy: 1e-9)
        XCTAssertEqual(HybridMatcher.softmax([1000, 1000]), [0.5, 0.5])
        let prompts = EmotionPrompts(classes: EmotionPrompts.expectedClasses, prompts: Array(repeating: "", count: 7),
                                     embeddings: (0..<7).map { unit($0) })
        let zs = HybridMatcher.zeroShot(embedding: unit(3), prompts: prompts)
        // softmax(100 · [0,0,0,1,0,0,0]): e^100 against six e^0
        XCTAssertEqual(zs[3], 1 / (1 + 6 * exp(-100)), accuracy: 1e-12)
        XCTAssertEqual(zs.reduce(0, +), 1, accuracy: 1e-12)
    }

    func testCommittedPromptEmbeddingsLoad() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Hybrid/emotion_prompts.json")
        let prompts = try XCTUnwrap(EmotionPrompts.load(from: url))
        XCTAssertEqual(prompts.scale, 100)
        XCTAssertEqual(prompts.prompts.first, "a photo of a angry face")
        XCTAssertEqual(prompts.prompts.last, "a photo of a surprised, shocked face")
        for row in prompts.embeddings {
            XCTAssertEqual(row.reduce(0) { $0 + Double($1) * Double($1) }, 1, accuracy: 1e-4)
        }
    }

    // MARK: words

    func testEmotionWords() {
        let expected: [HSEmotionClass: Mood] = [
            .surprise: .shocked, .happiness: .happy, .anger: .angry, .sadness: .sad,
            .disgust: .disgusted, .fear: .scared, .neutral: .unimpressed, .contempt: .unimpressed,
        ]
        for c in HSEmotionClass.allCases { XCTAssertEqual(c.mood, expected[c], c.name) }
        XCTAssertEqual(HSEmotionClass.allCases.map(\.name),
                       ["anger", "contempt", "disgust", "fear", "happiness", "neutral", "sadness", "surprise"])
        XCTAssertEqual(HSEmotionClass.top(of: [0, 0, 0, 0.1, 0.2, 0.6, 0.1, 0]), .neutral)
        XCTAssertNil(HSEmotionClass.top(of: [1, 0]))
        XCTAssertEqual(Mood.disgusted.searchQuery, "disgusted reaction")
        XCTAssertEqual(Mood.scared.label, "scared")
    }

    func testRoutingLeavesPosesAndFaceDetailsToTheRules() {
        let baseline = RestingBaseline()
        let emotion = oneHot(4, 8)
        let face = FaceFeatures.populationNeutral
        let plain = ExpressionSample(face: face, timestamp: 1, emotion: emotion)
        XCTAssertTrue(HybridRouting.usesHybrid(plain, baseline: baseline))
        XCTAssertEqual(HybridRouting.mood(for: plain, baseline: baseline, hybrid: true), .happy)
        XCTAssertEqual(HybridRouting.mood(for: plain, baseline: baseline, hybrid: false),
                       MoodClassifier.mood(for: face, pose: nil, baseline: baseline))
        // No emotion reading (the models aren't there) or no face: the rules.
        XCTAssertFalse(HybridRouting.usesHybrid(ExpressionSample(face: face, timestamp: 1), baseline: baseline))
        XCTAssertFalse(HybridRouting.usesHybrid(ExpressionSample(face: nil, timestamp: 1, emotion: emotion), baseline: baseline))
        // By default a face detail never routes (only a clear pose does); its word shows either way.
        let tongue = ExpressionSample(face: face, shape: FaceShape(tongue: 0.9), timestamp: 1, emotion: emotion)
        XCTAssertEqual(baseline.cues(of: tongue.shape).clearCue, .tongueOut)
        XCTAssertTrue(HybridRouting.routedCues.isEmpty)
        XCTAssertTrue(HybridRouting.usesHybrid(tongue, baseline: baseline, cueHeld: true))
        // Routing the details the hybrid can't represent: held, the rule ranker; a single frame, the hybrid.
        let routed = HybridRouting.unrepresentableCues
        XCTAssertFalse(HybridRouting.usesHybrid(tongue, baseline: baseline, cueHeld: true, routing: routed))
        XCTAssertTrue(HybridRouting.usesHybrid(tongue, baseline: baseline, cueHeld: false, routing: routed))
        XCTAssertEqual(HybridRouting.mood(for: tongue, baseline: baseline, hybrid: true, cueHeld: true), .tongueOut)
        XCTAssertEqual(HybridRouting.mood(for: tongue, baseline: baseline, hybrid: true, cueHeld: false), .tongueOut)
        // A smirk always goes to the hybrid, and the field still says "smirk".
        let smirk = ExpressionSample(face: face, shape: FaceShape(cornerTilt: 0.3), timestamp: 1, emotion: emotion)
        XCTAssertEqual(baseline.cues(of: smirk.shape).clearCue, .smirk)
        XCTAssertTrue(HybridRouting.usesHybrid(smirk, baseline: baseline, cueHeld: true, routing: routed))
        XCTAssertEqual(HybridRouting.mood(for: smirk, baseline: baseline, hybrid: true), .smirk)
        XCTAssertEqual(routed, [.tongueOut, .wink, .pucker, .eyeRoll])
    }

    func testCueHistoryTellsAHeldDetailFromOneFrame() {
        var history = CueHistory()
        // 10 frames a second: no cue, then a tongue out for 0.4 s, then one frame of a wink.
        history.observe(nil, at: 0.0)
        for (i, t) in [0.1, 0.2, 0.3, 0.4, 0.5].enumerated() { history.observe(i < 5 ? .tongueOut : nil, at: t) }
        history.observe(.wink, at: 0.6)
        history.observe(nil, at: 0.7)
        XCTAssertTrue(history.isHeld(.tongueOut, at: 0.3))           // 0.1 ... 0.5
        XCTAssertTrue(history.isHeld(.tongueOut, at: 0.1))
        XCTAssertFalse(history.isHeld(.tongueOut, at: 0.1, for: 0.6))
        XCTAssertFalse(history.isHeld(.wink, at: 0.6))               // one frame
        XCTAssertFalse(history.isHeld(.wink, at: 0.3))               // another cue then
        XCTAssertFalse(history.isHeld(.tongueOut, at: 9))            // unknown frame
        history.observe(nil, at: 10)                                 // older than the window: forgotten
        XCTAssertFalse(history.isHeld(.tongueOut, at: 0.3))
    }

    func testMetersShowTheEmotionWords() {
        // contempt 0.1 + neutral 0.3 read together as "Unimpressed".
        let cues = HeldFaceReading.emotionCues([0.05, 0.1, 0.0, 0.05, 0.45, 0.3, 0.05, 0.0])
        XCTAssertEqual(cues.map(\.label), ["Happy", "Unimpressed", "Angry", "Scared"])
        XCTAssertEqual(cues.map(\.level), [2, 2, 0, 0])
        XCTAssertTrue(cues.allSatisfy { $0.region == nil })
        XCTAssertEqual(HeldFaceReading.emotionCues([1]), [])
    }

    func testMatchingModelSettingDefaultsToHybridAndDecodesLeniently() throws {
        XCTAssertEqual(AppSettings().matchingModel, .hybrid)
        var settings = AppSettings()
        settings.matchingModel = .classic
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.matchingModel, .classic)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"openAtLogin": false}"#.utf8))
        XCTAssertEqual(old.matchingModel, .hybrid)
        let odd = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"matchingModel": "clip-l14"}"#.utf8))
        XCTAssertEqual(odd.matchingModel, .hybrid)
    }

    // MARK: index

    func testIndexSavesAndLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(HybridIndex.fileName)
        XCTAssertEqual(HybridIndex.load(from: url).count, 0)   // no file yet

        let face = HybridIndexEntry(key: "A", contentHash: "h1", clipFull: unit(5), hasFace: true, emo: oneHot(7, 8), zs: oneHot(6, 7))
        let cartoon = HybridIndexEntry(key: HybridIndex.templateKey("61579"), contentHash: "https://i.imgflip.com/1bij.jpg",
                                       clipFull: normalized((0..<512).map { Float($0 % 7) - 3 }), hasFace: false, emo: nil,
                                       zs: HybridMatcher.softmax([1, 2, 3, 4, 5, 6, 7]))
        var index = HybridIndex(entries: [face, cartoon])
        try index.save(to: url)
        let loaded = HybridIndex.load(from: url)
        XCTAssertEqual(loaded, index)
        XCTAssertEqual(loaded[cartoon.key]?.clipFull, cartoon.clipFull)   // base64 Float32 round-trips exactly
        XCTAssertTrue(HybridIndex.isTemplateKey(cartoon.key))
        XCTAssertFalse(loaded.needsIndexing(key: "A", contentHash: "h1"))
        XCTAssertTrue(loaded.needsIndexing(key: "A", contentHash: "h2"))
        XCTAssertTrue(loaded.needsIndexing(key: "B", contentHash: "h1"))

        // Gone items leave; templates are kept by a library pass.
        XCTAssertEqual(index.retain(keys: [], where: { !HybridIndex.isTemplateKey($0) }), 1)
        XCTAssertNil(index["A"])
        XCTAssertNotNil(index[cartoon.key])

        // Another model's index, or a damaged file, loads empty; a malformed entry is dropped.
        var other = HybridIndex(modelRevision: "other", entries: [face])
        try other.save(to: url)
        XCTAssertEqual(HybridIndex.load(from: url).count, 0)
        other.modelRevision = HybridIndex.currentModelRevision
        other.upsert(HybridIndexEntry(key: "short", contentHash: "", clipFull: [1, 0], hasFace: false, emo: nil, zs: oneHot(0, 7)))
        try other.save(to: url)
        XCTAssertEqual(HybridIndex.load(from: url).count, 1)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(HybridIndex.load(from: url).count, 0)
    }

    // MARK: preprocessing (Pillow / torchvision)

    func testBicubicResizeMatchesPillow() {
        let image = pattern(width: 9, height: 6)
        // PIL: Image.fromarray(a).resize((4, 3), Image.BICUBIC)
        XCTAssertEqual(image.resizedBicubic(width: 4, height: 3).pixels, [
            83, 12, 230, 140, 117, 181, 131, 157, 127, 90, 120, 78, 110, 26, 197, 102, 131, 148, 137, 171, 94, 129, 134,
            41, 149, 39, 163, 108, 144, 114, 99, 184, 57, 156, 147, 59,
        ])
        XCTAssertEqual(Array(image.resizedBicubic(width: 13, height: 8).pixels.prefix(30)), [
            0, 0, 255, 12, 4, 246, 41, 20, 228, 66, 48, 212, 92, 89, 196, 117, 151, 180, 143, 208, 164, 179, 99, 148, 221,
            114, 132, 221, 213, 116,
        ])
        XCTAssertEqual(Array(image.resizedBicubic(width: 5, height: 10).pixels.prefix(30)), [
            9, 3, 246, 73, 68, 207, 151, 155, 164, 189, 153, 121, 18, 98, 82, 44, 6, 240, 120, 71, 201, 168, 158, 158, 127,
            156, 115, 52, 101, 76,
        ])
        XCTAssertEqual(image.resizedBicubic(width: 9, height: 6), image)
    }

    func testModelInputs() {
        let wide = pattern(width: 300, height: 200)
        let clip = HybridPreprocess.clipInput(wide)
        XCTAssertEqual(clip.count, 3 * 224 * 224)
        let hse = HybridPreprocess.emotionInput(wide)
        XCTAssertEqual(hse.count, 3 * 224 * 224)
        // A flat grey picture normalizes to (0.5 − mean) / std per channel.
        let grey = RGBImage(width: 10, height: 20, pixels: Array(repeating: 128, count: 600))
        let t = HybridPreprocess.emotionInput(grey)
        XCTAssertEqual(t[0], (128 / 255 - 0.485) / 0.229, accuracy: 1e-6)
        XCTAssertEqual(t[224 * 224], (128 / 255 - 0.456) / 0.224, accuracy: 1e-6)
        XCTAssertEqual(t[2 * 224 * 224], (128 / 255 - 0.406) / 0.225, accuracy: 1e-6)
    }

    func testFaceCropFollowsTheBenchmark() {
        // A 100 × 80 box at (50, 40) in a 400 × 300 picture: margin 15 on every side.
        XCTAssertEqual(HybridPreprocess.faceCrop(x1: 50.7, y1: 40.2, x2: 150.9, y2: 120.5, imageWidth: 400, imageHeight: 300),
                       PixelRect(x0: 35, y0: 25, x1: 165, y1: 135))
        // Clipped to the picture.
        XCTAssertEqual(HybridPreprocess.faceCrop(x1: -5, y1: 10, x2: 60, y2: 70, imageWidth: 64, imageHeight: 64),
                       PixelRect(x0: 0, y0: 1, x1: 64, y1: 64))
        // Under 12 px: no face.
        XCTAssertNil(HybridPreprocess.faceCrop(x1: 0, y1: 0, x2: 11, y2: 40, imageWidth: 64, imageHeight: 64))
        // Vision's box (origin bottom-left, normalized) lands on the same pixels.
        XCTAssertEqual(HybridPreprocess.faceCrop(visionBox: 0.125, y: 0.6, width: 0.25, height: 0.2, imageWidth: 400, imageHeight: 300),
                       HybridPreprocess.faceCrop(x1: 50, y1: 60, x2: 150, y2: 120, imageWidth: 400, imageHeight: 300))
    }

    func testFourChannelPixelsLoseTheirFourthByte() {
        let bgra: [UInt8] = [1, 2, 3, 255, 4, 5, 6, 0]
        let image = bgra.withUnsafeBytes { RGBImage(fourChannel: $0, width: 2, height: 1, bytesPerRow: 8, bgra: true) }
        XCTAssertEqual(image.pixels, [3, 2, 1, 6, 5, 4])
        let cropped = pattern(width: 9, height: 6).cropped(to: PixelRect(x0: 2, y0: 1, x1: 5, y1: 3))
        XCTAssertEqual(cropped.width, 3)
        XCTAssertEqual(Array(cropped.pixels.prefix(3)), Array(pattern(width: 9, height: 6).pixels[(9 + 2) * 3..<(9 + 2) * 3 + 3]))
    }

    // MARK: helpers

    private func unit(_ i: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 512)
        v[i] = 1
        return v
    }

    private func normalized(_ head: [Float]) -> [Float] {
        var v = [Float](repeating: 0, count: 512)
        for (i, x) in head.enumerated() { v[i] = x }
        return HybridMatcher.l2Normalized(v)
    }

    private func oneHot(_ i: Int, _ n: Int) -> [Double] {
        (0..<n).map { $0 == i ? 1 : 0 }
    }

    /// The fixture's picture: ((x·37 + y·91) % 256, (x²·13 + y·7) % 256, (255 − x·23 − y·17) mod 256).
    private func pattern(width: Int, height: Int) -> RGBImage {
        var pixels: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                pixels.append(UInt8((x * 37 + y * 91) % 256))
                pixels.append(UInt8((x * x * 13 + y * 7) % 256))
                pixels.append(UInt8(((255 - x * 23 - y * 17) % 256 + 256) % 256))
            }
        }
        return RGBImage(width: width, height: height, pixels: pixels)
    }
}
