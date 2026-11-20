import CoreGraphics
import CoreML
import Foundation
import Vision
import XCTest
@testable import MemeMeApp
import MemeMeCore

/// Times the hybrid matcher on this Mac for each compute-unit setting: a live frame (the app's face request, the crop
/// and HSEmotion) and a held-face search (CLIP of the frame and of the crop, zero-shot, scoring 209 and 5,000 memes).
/// Run it with scripts/hybrid/time-on-mac.sh (a release build). Skipped unless these are set:
///   MEMEME_HYBRID_TEST_MODELS  the converted models
///   MEMEME_SPEED_PHOTOS        a folder of face photos (made into 640 × 480 frames, as the camera delivers)
final class HybridSpeedTests: XCTestCase {
    func testSpeedPerComputeUnits() throws {
        let env = ProcessInfo.processInfo.environment
        guard let modelsPath = env["MEMEME_HYBRID_TEST_MODELS"], let photosPath = env["MEMEME_SPEED_PHOTOS"] else {
            throw XCTSkip("set MEMEME_HYBRID_TEST_MODELS and MEMEME_SPEED_PHOTOS")
        }
        let photos = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: photosPath, isDirectory: true),
                                                                 includingPropertiesForKeys: nil)
            .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(24)
        let frames = photos.compactMap { url in HybridAnalyzer.firstFrame(of: url).flatMap { self.webcamFrame($0) } }
        XCTAssertFalse(frames.isEmpty, "no photos in \(photosPath)")
        let rounds = Int(env["MEMEME_SPEED_ROUNDS"] ?? "") ?? 3
        var rows: [String] = []
        for (name, units) in [("CPU only", MLComputeUnits.cpuOnly), ("CPU + Neural Engine", .cpuAndNeuralEngine),
                              ("All (the app)", .all)] {
            let models = try HybridModels(directory: URL(fileURLWithPath: modelsPath, isDirectory: true), computeUnits: units)
            models.warmUp()
            let gallery = HybridSpeedTests.syntheticIndex(count: 209)
            let big = HybridSpeedTests.syntheticIndex(count: 5000)
            _ = try live(frames[0], models: models)   // first-use costs out of the way
            var liveTimes: [Double] = [], heldTimes: [Double] = [], heldBigTimes: [Double] = []
            for _ in 0..<rounds {
                for frame in frames {
                    liveTimes.append(try live(frame, models: models))
                    let rgb = HybridAnalyzer.rgbImage(from: frame)!
                    let crop = HybridAnalyzer.largestFaceCrop(in: frame)
                    let emotion = try models.emotion(crop.map { rgb.cropped(to: $0) } ?? rgb)   // read live, before the hold
                    var start = CFAbsoluteTimeGetCurrent()
                    let q = try HybridAnalyzer.query(frame: rgb, faceCrop: crop, emotion: emotion, models: models)
                    let queryTime = CFAbsoluteTimeGetCurrent() - start
                    start = CFAbsoluteTimeGetCurrent()
                    _ = HybridMatcher.rank(gallery, query: q)
                    heldTimes.append(queryTime + CFAbsoluteTimeGetCurrent() - start)
                    start = CFAbsoluteTimeGetCurrent()
                    _ = HybridMatcher.rank(big, query: q)
                    heldBigTimes.append(queryTime + CFAbsoluteTimeGetCurrent() - start)
                }
            }
            let cells = [mean(liveTimes), median(liveTimes), mean(heldTimes), median(heldTimes), mean(heldBigTimes)]
                .map { pad(String(format: "%.1f ms", 1000 * $0), 13, left: true) }
            rows.append(pad(name, 20) + cells.joined())
        }
        var lines = ["HYBRID-SPEED \(frames.count) frames × \(rounds) rounds, 640 × 480, \(ProcessInfo.processInfo.processorCount) cores",
                     "HYBRID-SPEED " + pad("compute units", 20)
                        + ["live mean", "live median", "held mean", "held median", "held 5k mean"].map { pad($0, 13, left: true) }
                        .joined()]
        lines += rows.map { "HYBRID-SPEED " + $0 }
        lines.append("HYBRID-SPEED live = face landmarks + crop + HSEmotion; held = 2 CLIP passes + zero-shot + scoring "
                     + "209 memes (held 5k: 5,000)")
        let text = lines.joined(separator: "\n")
        print(text)
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// One live frame as the app reads it: the face landmarks request, the largest face's crop, HSEmotion.
    private func live(_ frame: CGImage, models: HybridModels) throws -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: frame, orientation: .up, options: [:]).perform([request])
        let faces = (request.results ?? []).compactMap { $0 as? VNFaceObservation }
        let rgb = HybridAnalyzer.rgbImage(from: frame)!
        let crop = HybridAnalyzer.largestFaceCrop(faces, imageWidth: rgb.width, imageHeight: rgb.height)
        _ = try models.emotion(crop.map { rgb.cropped(to: $0) } ?? rgb)
        return CFAbsoluteTimeGetCurrent() - start
    }

    static func syntheticIndex(count: Int) -> [HybridIndexEntry] {
        var rng = SystemRandomNumberGenerator()
        return (0..<count).map { i in
            let v = HybridMatcher.l2Normalized((0..<512).map { _ in Float.random(in: -1...1, using: &rng) })
            return HybridIndexEntry(key: "s\(i)", contentHash: "", clipFull: v, hasFace: i % 2 == 0,
                                    emo: HybridMatcher.softmax((0..<8).map { _ in Double.random(in: 0...3) }),
                                    zs: HybridMatcher.softmax((0..<7).map { _ in Double.random(in: 0...3) }))
        }
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

    private func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
        let fill = String(repeating: " ", count: max(0, width - text.count))
        return left ? fill + text : text + fill
    }

    private func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
    private func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }
}
