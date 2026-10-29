import CoreGraphics
import CoreVideo
import Foundation
@testable import MemeMeApp
import MemeMeCore
import XCTest

/// The seven features measured in the face's own frame, and the pixels the face's colors are read from.
final class FaceFeatureExtractorTests: XCTestCase {
    // MARK: A synthetic face (face-box-normalized, origin bottom-left)

    /// A hexagon 0.12 wide and 0.04 high around `center`.
    private static func eye(_ center: CGPoint) -> [CGPoint] {
        [CGPoint(x: center.x - 0.06, y: center.y), CGPoint(x: center.x - 0.03, y: center.y + 0.02),
         CGPoint(x: center.x + 0.03, y: center.y + 0.02), CGPoint(x: center.x + 0.06, y: center.y),
         CGPoint(x: center.x + 0.03, y: center.y - 0.02), CGPoint(x: center.x - 0.03, y: center.y - 0.02)]
    }

    /// Eyes at (0.35, 0.6) and (0.65, 0.6) looking ahead, brows 0.09 over them, lips 0.24 wide with their corners
    /// at 0.3, the mouth closed (0.01 open).
    private static let face = FaceShapeMeasure.Landmarks(
        leftEye: FaceFeatureExtractorTests.eye(CGPoint(x: 0.65, y: 0.6)),
        rightEye: FaceFeatureExtractorTests.eye(CGPoint(x: 0.35, y: 0.6)),
        leftBrow: [CGPoint(x: 0.59, y: 0.69), CGPoint(x: 0.65, y: 0.69), CGPoint(x: 0.71, y: 0.69)],
        rightBrow: [CGPoint(x: 0.29, y: 0.69), CGPoint(x: 0.35, y: 0.69), CGPoint(x: 0.41, y: 0.69)],
        outerLips: [
            CGPoint(x: 0.38, y: 0.30), CGPoint(x: 0.42, y: 0.33), CGPoint(x: 0.46, y: 0.345), CGPoint(x: 0.50, y: 0.34),
            CGPoint(x: 0.54, y: 0.345), CGPoint(x: 0.58, y: 0.33), CGPoint(x: 0.62, y: 0.30), CGPoint(x: 0.58, y: 0.27),
            CGPoint(x: 0.54, y: 0.258), CGPoint(x: 0.50, y: 0.255), CGPoint(x: 0.46, y: 0.258), CGPoint(x: 0.42, y: 0.27),
        ],
        innerLips: [
            CGPoint(x: 0.40, y: 0.30), CGPoint(x: 0.45, y: 0.305), CGPoint(x: 0.50, y: 0.305), CGPoint(x: 0.55, y: 0.305),
            CGPoint(x: 0.60, y: 0.30), CGPoint(x: 0.55, y: 0.295), CGPoint(x: 0.50, y: 0.295), CGPoint(x: 0.45, y: 0.295),
        ],
        leftPupil: [CGPoint(x: 0.65, y: 0.6)],
        rightPupil: [CGPoint(x: 0.35, y: 0.6)]
    )

    /// The face turned by `degrees` about the middle of its box.
    private static func tilted(_ landmarks: FaceShapeMeasure.Landmarks, degrees: Double) -> FaceShapeMeasure.Landmarks {
        let angle = degrees * Double.pi / 180
        func turn(_ points: [CGPoint]) -> [CGPoint] {
            points.map { point in
                let x = Double(point.x) - 0.5
                let y = Double(point.y) - 0.5
                return CGPoint(x: 0.5 + x * cos(angle) - y * sin(angle), y: 0.5 + x * sin(angle) + y * cos(angle))
            }
        }
        return FaceShapeMeasure.Landmarks(
            leftEye: turn(landmarks.leftEye), rightEye: turn(landmarks.rightEye),
            leftBrow: turn(landmarks.leftBrow), rightBrow: turn(landmarks.rightBrow),
            outerLips: turn(landmarks.outerLips), innerLips: turn(landmarks.innerLips),
            leftPupil: turn(landmarks.leftPupil), rightPupil: turn(landmarks.rightPupil)
        )
    }

    // MARK: The seven features

    func testAnUprightFaceMeasuresAsBefore() throws {
        let features = try XCTUnwrap(FaceFeatureExtractor.features(from: FaceFeatureExtractorTests.face, roll: 0))
        // Brows: (0.69 − 0.6 − 0.02) / 0.2. Eyes: (0.04 / 0.12 − 0.05) / 0.5. Mouth: 0.01 / 0.25 open,
        // (0.24 − 0.2) / 0.5 wide. Smile: corners at 0.3, the lips' mean height 3.601 / 12, so
        // 0.5 + 2.5 × (0.3 − 3.601 / 12) / 0.24 = 0.5 − 1 / 1152. Gaze: the pupils in the middle.
        XCTAssertEqual(features.browRaise, 0.35, accuracy: 1e-9)
        XCTAssertEqual(features.eyeOpenness, 0.85 / 1.5, accuracy: 1e-9)
        XCTAssertEqual(features.mouthOpenness, 0.04, accuracy: 1e-9)
        XCTAssertEqual(features.mouthWidth, 0.08, accuracy: 1e-9)
        XCTAssertEqual(features.smile, 0.5 - 1.0 / 1152, accuracy: 1e-9)
        XCTAssertEqual(features.headTilt, 0, accuracy: 1e-9)
        XCTAssertEqual(features.gazeSide, 0, accuracy: 1e-9)
        // A roll of 22.5° is half the head tilt's range.
        let rolled = try XCTUnwrap(FaceFeatureExtractor.features(from: FaceFeatureExtractorTests.face, roll: -Double.pi / 8))
        XCTAssertEqual(rolled.headTilt, 0.5, accuracy: 1e-9)
    }

    func testATiltedHeadDoesntReadAsAnOpenMouth() throws {
        let upright = try XCTUnwrap(FaceFeatureExtractor.features(from: FaceFeatureExtractorTests.face, roll: 0))
        for degrees in [20.0, -20, 35] {
            let tilted = FaceFeatureExtractorTests.tilted(FaceFeatureExtractorTests.face, degrees: degrees)
            // Measured in the picture's axes, the closed mouth turned 20° would span 0.068 in height: 0.27 open.
            let features = try XCTUnwrap(FaceFeatureExtractor.features(from: tilted, roll: 0))
            for (value, expected) in zip(features.vector, upright.vector) {
                XCTAssertEqual(value, expected, accuracy: 1e-9, "\(degrees)°")
            }
        }
    }

    func testFeaturesNeedEyesOrLips() {
        XCTAssertNil(FaceFeatureExtractor.features(from: FaceShapeMeasure.Landmarks(), roll: 0))
        // Lips alone: measured as they are, the eyes at their usual values.
        let lipsOnly = FaceShapeMeasure.Landmarks(outerLips: FaceFeatureExtractorTests.face.outerLips,
                                                  innerLips: FaceFeatureExtractorTests.face.innerLips)
        let features = FaceFeatureExtractor.features(from: lipsOnly, roll: 0)
        XCTAssertEqual(features?.mouthOpenness ?? 0, 0.04, accuracy: 1e-9)
        XCTAssertEqual(features?.eyeOpenness ?? 0, FaceFeatures.populationNeutral.eyeOpenness, accuracy: 1e-9)
    }

    // MARK: Colors

    /// A 4 × 2 camera frame (32BGRA): the top row red with its last pixel green, the bottom row blue.
    private func makeFrame(format: OSType = kCVPixelFormatType_32BGRA) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 4, 2, format, nil, &created)
        let buffer = try XCTUnwrap(created, "CVPixelBufferCreate failed (\(status))")
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { _ = CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<2 {
            for column in 0..<4 {
                // Blue, green, red, alpha.
                let pixel: [UInt8]
                if row == 1 {
                    pixel = [255, 0, 0, 255]
                } else if column == 3 {
                    pixel = [0, 255, 0, 255]
                } else {
                    pixel = [0, 0, 255, 255]
                }
                for (index, value) in pixel.enumerated() {
                    base[row * bytesPerRow + column * 4 + index] = value
                }
            }
        }
        return buffer
    }

    private func assertColor(_ sample: FaceShapeMeasure.Sample?, luma: Double, redness: Double, accuracy: Double = 1e-6,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let sample else {
            XCTFail("no color", file: file, line: line)
            return
        }
        XCTAssertEqual(sample.luma, luma, accuracy: accuracy, "luma", file: file, line: line)
        XCTAssertEqual(sample.redness, redness, accuracy: accuracy, "redness", file: file, line: line)
    }

    // BT.601 of pure red, green and blue: luma 0.299, 0.587, 0.114 × 255; Cr 128 + 0.5, − 0.4187, − 0.0813 × 255.
    private static let red = (luma: 76.245, redness: 255.5)
    private static let green = (luma: 149.685, redness: 21.2315)
    private static let blue = (luma: 29.07, redness: 107.2685)

    func testACameraFrameIsReadFromTheTopRowDown() throws {
        let frame = try makeFrame()
        // The face box is the frame's right half: its point (0.5, 0.75) is pixel x 3, y 1.5 from the bottom (the top
        // row); (0.1, 0.75) is x 2.2.
        let box = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let samples = FaceFeatureExtractor.withColors(of: frame, box: box) { color -> [FaceShapeMeasure.Sample?]? in
            guard let color else { return nil }
            return [CGPoint(x: 0.5, y: 0.75), CGPoint(x: 0.1, y: 0.75), CGPoint(x: 0.5, y: 0.25),
                    CGPoint(x: 1, y: 0.5), CGPoint(x: -1.2, y: 0.5), CGPoint(x: 0.5, y: 1)].map(color)
        }
        let read = try XCTUnwrap(samples, "a 32BGRA frame is read")
        assertColor(read[0], luma: FaceFeatureExtractorTests.green.luma, redness: FaceFeatureExtractorTests.green.redness)
        assertColor(read[1], luma: FaceFeatureExtractorTests.red.luma, redness: FaceFeatureExtractorTests.red.redness)
        assertColor(read[2], luma: FaceFeatureExtractorTests.blue.luma, redness: FaceFeatureExtractorTests.blue.redness)
        XCTAssertNil(read[3], "x 4 is past the right edge")
        XCTAssertNil(read[4], "left of the picture")
        XCTAssertNil(read[5], "y 2 is past the top")

        // Another pixel format isn't read.
        let other = try makeFrame(format: kCVPixelFormatType_32ARGB)
        let isRead = FaceFeatureExtractor.withColors(of: other, box: box) { color in color != nil }
        XCTAssertFalse(isRead)
    }

    func testAnImageIsDrawnSmallAndReadLikeAFrame() throws {
        // 1024 × 512: the top half red, the bottom half blue (rows top-down, as CGImage keeps them).
        let width = 1024
        let height = 512
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * 4)
        for row in 0..<height {
            let pixel: [UInt8] = row < height / 2 ? [255, 0, 0, 255] : [0, 0, 255, 255]
            for _ in 0..<width {
                bytes.append(contentsOf: pixel)
            }
        }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))

        let pixels = try XCTUnwrap(RGBAPixels(image: image))
        XCTAssertEqual(pixels.width, 512, "at most 512 on the longer side")
        XCTAssertEqual(pixels.height, 256)
        XCTAssertEqual(pixels.bytes.count, 512 * 256 * 4)
        let samples = pixels.withColors(box: CGRect(x: 0, y: 0, width: 1, height: 1)) { color in
            [CGPoint(x: 0.5, y: 0.75), CGPoint(x: 0.5, y: 0.25), CGPoint(x: 0.5, y: 1.2)].map { point in color?(point) }
        }
        assertColor(samples[0], luma: FaceFeatureExtractorTests.red.luma, redness: FaceFeatureExtractorTests.red.redness,
                    accuracy: 1.5)
        assertColor(samples[1], luma: FaceFeatureExtractorTests.blue.luma, redness: FaceFeatureExtractorTests.blue.redness,
                    accuracy: 1.5)
        XCTAssertNil(samples[2])

        // A small image keeps its size.
        let small = try XCTUnwrap(RGBAPixels(image: try TestImages.shapes(width: 100, height: 60)))
        XCTAssertEqual(small.width, 100)
        XCTAssertEqual(small.height, 60)
    }
}
