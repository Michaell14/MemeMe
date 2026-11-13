import CoreGraphics
import CoreML
import Foundation
import Vision
import XCTest
@testable import MemeMeApp
import MemeMeCore

/// The hybrid matcher against the team's benchmark (bench.py) on this Mac: parity with the Python reference, the
/// expression match@5 of the hybrid (and of the classic ranker on the same data), and the speed of a live frame and of
/// a held-face search. Runs only when CI provides everything (otherwise skipped):
///   MEMEME_HYBRID_TEST_MODELS   the converted models (scripts/build-hybrid-models.sh)
///   MEMEME_BENCHMARK_DATA       the images (scripts/hybrid/fetch_benchmark_data.py)
///   MEMEME_BENCHMARK_REFERENCE  the Python reference's output (scripts/hybrid/bench_reference.py)
///   MEMEME_BENCHMARK_OUT        optional: where the results go as JSON
final class HybridBenchmarkTests: XCTestCase {
    private struct Reference: Decodable {
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
        var full: [Float]; var face: [Float]; var emo: [Double]
        var visionCrop: PixelRect?; var rgb: RGBImage
        var visionFace: [Float]; var visionEmo: [Double]   // the app's path: Vision's crop (the whole image without one)
    }

    private func note(_ line: String) {
        FileHandle.standardError.write(Data(("HYBRID-BENCH " + line + "\n").utf8))
    }

    /// MEMEME_HYBRID_COMPUTE_UNITS: all (the app's setting, default), cpu, cpuAndGPU, cpuAndNeuralEngine.
    private func computeUnits() -> MLComputeUnits {
        switch ProcessInfo.processInfo.environment["MEMEME_HYBRID_COMPUTE_UNITS"] {
        case "cpu": return .cpuOnly
        case "cpuAndGPU": return .cpuAndGPU
        case "cpuAndNeuralEngine": return .cpuAndNeuralEngine
        default: return .all
        }
    }

    func testHybridAgainstTheBenchmark() throws {
        let env = ProcessInfo.processInfo.environment
        guard let modelsPath = env["MEMEME_HYBRID_TEST_MODELS"], let dataPath = env["MEMEME_BENCHMARK_DATA"],
              let referencePath = env["MEMEME_BENCHMARK_REFERENCE"] else {
            throw XCTSkip("set MEMEME_HYBRID_TEST_MODELS, MEMEME_BENCHMARK_DATA and MEMEME_BENCHMARK_REFERENCE")
        }
        let data = URL(fileURLWithPath: dataPath, isDirectory: true)
        let models = try HybridModels(directory: URL(fileURLWithPath: modelsPath, isDirectory: true),
                                      computeUnits: computeUnits())
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: URL(fileURLWithPath: referencePath)))
        var clock = CFAbsoluteTimeGetCurrent()
        models.warmUp()
        note("models loaded and warmed up in \(fmt(CFAbsoluteTimeGetCurrent() - clock)) s (compute units \(computeUnits().rawValue))")
        clock = CFAbsoluteTimeGetCurrent()
        var report: [String: Any] = [:]

        // ---------- per image: CLIP and HSEmotion, on the same crops as the reference ----------
        var measured: [String: Measured] = [:]
        // Model-only parity: the reference's own decoded pixels (PIL), so JPEG decoders don't count.
        let pixelsDir = env["MEMEME_BENCHMARK_PIXELS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        var modelClipCos: [Double] = [], modelFaceCos: [Double] = [], modelEmoDiff: [Double] = []
        var clipCos: [Double] = [], faceCos: [Double] = [], emoDiff: [Double] = [], zsDiff: [Double] = []
        var worst: [(file: String, what: String, value: Double)] = []
        var detectorAgrees = 0
        for image in reference.images {
            let url = data.appendingPathComponent(image.file)
            let cg = try XCTUnwrap(HybridAnalyzer.firstFrame(of: url), image.file)
            let rgb = try XCTUnwrap(HybridAnalyzer.rgbImage(from: cg), image.file)
            let full = try models.clipEmbedding(rgb)
            let refCrop = image.box.map { b in
                PixelRect(x0: Int(b[0].rounded(.toNearestOrEven)), y0: Int(b[1].rounded(.toNearestOrEven)),
                          x1: Int(b[2].rounded(.toNearestOrEven)), y1: Int(b[3].rounded(.toNearestOrEven)))
            }
            let faceImage = refCrop.map { rgb.cropped(to: $0) } ?? rgb
            let face = refCrop == nil ? full : try models.clipEmbedding(faceImage)
            let emo = try models.emotion(faceImage)
            let visionCrop = HybridAnalyzer.largestFaceCrop(in: cg)
            if (visionCrop != nil) == (image.box != nil) { detectorAgrees += 1 }
            let visionFace: [Float], visionEmo: [Double]
            if visionCrop == refCrop {
                visionFace = face
                visionEmo = emo
            } else {
                let crop = visionCrop.map { rgb.cropped(to: $0) } ?? rgb
                visionFace = visionCrop == nil ? full : try models.clipEmbedding(crop)
                visionEmo = try models.emotion(crop)
            }
            measured[image.kind + ":" + String(image.index)] = Measured(full: full, face: face, emo: emo,
                                                                         visionCrop: visionCrop, rgb: rgb,
                                                                         visionFace: visionFace, visionEmo: visionEmo)
            if measured.count % 25 == 0 {
                note("measured \(measured.count) of \(reference.images.count) images, \(fmt(CFAbsoluteTimeGetCurrent() - clock)) s")
            }
            if let pixelsDir, let size = image.size, size.count == 2,
               let raw = try? Data(contentsOf: pixelsDir.appendingPathComponent("\(image.kind)_\(image.index).rgb")),
               raw.count == size[0] * size[1] * 3 {
                let pil = RGBImage(width: size[0], height: size[1], pixels: [UInt8](raw))
                let pilFull = try models.clipEmbedding(pil)
                let pilFace = refCrop.map { pil.cropped(to: $0) } ?? pil
                let pilFaceEmbedding = refCrop == nil ? pilFull : try models.clipEmbedding(pilFace)
                let pilEmo = try models.emotion(pilFace)
                modelClipCos.append(cosine(pilFull, image.clip_full))
                modelFaceCos.append(cosine(pilFaceEmbedding, image.clip_face))
                modelEmoDiff.append(zip(pilEmo, image.emo).map { abs($0 - $1) }.max() ?? 1)
            }
            let c = cosine(full, image.clip_full), f = cosine(face, image.clip_face)
            let e = zip(emo, image.emo).map { abs($0 - $1) }.max() ?? 1
            let zsSource = image.kind == "gallery" ? full : face
            let z = zip(models.zeroShot(zsSource), image.zs).map { abs($0 - $1) }.max() ?? 1
            clipCos.append(c)
            faceCos.append(f)
            emoDiff.append(e)
            zsDiff.append(z)
            if c < 0.99 { worst.append((image.file, "clip cosine", c)) }
            if e > 0.02 { worst.append((image.file, "emotion max abs", e)) }
        }
        let n = reference.images.count
        var parity: [String: Any] = [:]
        parity["images"] = n
        parity["clip_full_cosine_min"] = clipCos.min() ?? 0
        parity["clip_full_cosine_mean"] = mean(clipCos)
        parity["clip_face_cosine_min"] = faceCos.min() ?? 0
        parity["hsemotion_max_abs_diff_max"] = emoDiff.max() ?? 1
        parity["hsemotion_max_abs_diff_mean"] = mean(emoDiff)
        parity["zero_shot_max_abs_diff_max"] = zsDiff.max() ?? 1
        parity["clip_cosine_below_0.99"] = clipCos.filter { $0 < 0.99 }.count
        parity["hsemotion_diff_above_0.02"] = emoDiff.filter { $0 > 0.02 }.count
        parity["vision_and_res10_agree_on_face"] = detectorAgrees
        report["parity_end_to_end"] = parity
        var modelParity: [String: Any] = [:]
        modelParity["images"] = modelClipCos.count
        modelParity["clip_full_cosine_min"] = modelClipCos.min() ?? 0
        modelParity["clip_full_cosine_mean"] = mean(modelClipCos)
        modelParity["clip_face_cosine_min"] = modelFaceCos.min() ?? 0
        modelParity["clip_cosine_below_0.99"] = (modelClipCos + modelFaceCos).filter { $0 < 0.99 }.count
        modelParity["hsemotion_max_abs_diff_max"] = modelEmoDiff.max() ?? 1
        modelParity["hsemotion_max_abs_diff_mean"] = mean(modelEmoDiff)
        modelParity["hsemotion_diff_above_0.02"] = modelEmoDiff.filter { $0 > 0.02 }.count
        report["parity_model_only"] = modelParity
        note("model-only parity: CLIP cosine min \(fmt(min(modelClipCos.min() ?? 0, modelFaceCos.min() ?? 0))), HSEmotion max abs \(fmt(modelEmoDiff.max() ?? 1))")
        for w in worst.prefix(12) { print("HYBRID-BENCH parity outlier \(w.file): \(w.what) \(w.value)") }

        // ---------- CLIP conversions compared on the reference's pixels (MEMEME_HYBRID_VARIANTS: name=dir,…) ----------
        if let pixelsDir, let variants = env["MEMEME_HYBRID_VARIANTS"] {
            var variantReport: [String: Any] = [:]
            for spec in variants.split(separator: ",") {
                let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let variant = try HybridModels(directory: URL(fileURLWithPath: parts[1], isDirectory: true),
                                               computeUnits: computeUnits())
                variant.warmUp()
                var cos: [Double] = []
                var seconds: [Double] = []
                for image in reference.images {
                    guard let size = image.size, size.count == 2,
                          let raw = try? Data(contentsOf: pixelsDir.appendingPathComponent("\(image.kind)_\(image.index).rgb")),
                          raw.count == size[0] * size[1] * 3 else { continue }
                    let pil = RGBImage(width: size[0], height: size[1], pixels: [UInt8](raw))
                    let start = CFAbsoluteTimeGetCurrent()
                    let e = try variant.clipEmbedding(pil)
                    seconds.append(CFAbsoluteTimeGetCurrent() - start)
                    cos.append(cosine(e, image.clip_full))
                }
                var r: [String: Any] = [:]
                r["images"] = cos.count
                r["clip_full_cosine_min"] = cos.min() ?? 0
                r["clip_full_cosine_mean"] = mean(cos)
                r["clip_cosine_below_0.99"] = cos.filter { $0 < 0.99 }.count
                r["clip_s_per_image_mean"] = mean(seconds)
                variantReport[parts[0]] = r
                note("CLIP variant \(parts[0]): cosine min \(fmt(cos.min() ?? 0)) mean \(fmt(mean(cos))), below 0.99: \(cos.filter { $0 < 0.99 }.count), \(fmt(mean(seconds))) s per image")
            }
            report["clip_variants"] = variantReport
        }

        // ---------- hybrid match@5 ----------
        let gallery = reference.gallery
        let labels = gallery.map { Set($0.labels) }
        func galleryEntries(visionDetector: Bool) throws -> [HybridIndexEntry] {
            try gallery.indices.map { i in
                let m = measured["gallery:\(i)"]!
                if !visionDetector {
                    let img = reference.images.first { $0.kind == "gallery" && $0.index == i }!
                    return HybridIndexEntry(key: gallery[i].id, contentHash: "", clipFull: m.full, hasFace: img.box != nil,
                                            emo: m.emo, zs: models.zeroShot(m.full))
                }
                // HybridAnalyzer.entry, from the passes already made.
                return HybridIndexEntry(key: gallery[i].id, contentHash: "", clipFull: m.full, hasFace: m.visionCrop != nil,
                                        emo: m.visionEmo, zs: models.zeroShot(m.full))
            }
        }
        func queryFor(_ i: Int, visionDetector: Bool) throws -> HybridQuery {
            let m = measured["query:\(i)"]!
            if !visionDetector {
                return HybridQuery(full: m.full, emotion: m.emo, zeroShot: models.zeroShot(m.face))
            }
            // HybridAnalyzer.query, from the passes already made.
            return HybridQuery(full: m.full, emotion: m.visionEmo, zeroShot: models.zeroShot(m.visionFace))
        }
        let test = reference.queries.indices.filter { reference.queries[$0].split == "test" }
        func evaluate(_ top5: (Int) throws -> [Int]) rethrows -> (p5: Double, macro: Double, lists: [Int: [String]]) {
            var per: [Int: Double] = [:]
            var lists: [Int: [String]] = [:]
            for i in test {
                let top = try top5(i)
                lists[i] = top.map { gallery[$0].id }
                per[i] = Double(top.filter { labels[$0].contains(reference.queries[i].emotion) }.count) / 5
            }
            let p5 = mean(Array(per.values))
            let classes = EmotionPrompts.expectedClasses
            let macro = mean(classes.compactMap { c -> Double? in
                let v = test.filter { reference.queries[$0].emotion == c }.compactMap { per[$0] }
                return v.isEmpty ? nil : mean(v)
            })
            return (p5, macro, lists)
        }
        func overlap(_ lists: [Int: [String]]) -> Double {
            mean(test.map { i in Double(Set(lists[i] ?? []).intersection(reference.top5[String(i)] ?? []).count) / 5 })
        }
        var hybridRuns: [String: Any] = [:]
        var hybridQueries: [Int: HybridQuery] = [:]
        for (name, vision) in [("benchmark boxes (res10)", false), ("Vision face detector (the app)", true)] {
            let entries = try galleryEntries(visionDetector: vision)
            let result = try evaluate { i in
                let q = try queryFor(i, visionDetector: vision)
                if vision { hybridQueries[i] = q }
                let scores = entries.map { HybridMatcher.score(query: q, entry: $0) }
                return Array(scores.indices.sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }.prefix(5))
            }
            var run: [String: Any] = [:]
            run["expr_p5_test"] = result.p5
            run["expr_p5_macro_test"] = result.macro
            run["top5_overlap_with_python"] = overlap(result.lists)
            run["gallery_faces"] = entries.filter { $0.hasFace }.count
            hybridRuns[name] = run
            print("HYBRID-BENCH hybrid [\(name)] match@5 \(fmt(result.p5)) macro \(fmt(result.macro)) top-5 overlap \(fmt(overlap(result.lists)))")
        }
        report["hybrid"] = hybridRuns
        report["python_reference"] = reference.results

        note("hybrid ranked, \(fmt(CFAbsoluteTimeGetCurrent() - clock)) s")
        // ---------- the classic ranker on the same data (population-neutral resting face) ----------
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
                                          emotion: a.face == nil ? nil : hybridQueries[i]?.emotion)
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
        print("HYBRID-BENCH classic ranker match@5 \(fmt(classic.p5)) macro \(fmt(classic.macro))")
        // As the app routes it: the hybrid unless a pose or a face detail is clear.
        let appEntries = try galleryEntries(visionDetector: true)
        var routedToClassic = 0
        let routed = try evaluate { i in
            let sample = samples[i]!
            guard sample.emotion != nil, HybridRouting.usesHybrid(sample, baseline: baseline), let q = hybridQueries[i] else {
                routedToClassic += 1
                return classicTop5(i)
            }
            let scores = appEntries.map { HybridMatcher.score(query: q, entry: $0) }
            return Array(scores.indices.sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }.prefix(5))
        }
        print("HYBRID-BENCH app routing match@5 \(fmt(routed.p5)) macro \(fmt(routed.macro)) (\(routedToClassic) of \(test.count) queries to the classic ranker)")
        var classicReport: [String: Any] = [:]
        classicReport["expr_p5_test"] = classic.p5
        classicReport["expr_p5_macro_test"] = classic.macro
        report["classic"] = classicReport
        var routedReport: [String: Any] = [:]
        routedReport["expr_p5_test"] = routed.p5
        routedReport["expr_p5_macro_test"] = routed.macro
        routedReport["queries_to_classic"] = routedToClassic
        routedReport["test_queries"] = test.count
        report["app_routing"] = routedReport

        note("classic ranked, \(fmt(CFAbsoluteTimeGetCurrent() - clock)) s")
        // ---------- speed ----------
        var speeds: [String: Any] = [:]
        let unitSettings: [(String, MLComputeUnits)] = [("all", .all), ("cpuOnly", .cpuOnly),
                                                         ("cpuAndNeuralEngine", .cpuAndNeuralEngine)]
        for (name, units) in unitSettings {
            let timed = try HybridModels(directory: URL(fileURLWithPath: modelsPath, isDirectory: true), computeUnits: units)
            timed.warmUp()
            speeds[name] = try measureSpeed(models: timed, data: data, reference: reference, entries: appEntries, label: name)
        }
        report["speed"] = speeds

        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print("HYBRID-BENCH report\n" + String(decoding: json, as: UTF8.self))
        if let out = env["MEMEME_BENCHMARK_OUT"] {
            try json.write(to: URL(fileURLWithPath: out))
        }

        // The parity bounds from the task, on the models (the same pixels as the reference). End to end, Apple's image
        // decoders differ from PIL's by a few levels per pixel; that is reported above, not asserted.
        if !modelClipCos.isEmpty {
            XCTAssertGreaterThanOrEqual(min(modelClipCos.min() ?? 0, modelFaceCos.min() ?? 0), 0.99, "CLIP cosine with the reference")
            XCTAssertLessThanOrEqual(modelEmoDiff.max() ?? 1, 0.02, "HSEmotion probabilities against the reference")
        }
    }

    /// A live frame (the app's face request + crop + HSEmotion) and a held-face search (two CLIP passes, zero-shot, and
    /// scoring the gallery, and 5,000 entries), on 640 × 480 frames made from the test photos.
    private func measureSpeed(models: HybridModels, data: URL, reference: Reference,
                              entries: [HybridIndexEntry], label: String) throws -> [String: Any] {
        let files = reference.queries.filter { $0.split == "test" }.prefix(24).map { data.appendingPathComponent($0.file) }
        let frames = files.compactMap { url in HybridAnalyzer.firstFrame(of: url).flatMap { self.webcamFrame($0) } }
        XCTAssertFalse(frames.isEmpty)
        var big = entries
        var rng = SystemRandomNumberGenerator()
        while big.count < 5000 {
            let v = HybridMatcher.l2Normalized((0..<512).map { _ in Float.random(in: -1...1, using: &rng) })
            big.append(HybridIndexEntry(key: "s\(big.count)", contentHash: "", clipFull: v, hasFace: big.count % 2 == 0,
                                        emo: HybridMatcher.softmax((0..<8).map { _ in Double.random(in: 0...3) }),
                                        zs: HybridMatcher.softmax((0..<7).map { _ in Double.random(in: 0...3) })))
        }
        func live(_ frame: CGImage, request: VNImageBasedRequest) throws -> Double {
            let start = CFAbsoluteTimeGetCurrent()
            try VNImageRequestHandler(cgImage: frame, orientation: .up, options: [:]).perform([request])
            let faces = (request.results ?? []).compactMap { $0 as? VNFaceObservation }
            let rgb = HybridAnalyzer.rgbImage(from: frame)!
            let crop = HybridAnalyzer.largestFaceCrop(faces, imageWidth: rgb.width, imageHeight: rgb.height)
            _ = try models.emotion(crop.map { rgb.cropped(to: $0) } ?? rgb)
            return CFAbsoluteTimeGetCurrent() - start
        }
        var landmarks: [Double] = [], rectangles: [Double] = [], held: [Double] = [], heldBig: [Double] = [], rank5k: [Double] = []
        _ = try live(frames[0], request: VNDetectFaceLandmarksRequest())
        for frame in frames {
            landmarks.append(try live(frame, request: VNDetectFaceLandmarksRequest()))
            rectangles.append(try live(frame, request: VNDetectFaceRectanglesRequest()))
            let rgb = HybridAnalyzer.rgbImage(from: frame)!
            let crop = HybridAnalyzer.largestFaceCrop(in: frame)
            let emotion = try models.emotion(crop.map { rgb.cropped(to: $0) } ?? rgb)
            var start = CFAbsoluteTimeGetCurrent()
            let q = try HybridAnalyzer.query(frame: rgb, faceCrop: crop, emotion: emotion, models: models)
            let queryTime = CFAbsoluteTimeGetCurrent() - start
            start = CFAbsoluteTimeGetCurrent()
            _ = HybridMatcher.rank(entries, query: q)
            held.append(queryTime + CFAbsoluteTimeGetCurrent() - start)
            start = CFAbsoluteTimeGetCurrent()
            _ = HybridMatcher.rank(big, query: q)
            let r = CFAbsoluteTimeGetCurrent() - start
            rank5k.append(r)
            heldBig.append(queryTime + r)
        }
        var speed: [String: Any] = [:]
        speed["frames"] = frames.count
        speed["frame_size"] = "640x480"
        speed["live_frame_s_landmarks_mean"] = mean(landmarks)
        speed["live_frame_s_landmarks_median"] = median(landmarks)
        speed["live_frame_s_rectangles_mean"] = mean(rectangles)
        speed["held_search_s_gallery209_mean"] = mean(held)
        speed["held_search_s_gallery209_median"] = median(held)
        speed["held_search_s_5000_items_mean"] = mean(heldBig)
        speed["rank_only_s_5000_items_mean"] = mean(rank5k)
        speed["cpu"] = ProcessInfo.processInfo.processorCount
        print("HYBRID-BENCH speed [\(label)] live frame \(fmt(mean(landmarks))) s (landmarks), \(fmt(mean(rectangles))) s (rectangles); held search \(fmt(mean(held))) s (209), \(fmt(mean(heldBig))) s (5,000)")
        return speed
    }

    /// The photo scaled into a 640 × 480 frame (as the camera delivers), on grey.
    private func webcamFrame(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 640 * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        let scale = 480 / Double(image.height)
        let w = Double(image.width) * scale
        context.draw(image, in: CGRect(x: (640 - w) / 2, y: 0, width: w, height: 480))
        return context.makeImage()
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Double {
        VectorMath.cosine(a, b)
    }

    private func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
    private func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }
    private func fmt(_ v: Double) -> String { String(format: "%.4f", v) }
}
