import CoreGraphics
import CoreML
import Foundation
import Vision
import XCTest
@testable import MemeMeApp
import MemeMeCore

/// The hybrid matcher against the team's benchmark (bench.py): parity with the Python reference and, on the full set,
/// expression match@5 of the hybrid, the classic ranker and the app's routing. Skipped unless these are set:
///   MEMEME_HYBRID_TEST_MODELS   the converted models (scripts/build-hybrid-models.sh)
///   MEMEME_BENCHMARK_DATA       the images (scripts/hybrid/fetch_benchmark_data.py)
///   MEMEME_BENCHMARK_REFERENCE  the Python reference's output (scripts/hybrid/bench_reference.py)
///   MEMEME_BENCHMARK_PIXELS     the reference's decoded pixels (bench_reference.py --dump-pixels): parity on the models
///   MEMEME_BENCHMARK_MODE       "sample" (parity only; every push) or "full" (default; the manual workflow)
///   MEMEME_HYBRID_VARIANTS      optional, name=dir,…: other CLIP conversions compared on the same pixels
///   MEMEME_HYBRID_COMPUTE_UNITS optional: all (default), cpu, cpuAndGPU, cpuAndNeuralEngine
///   MEMEME_BENCHMARK_OUT        optional: where the results go as JSON
final class HybridBenchmarkTests: XCTestCase {
    struct Reference: Decodable {
        struct Gallery: Decodable { let id: String; let file: String; let labels: [String]; let has_face: Bool }
        struct Query: Decodable { let file: String; let emotion: String; let split: String }
        struct Image: Decodable {
            let kind: String; let index: Int; let file: String; let box: [Double]?; let size: [Int]?
            let clip_full: [Float]; let clip_face: [Float]; let emo: [Double]; let zs: [Double]
        }
        let results: [String: Double]
        let gallery: [Gallery]
        let queries: [Query]
        let top5: [String: [String]]
        let images: [Image]
    }

    private struct Measured {
        var full: [Float]; var face: [Float]; var emo: [Double]   // from Apple's decoding, on the reference's crop
        var visionCrop: PixelRect?
        var visionFace: [Float]; var visionEmo: [Double]   // the app's path: Vision's crop (the whole image without one)
    }

    /// Parity bounds (agreed with the team): CLIP mean cosine, the share of checks (whole images and face crops) at
    /// 0.99 or better, HSEmotion's largest difference, and match@5 against the Python reference.
    static let minimumMeanCosine = 0.999
    static let minimumShareAt099 = 0.99
    static let maximumEmotionDifference = 0.02
    static let maximumMatchDifference = 0.01

    func testHybridAgainstTheBenchmark() throws {
        let env = ProcessInfo.processInfo.environment
        guard let modelsPath = env["MEMEME_HYBRID_TEST_MODELS"], let dataPath = env["MEMEME_BENCHMARK_DATA"],
              let referencePath = env["MEMEME_BENCHMARK_REFERENCE"] else {
            throw XCTSkip("set MEMEME_HYBRID_TEST_MODELS, MEMEME_BENCHMARK_DATA and MEMEME_BENCHMARK_REFERENCE")
        }
        let full = env["MEMEME_BENCHMARK_MODE"] != "sample"
        let data = URL(fileURLWithPath: dataPath, isDirectory: true)
        let pixelsDir = env["MEMEME_BENCHMARK_PIXELS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let units = HybridBenchmarkTests.computeUnits(env["MEMEME_HYBRID_COMPUTE_UNITS"])
        let models = try HybridModels(directory: URL(fileURLWithPath: modelsPath, isDirectory: true), computeUnits: units)
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: URL(fileURLWithPath: referencePath)))
        models.warmUp()
        let clock = CFAbsoluteTimeGetCurrent()
        var report: [String: Any] = ["mode": full ? "full" : "sample", "images": reference.images.count]

        // ---------- per image ----------
        var measured: [String: Measured] = [:]
        var modelCos: [Double] = [], modelChecks: [Double] = [], modelEmo: [Double] = []
        var endCos: [Double] = [], endChecks: [Double] = [], endEmo: [Double] = []
        var detectorAgrees = 0
        for image in reference.images {
            let refCrop = image.box.map { b in
                PixelRect(x0: Int(b[0].rounded(.toNearestOrEven)), y0: Int(b[1].rounded(.toNearestOrEven)),
                          x1: Int(b[2].rounded(.toNearestOrEven)), y1: Int(b[3].rounded(.toNearestOrEven)))
            }
            // The models on the reference's own pixels (PIL's decoding): the parity bounds.
            if let pixelsDir, let size = image.size, size.count == 2,
               let raw = try? Data(contentsOf: pixelsDir.appendingPathComponent("\(image.kind)_\(image.index).rgb")),
               raw.count == size[0] * size[1] * 3 {
                let pil = RGBImage(width: size[0], height: size[1], pixels: [UInt8](raw))
                let (c, f, e) = try compare(pil, crop: refCrop, image: image, models: models)
                modelCos.append(c)
                modelChecks.append(c)
                if refCrop != nil { modelChecks.append(f) }
                modelEmo.append(e)
                if c < 0.99 || f < 0.99 || e > 0.02 {
                    note("model parity outlier \(image.file): CLIP \(fmt(c)), crop \(fmt(f)), HSEmotion \(fmt(e))")
                }
            }
            // End to end, from Apple's decoding (informational: decoders differ by a few levels per pixel).
            let url = data.appendingPathComponent(image.file)
            let cg = try XCTUnwrap(HybridAnalyzer.firstFrame(of: url), image.file)
            let rgb = try XCTUnwrap(HybridAnalyzer.rgbImage(from: cg), image.file)
            let (c, f, e, fullEmbedding, emo, faceEmbedding) = try compareDetailed(rgb, crop: refCrop, image: image, models: models)
            endCos.append(c)
            endChecks.append(c)
            if refCrop != nil { endChecks.append(f) }
            endEmo.append(e)
            guard full else { continue }
            let visionCrop = HybridAnalyzer.largestFaceCrop(in: cg)
            if (visionCrop != nil) == (image.box != nil) { detectorAgrees += 1 }
            let visionFace: [Float], visionEmo: [Double]
            if visionCrop == refCrop {
                visionFace = faceEmbedding
                visionEmo = emo
            } else {
                let crop = visionCrop.map { rgb.cropped(to: $0) } ?? rgb
                visionFace = visionCrop == nil ? fullEmbedding : try models.clipEmbedding(crop)
                visionEmo = try models.emotion(crop)
            }
            measured["\(image.kind):\(image.index)"] = Measured(full: fullEmbedding, face: faceEmbedding, emo: emo,
                                                                 visionCrop: visionCrop,
                                                                 visionFace: visionFace, visionEmo: visionEmo)
            if measured.count % 50 == 0 {
                note("measured \(measured.count) of \(reference.images.count), \(fmt(CFAbsoluteTimeGetCurrent() - clock)) s")
            }
        }
        report["parity_model_only"] = parityReport(modelCos, modelChecks, modelEmo)
        report["parity_end_to_end"] = parityReport(endCos, endChecks, endEmo)
        note("model-only parity: \(summary(modelCos, modelChecks, modelEmo))")
        note("end-to-end parity (informational): \(summary(endCos, endChecks, endEmo))")

        if let pixelsDir, let variants = env["MEMEME_HYBRID_VARIANTS"] {
            report["clip_variants"] = try compareVariants(variants, pixelsDir: pixelsDir, reference: reference, units: units)
        }

        var swiftMatch: Double?
        if full {
            let match = try matchAt5(reference: reference, measured: measured, models: models)
            report.merge(match.report) { $1 }
            report["vision_and_res10_agree_on_face"] = detectorAgrees
            swiftMatch = match.benchmarkBoxesP5
        }

        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print("HYBRID-BENCH report\n" + String(decoding: json, as: UTF8.self))
        if let out = env["MEMEME_BENCHMARK_OUT"] {
            try json.write(to: URL(fileURLWithPath: out))
        }

        // ---------- the agreed bounds ----------
        XCTAssertFalse(modelCos.isEmpty, "no reference pixels (MEMEME_BENCHMARK_PIXELS)")
        XCTAssertGreaterThanOrEqual(mean(modelCos), HybridBenchmarkTests.minimumMeanCosine, "CLIP mean cosine")
        XCTAssertGreaterThanOrEqual(share(modelChecks, atLeast: 0.99), HybridBenchmarkTests.minimumShareAt099,
                                    "share of CLIP checks (images and face crops) at 0.99 or better")
        XCTAssertLessThanOrEqual(modelEmo.max() ?? 1, HybridBenchmarkTests.maximumEmotionDifference,
                                 "HSEmotion probabilities against the reference")
        if let swiftMatch, let python = reference.results["hybrid_p5_test"] {
            XCTAssertLessThanOrEqual(abs(swiftMatch - python), HybridBenchmarkTests.maximumMatchDifference,
                                     "Swift hybrid match@5 (benchmark boxes) against the Python reference")
        }
    }

    // MARK: - Parity

    private func compare(_ rgb: RGBImage, crop: PixelRect?, image: Reference.Image,
                         models: HybridModels) throws -> (Double, Double, Double) {
        let r = try compareDetailed(rgb, crop: crop, image: image, models: models)
        return (r.0, r.1, r.2)
    }

    /// CLIP of the whole image and of the reference's crop, HSEmotion of the crop, against the reference.
    private func compareDetailed(_ rgb: RGBImage, crop: PixelRect?, image: Reference.Image, models: HybridModels) throws
        -> (Double, Double, Double, [Float], [Double], [Float]) {
        let fullEmbedding = try models.clipEmbedding(rgb)
        let faceImage = crop.map { rgb.cropped(to: $0) } ?? rgb
        let faceEmbedding = crop == nil ? fullEmbedding : try models.clipEmbedding(faceImage)
        let emo = try models.emotion(faceImage)
        let e = zip(emo, image.emo).map { abs($0 - $1) }.max() ?? 1
        return (VectorMath.cosine(fullEmbedding, image.clip_full), VectorMath.cosine(faceEmbedding, image.clip_face), e,
                fullEmbedding, emo, faceEmbedding)
    }

    private func parityReport(_ cos: [Double], _ checks: [Double], _ emo: [Double]) -> [String: Any] {
        var r: [String: Any] = [:]
        r["images"] = cos.count
        r["clip_full_cosine_mean"] = mean(cos)
        r["clip_full_cosine_min"] = cos.min() ?? 0
        r["clip_checks"] = checks.count
        r["clip_checks_below_0.99"] = checks.filter { $0 < 0.99 }.count
        r["clip_checks_share_at_0.99"] = share(checks, atLeast: 0.99)
        r["clip_checks_min"] = checks.min() ?? 0
        r["hsemotion_max_abs_diff_max"] = emo.max() ?? 1
        r["hsemotion_max_abs_diff_mean"] = mean(emo)
        r["hsemotion_above_0.02"] = emo.filter { $0 > 0.02 }.count
        return r
    }

    private func summary(_ cos: [Double], _ checks: [Double], _ emo: [Double]) -> String {
        "CLIP mean \(fmt(mean(cos))), \(fmt(100 * share(checks, atLeast: 0.99)))% of \(checks.count) checks ≥ 0.99 "
            + "(min \(fmt(checks.min() ?? 0))); HSEmotion max \(fmt(emo.max() ?? 1)) over \(emo.count) images"
    }

    private func compareVariants(_ variants: String, pixelsDir: URL, reference: Reference,
                                 units: MLComputeUnits) throws -> [String: Any] {
        var out: [String: Any] = [:]
        for spec in variants.split(separator: ",") {
            let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let variant = try HybridModels(directory: URL(fileURLWithPath: parts[1], isDirectory: true), computeUnits: units)
            variant.warmUp()
            var cos: [Double] = []
            for image in reference.images {
                guard let size = image.size, size.count == 2,
                      let raw = try? Data(contentsOf: pixelsDir.appendingPathComponent("\(image.kind)_\(image.index).rgb")),
                      raw.count == size[0] * size[1] * 3 else { continue }
                let e = try variant.clipEmbedding(RGBImage(width: size[0], height: size[1], pixels: [UInt8](raw)))
                cos.append(VectorMath.cosine(e, image.clip_full))
            }
            var r: [String: Any] = [:]
            r["images"] = cos.count
            r["clip_full_cosine_mean"] = mean(cos)
            r["clip_full_cosine_min"] = cos.min() ?? 0
            r["clip_below_0.99"] = cos.filter { $0 < 0.99 }.count
            out[parts[0]] = r
            note("CLIP variant \(parts[0]): mean \(fmt(mean(cos))), min \(fmt(cos.min() ?? 0)), below 0.99: \(cos.filter { $0 < 0.99 }.count)")
        }
        return out
    }

    // MARK: - match@5 (full set)

    private enum Route: String, CaseIterable {
        case hybridOnly = "hybrid only"
        case poseOnly = "hybrid unless a clear pose"
        case heldDetails = "hybrid unless a clear pose or tongue out / wink / duck face / eye roll (the app)"
        case anyDetail = "hybrid unless a clear pose or any clear face detail (before)"
    }

    private func matchAt5(reference: Reference, measured: [String: Measured],
                          models: HybridModels) throws -> (report: [String: Any], benchmarkBoxesP5: Double) {
        let gallery = reference.gallery
        let labels = gallery.map { Set($0.labels) }
        let test = reference.queries.indices.filter { reference.queries[$0].split == "test" }
        let images = Dictionary(uniqueKeysWithValues: reference.images.map { ("\($0.kind):\($0.index)", $0) })
        var report: [String: Any] = [:]

        func evaluate(_ top5: (Int) throws -> [Int]) rethrows -> (p5: Double, macro: Double, lists: [Int: [String]]) {
            var per: [Int: Double] = [:]
            var lists: [Int: [String]] = [:]
            for i in test {
                let top = try top5(i)
                lists[i] = top.map { gallery[$0].id }
                per[i] = Double(top.filter { labels[$0].contains(reference.queries[i].emotion) }.count) / 5
            }
            let byClass = EmotionPrompts.expectedClasses.compactMap { c -> Double? in
                let v = test.filter { reference.queries[$0].emotion == c }.compactMap { per[$0] }
                return v.isEmpty ? nil : mean(v)
            }
            return (mean(Array(per.values)), mean(byClass), lists)
        }
        func overlap(_ lists: [Int: [String]]) -> Double {
            mean(test.map { i in Double(Set(lists[i] ?? []).intersection(reference.top5[String(i)] ?? []).count) / 5 })
        }
        func rankTop5(_ q: HybridQuery, _ entries: [HybridIndexEntry]) -> [Int] {
            let scores = entries.map { HybridMatcher.score(query: q, entry: $0) }
            return Array(scores.indices.sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }.prefix(5))
        }

        // Gallery entries and queries: with the benchmark's boxes (like for like) and with Vision's (the app).
        let resEntries = gallery.indices.map { i -> HybridIndexEntry in
            let m = measured["gallery:\(i)"]!
            return HybridIndexEntry(key: gallery[i].id, contentHash: "", clipFull: m.full, hasFace: images["gallery:\(i)"]?.box != nil,
                                    emo: m.emo, zs: models.zeroShot(m.full))
        }
        let visionEntries = gallery.indices.map { i -> HybridIndexEntry in
            let m = measured["gallery:\(i)"]!
            return HybridIndexEntry(key: gallery[i].id, contentHash: "", clipFull: m.full, hasFace: m.visionCrop != nil,
                                    emo: m.visionEmo, zs: models.zeroShot(m.full))
        }
        var resQueries: [Int: HybridQuery] = [:], visionQueries: [Int: HybridQuery] = [:]
        for i in test {
            let m = measured["query:\(i)"]!
            resQueries[i] = HybridQuery(full: m.full, emotion: m.emo, zeroShot: models.zeroShot(m.face))
            visionQueries[i] = HybridQuery(full: m.full, emotion: m.visionEmo, zeroShot: models.zeroShot(m.visionFace))
        }
        let res = evaluate { rankTop5(resQueries[$0]!, resEntries) }
        let vision = evaluate { rankTop5(visionQueries[$0]!, visionEntries) }
        var hybrid: [String: Any] = [:]
        hybrid["benchmark boxes (res10)"] = ["expr_p5_test": res.p5, "expr_p5_macro_test": res.macro,
                                             "top5_overlap_with_python": overlap(res.lists)] as [String: Any]
        hybrid["Vision face detector (the app)"] = ["expr_p5_test": vision.p5, "expr_p5_macro_test": vision.macro,
                                                    "top5_overlap_with_python": overlap(vision.lists),
                                                    "gallery_faces": visionEntries.filter { $0.hasFace }.count] as [String: Any]
        report["hybrid"] = hybrid
        report["python_reference"] = reference.results
        note("hybrid [benchmark boxes] match@5 \(fmt(res.p5)) macro \(fmt(res.macro)) overlap \(fmt(overlap(res.lists)))")
        note("hybrid [Vision] match@5 \(fmt(vision.p5)) macro \(fmt(vision.macro)) overlap \(fmt(overlap(vision.lists)))")

        // The classic ranker on the same data (population-neutral resting face).
        let data = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MEMEME_BENCHMARK_DATA"]!, isDirectory: true)
        let baseline = RestingBaseline()
        let items: [LibraryItem] = try gallery.map { g in
            let url = data.appendingPathComponent(g.file)
            let a = try ImageAnalyzer.analyze(url: url, includeText: false)
            return LibraryItem(id: UUID(), fileURL: url, displayName: g.id, kind: .mine, tier: .meme, source: "Benchmark",
                               contentHash: g.id, face: a.face, pose: a.pose, poseRevision: LibraryItem.currentPoseRevision,
                               intensity: a.intensity, faceShape: a.faceShape, faceRevision: LibraryItem.currentFaceRevision)
        }
        let indexOf = Dictionary(uniqueKeysWithValues: gallery.enumerated().map { ($0.element.id, $0.offset) })
        var samples: [Int: ExpressionSample] = [:]
        for i in test {
            let a = try ImageAnalyzer.analyze(url: data.appendingPathComponent(reference.queries[i].file), includeText: false)
            // As the camera does: an emotion reading whenever the frame has a face.
            samples[i] = ExpressionSample(face: a.face, pose: a.pose, shape: a.faceShape, timestamp: 0,
                                          emotion: a.face == nil ? nil : visionQueries[i]?.emotion)
        }
        let ranker = Ranker(baseline: baseline)
        func classicTop5(_ i: Int) -> [Int] {
            let sample = samples[i]!
            let deviation = sample.face.map { baseline.deviation(of: $0) } ?? [:]
            let weights = FeatureWeights.automatic(deviation: deviation, poseStrength: sample.pose?.gestureStrength ?? 0)
            return ranker.rank(items, query: .expression(sample, weights: weights), limit: 5, capsFriends: false)
                .compactMap { indexOf[$0.item.displayName] }
        }
        let classic = evaluate(classicTop5)
        report["classic"] = ["expr_p5_test": classic.p5, "expr_p5_macro_test": classic.macro] as [String: Any]
        note("classic ranker match@5 \(fmt(classic.p5)) macro \(fmt(classic.macro))")

        // What triggers on these photos, and match@5 for each routing rule. A still photo is a held face, so a clear
        // detail counts as held.
        var cueCounts: [String: Int] = [:]
        var poses = 0, noEmotion = 0
        for i in test {
            let sample = samples[i]!
            if sample.emotion == nil { noEmotion += 1 }
            if PoseBadge.of(sample, baseline: baseline) != nil { poses += 1 }
            if let cue = baseline.cues(of: sample.shape).clearCue { cueCounts[cue.rawValue, default: 0] += 1 }
        }
        report["routing_triggers"] = ["clear_face_details": cueCounts, "clear_poses": poses,
                                      "no_face_or_emotion": noEmotion, "test_queries": test.count] as [String: Any]
        note("triggers: face details \(cueCounts), poses \(poses), no face/emotion \(noEmotion), of \(test.count)")
        var routes: [String: Any] = [:]
        for route in Route.allCases {
            var toClassic = 0
            let result = evaluate { i -> [Int] in
                let sample = samples[i]!
                let pose = PoseBadge.of(sample, baseline: baseline) != nil
                let cue = baseline.cues(of: sample.shape).clearCue
                let classicRoute: Bool
                switch route {
                case .hybridOnly: classicRoute = false
                case .poseOnly: classicRoute = pose
                case .heldDetails: classicRoute = !HybridRouting.usesHybrid(sample, baseline: baseline, cueHeld: true)
                case .anyDetail: classicRoute = pose || cue != nil
                }
                if sample.emotion == nil || classicRoute {
                    toClassic += 1
                    return classicTop5(i)
                }
                return rankTop5(visionQueries[i]!, visionEntries)
            }
            routes[route.rawValue] = ["expr_p5_test": result.p5, "expr_p5_macro_test": result.macro,
                                      "queries_to_classic": toClassic] as [String: Any]
            note("routing [\(route.rawValue)] match@5 \(fmt(result.p5)) macro \(fmt(result.macro)) (\(toClassic) to classic)")
        }
        report["routing"] = routes
        return (report, res.p5)
    }

    // MARK: - Helpers

    static func computeUnits(_ name: String?) -> MLComputeUnits {
        switch name {
        case "cpu", "cpuOnly": return .cpuOnly
        case "cpuAndGPU": return .cpuAndGPU
        case "cpuAndNeuralEngine": return .cpuAndNeuralEngine
        default: return .all
        }
    }

    private func note(_ line: String) {
        FileHandle.standardError.write(Data(("HYBRID-BENCH " + line + "\n").utf8))
    }

    private func share(_ v: [Double], atLeast bound: Double) -> Double {
        v.isEmpty ? 0 : Double(v.filter { $0 >= bound }.count) / Double(v.count)
    }

    private func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
    private func fmt(_ v: Double) -> String { String(format: "%.4f", v) }
}
