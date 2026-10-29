import CoreGraphics
import Foundation
import ImageIO
@testable import MemeMeApp
import MemeMeCore
import XCTest

final class ImageAnalyzerTests: XCTestCase {
    // MARK: - Loading (ImageIO only)

    func testAnimatedGIFLoadsThreeFrames() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let url = sandbox.file("dance.gif")
        let frames = try (0..<3).map { try TestImages.shapes(width: 120, height: 120, seed: $0) }
        try TestImages.writeGIF(frames, to: url)

        let loaded = try XCTUnwrap(ImageAnalyzer.load(url: url), "ImageIO should read a GIF it just wrote")

        XCTAssertTrue(loaded.isAnimated)
        XCTAssertEqual(loaded.frames.count, 3, "Animated images keep the first, middle and 3/4 frames")
        XCTAssertEqual(loaded.pixelWidth, 120)
        XCTAssertEqual(loaded.pixelHeight, 120)
        XCTAssertEqual(loaded.cgImage.width, 120)
        XCTAssertEqual(loaded.data, try Data(contentsOf: url))
        XCTAssertFalse(loaded.isCameraPhoto)
        XCTAssertFalse(loaded.isScreenshot)
    }

    func testLongGIFStillKeepsAtMostThreeFrames() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let url = sandbox.file("long.gif")
        let frames = try (0..<8).map { try TestImages.shapes(width: 96, height: 96, seed: $0) }
        try TestImages.writeGIF(frames, to: url)

        let loaded = try XCTUnwrap(ImageAnalyzer.load(url: url))

        XCTAssertTrue(loaded.isAnimated)
        XCTAssertEqual(loaded.frames.count, 3)
    }

    func testSingleFrameGIFAndPNGAreStills() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let gifURL = sandbox.file("still.gif")
        let pngURL = sandbox.file("still.png")
        try TestImages.writeGIF([try TestImages.shapes(width: 100, height: 80)], to: gifURL)
        try TestImages.writePNG(try TestImages.shapes(width: 100, height: 80), to: pngURL)

        for url in [gifURL, pngURL] {
            let loaded = try XCTUnwrap(ImageAnalyzer.load(url: url), url.lastPathComponent)
            XCTAssertFalse(loaded.isAnimated, url.lastPathComponent)
            XCTAssertEqual(loaded.frames.count, 1, url.lastPathComponent)
            XCTAssertEqual(loaded.pixelWidth, 100, url.lastPathComponent)
            XCTAssertEqual(loaded.pixelHeight, 80, url.lastPathComponent)
        }
    }

    func testLoadRejectsNonImagesFoldersRemoteURLsAndFilesOver25MB() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }

        let notes = sandbox.file("notes.txt")
        try Data("not an image".utf8).write(to: notes)
        XCTAssertNil(ImageAnalyzer.load(url: notes))

        let folder = try sandbox.directory("Folder.png")
        XCTAssertNil(ImageAnalyzer.load(url: folder))

        let remote = try XCTUnwrap(URL(string: "https://media.giphy.com/media/abc/giphy.gif"))
        XCTAssertNil(ImageAnalyzer.load(url: remote))

        // A sparse 26 MB file: rejected by size before it is read.
        let big = sandbox.file("big.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: big.path, contents: Data([0x89, 0x50, 0x4E, 0x47])))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: 26 * 1024 * 1024)
        try handle.close()
        XCTAssertNil(ImageAnalyzer.load(url: big))
    }

    func testScreenshotNamesAndCameraMetadata() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let image = try TestImages.shapes(width: 160, height: 120)
        let cameraMetadata: [String: Any] = [
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "Apple",
                kCGImagePropertyTIFFModel as String: "iPhone 15 Pro",
            ],
        ]

        let screenshot = sandbox.file("Screenshot 2026-03-02 at 10.00.00.png")
        try TestImages.writePNG(image, to: screenshot)
        let loadedScreenshot = try XCTUnwrap(ImageAnalyzer.load(url: screenshot))
        XCTAssertTrue(loadedScreenshot.isScreenshot)
        XCTAssertFalse(loadedScreenshot.isCameraPhoto)

        let photo = sandbox.file("IMG_2207.jpg")
        try TestImages.writeJPEG(image, to: photo, properties: cameraMetadata)
        let loadedPhoto = try XCTUnwrap(ImageAnalyzer.load(url: photo))
        XCTAssertTrue(loadedPhoto.isCameraPhoto, "TIFF Make/Model marks a camera photo")
        XCTAssertFalse(loadedPhoto.isScreenshot)

        // A screenshot is never a camera photo, even with Make/Model present.
        let cleanShot = sandbox.file("CleanShot 2026-03-02.jpg")
        try TestImages.writeJPEG(image, to: cleanShot, properties: cameraMetadata)
        let loadedCleanShot = try XCTUnwrap(ImageAnalyzer.load(url: cleanShot))
        XCTAssertTrue(loadedCleanShot.isScreenshot)
        XCTAssertFalse(loadedCleanShot.isCameraPhoto)

        let plain = sandbox.file("meme.png")
        try TestImages.writePNG(image, to: plain)
        let loadedPlain = try XCTUnwrap(ImageAnalyzer.load(url: plain))
        XCTAssertFalse(loadedPlain.isScreenshot)
        XCTAssertFalse(loadedPlain.isCameraPhoto)
    }

    func testEXIFRotationSwapsWidthAndHeight() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let url = sandbox.file("rotated.jpg")
        // Stored 200 × 100, displayed rotated by 90° (EXIF orientation 6) → 100 × 200.
        try TestImages.writeJPEG(
            try TestImages.shapes(width: 200, height: 100),
            to: url,
            properties: [kCGImagePropertyOrientation as String: 6]
        )

        let loaded = try XCTUnwrap(ImageAnalyzer.load(url: url))

        XCTAssertEqual(loaded.pixelWidth, 100)
        XCTAssertEqual(loaded.pixelHeight, 200)
        XCTAssertEqual(loaded.cgImage.width, 100, "Frames are decoded with the orientation applied")
        XCTAssertEqual(loaded.cgImage.height, 200)
    }

    // MARK: - Hashing

    func testSHA256HexMatchesTheStandardVector() {
        XCTAssertEqual(
            ImageAnalyzer.sha256Hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            ImageAnalyzer.sha256Hex(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    // MARK: - Analysis (needs Vision)

    func testAnimatedGIFAnalysisIsAMeme() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let url = sandbox.file("dance.gif")
        let frames = try (0..<3).map { try TestImages.shapes(width: 120, height: 120, seed: $0) }
        try TestImages.writeGIF(frames, to: url)

        let analysis = try analyzeWithVision(url)

        XCTAssertTrue(analysis.facts.isAnimated)
        XCTAssertEqual(analysis.facts.pixelWidth, 120)
        XCTAssertEqual(analysis.facts.pixelHeight, 120)
        XCTAssertEqual(MemeTierClassifier.tier(for: analysis.facts), .meme, "Animated images are always memes")
        XCTAssertNil(analysis.face)
        XCTAssertNil(analysis.faceShape)
        XCTAssertEqual(analysis.facts.faceCount, 0)
    }

    func testTheFacePassReadsTheFaceAloneOrNothing() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let url = sandbox.file("dance.gif")
        let frames = try (0..<3).map { try TestImages.shapes(width: 120, height: 120, seed: $0) }
        try TestImages.writeGIF(frames, to: url)

        guard case let .read(face, shape, intensity) = ImageAnalyzer.analyzeFace(url: url) else {
            return XCTFail("a readable GIF is read (this test needs Vision face landmarks on the test machine)")
        }
        XCTAssertNil(face, "shapes have no face")
        XCTAssertNil(shape)
        XCTAssertEqual(intensity, 0)

        let notes = sandbox.file("notes.txt")
        try Data("not an image".utf8).write(to: notes)
        guard case .unreadable = ImageAnalyzer.analyzeFace(url: notes) else {
            return XCTFail("a text file is unreadable")
        }
    }

    func testRecognizesLargeTextInAPNG() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let url = sandbox.file("no-way.png")
        try TestImages.writePNG(try TestImages.text("NO WAY"), to: url)

        let analysis = try analyzeWithVision(url)

        XCTAssertTrue(
            analysis.text.uppercased().contains("NO"),
            "Vision text recognition (.fast) should read the big black “NO WAY” on white; got “\(analysis.text)”"
        )
        XCTAssertGreaterThanOrEqual(analysis.facts.textCharacterCount, 2)
        XCTAssertLessThanOrEqual(analysis.text.count, 200)
        XCTAssertFalse(analysis.facts.isAnimated)
    }

    func testSkippingTextRecognitionLeavesTextEmpty() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let url = sandbox.file("no-way.png")
        try TestImages.writePNG(try TestImages.text("NO WAY"), to: url)

        let analysis = try analyzeWithVision(url, includeText: false)

        XCTAssertEqual(analysis.text, "")
        XCTAssertEqual(analysis.facts.textCharacterCount, 0)
    }

    func testFeaturePrintUsesTheSharedRevision() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let url = sandbox.file("landscape.png")
        try TestImages.writePNG(try TestImages.landscape(), to: url)

        let analysis = try analyzeWithVision(url)

        let fingerprint = try XCTUnwrap(analysis.featurePrint, "VNGenerateImageFeaturePrintRequest produced no feature print")
        XCTAssertFalse(fingerprint.isEmpty)
        XCTAssertTrue(fingerprint.allSatisfy { $0.isFinite })
        XCTAssertEqual(analysis.featurePrintRevision, ImageAnalyzer.featurePrintRevision)

        // The standalone entry point (used for query images and stickers) must produce comparable prints.
        let direct = try ImageAnalyzer.featurePrint(of: analysis.chosenFrame)
        XCTAssertEqual(direct.count, fingerprint.count)
        XCTAssertGreaterThan(VectorMath.cosine(direct, fingerprint), 0.99)

        // No people in a landscape.
        XCTAssertNil(analysis.face)
        XCTAssertTrue(analysis.faceBoxes.isEmpty)
        XCTAssertEqual(analysis.intensity, 0)
        XCTAssertEqual(analysis.facts.faceCount, 0)
        XCTAssertEqual(analysis.facts.pixelWidth, 640)
        XCTAssertEqual(analysis.facts.pixelHeight, 427)
    }

    func testContentHashIsStableForIdenticalBytes() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let original = sandbox.file("reaction.png")
        try TestImages.writePNG(try TestImages.shapes(width: 128, height: 128, seed: 3), to: original)
        let copy = sandbox.file("copy of reaction.png")
        try FileManager.default.copyItem(at: original, to: copy)
        let bytes = try Data(contentsOf: original)

        let first = try analyzeWithVision(original)
        let second = try analyzeWithVision(copy)

        XCTAssertEqual(first.contentHash, second.contentHash, "The hash depends on the bytes, not the file name")
        XCTAssertEqual(first.contentHash, ImageAnalyzer.sha256Hex(bytes))
        XCTAssertEqual(first.contentHash.count, 64)

        let other = sandbox.file("other.png")
        try TestImages.writePNG(try TestImages.shapes(width: 128, height: 128, seed: 4), to: other)
        XCTAssertNotEqual(ImageAnalyzer.sha256Hex(try Data(contentsOf: other)), first.contentHash)
    }

    func testTinyPNGIsClassifiedSkipped() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let url = sandbox.file("icon.png")
        try TestImages.writePNG(try TestImages.shapes(width: 32, height: 32, seed: 5), to: url)

        let analysis = try analyzeWithVision(url)

        XCTAssertEqual(analysis.facts.pixelWidth, 32)
        XCTAssertEqual(analysis.facts.pixelHeight, 32)
        XCTAssertEqual(MemeTierClassifier.tier(for: analysis.facts), .skipped, "Images under 64 px are skipped")
    }
}
