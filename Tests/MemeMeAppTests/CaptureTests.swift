import CoreGraphics
import CoreImage
import Foundation
import ImageIO
@testable import MemeMeApp
import XCTest

final class CaptureEncoderTests: XCTestCase {
    func testAGIFHasEveryFrameLoopsAndKeepsItsTiming() throws {
        let frames = try (0..<5).map { try TestImages.shapes(width: 64, height: 64, seed: $0) }
        let data = try XCTUnwrap(CaptureEncoder.gif(frames, frameDelay: 0.08))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 5)
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.compuserve.gif")

        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        XCTAssertEqual((gif?[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue, 0)

        let frame = CGImageSourceCopyPropertiesAtIndex(source, 2, nil) as? [CFString: Any]
        let frameGIF = frame?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = (frameGIF?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
            ?? (frameGIF?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
        XCTAssertEqual(try XCTUnwrap(delay), 0.08, accuracy: 0.011)
    }

    func testNoFramesIsNoGIF() {
        XCTAssertNil(CaptureEncoder.gif([], frameDelay: 0.08))
    }

    func testAPhotoIsAPNG() throws {
        let data = try XCTUnwrap(CaptureEncoder.png(try TestImages.shapes(width: 48, height: 48)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 48)
    }
}

final class CameraFilterTests: XCTestCase {
    private let context = CIContext(options: [.cacheIntermediates: false])

    private func render(_ image: CIImage) throws -> CGImage {
        try XCTUnwrap(context.createCGImage(image, from: CGRect(x: 0, y: 0, width: 160, height: 160)))
    }

    /// A face in a 160 px square picture: eyes 40 px apart, level.
    private let face = FaceAnchors(leftEye: CGPoint(x: 60, y: 100), rightEye: CGPoint(x: 100, y: 100),
                                   mouth: CGPoint(x: 80, y: 60), mouthOpen: 0.2)

    func testEveryFilterKeepsThePictureItsSize() throws {
        let picture = CIImage(cgImage: try TestImages.shapes(width: 160, height: 160))
        for filter in CameraFilter.allCases {
            for anchors in [face, nil] as [FaceAnchors?] {
                let output = filter.apply(to: picture, face: anchors, time: 0.3)
                XCTAssertEqual(output.extent, picture.extent, "\(filter) face: \(anchors != nil)")
                let rendered = try render(output)
                XCTAssertEqual(rendered.width, 160, "\(filter)")
                XCTAssertEqual(rendered.height, 160, "\(filter)")
            }
        }
    }

    func testNoneChangesNothingAndFaceFiltersNeedAFace() {
        let picture = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 160))
        XCTAssertTrue(CameraFilter.none.apply(to: picture, face: face, time: 0) === picture)
        for filter in CameraFilter.allCases where filter.followsFace {
            XCTAssertTrue(filter.apply(to: picture, face: nil, time: 0) === picture, "\(filter)")
        }
    }

    func testFiltersHaveNames() {
        XCTAssertEqual(Set(CameraFilter.allCases.map(\.title)).count, CameraFilter.allCases.count)
        XCTAssertEqual(CameraFilter.allCases.first, CameraFilter.none)
    }
}

final class CaptureGeometryTests: XCTestCase {
    func testAFaceMapsIntoTheMirroredSquare() {
        // 640 × 480: the square is x 80...560. A point at the left of the buffer ends up on the right of the picture.
        let geometry = FaceGeometry(firstEye: CGPoint(x: 0.25, y: 0.5), secondEye: CGPoint(x: 0.5, y: 0.5),
                                    mouth: CGPoint(x: 0.375, y: 0.25), mouthOpen: 0.1)
        let anchors = FaceAnchors(geometry: geometry, imageWidth: 640, imageHeight: 480)
        // x: 0.25 × 640 = 160 → 160 − 80 = 80 → 480 − 80 = 400; 0.5 × 640 = 320 → 240 → 240.
        XCTAssertEqual(anchors.leftEye.x, 240, accuracy: 1e-9)
        XCTAssertEqual(anchors.rightEye.x, 400, accuracy: 1e-9)
        XCTAssertEqual(anchors.leftEye.y, 240, accuracy: 1e-9)
        XCTAssertEqual(anchors.mouth.x, 320, accuracy: 1e-9)
        XCTAssertEqual(anchors.mouth.y, 120, accuracy: 1e-9)
        XCTAssertEqual(anchors.eyeDistance, 160, accuracy: 1e-9)
        XCTAssertEqual(anchors.angle, 0, accuracy: 1e-9)
        XCTAssertEqual(anchors.mouthOpen, 0.1, accuracy: 1e-9)
    }

    func testAboveFollowsTheTilt() {
        let tilted = FaceAnchors(leftEye: CGPoint(x: 0, y: 0), rightEye: CGPoint(x: 10, y: 10), mouth: .zero, mouthOpen: 0)
        let point = tilted.above(CGPoint(x: 0, y: 0), by: 10)
        XCTAssertEqual(point.x, -10 * sin(CGFloat.pi / 4), accuracy: 1e-9)
        XCTAssertEqual(point.y, 10 * cos(CGFloat.pi / 4), accuracy: 1e-9)
    }

    func testBlendingMovesPartWay() {
        let a = FaceAnchors(leftEye: CGPoint(x: 0, y: 0), rightEye: CGPoint(x: 10, y: 0), mouth: .zero, mouthOpen: 0)
        let b = FaceAnchors(leftEye: CGPoint(x: 10, y: 10), rightEye: CGPoint(x: 20, y: 10), mouth: CGPoint(x: 4, y: 4), mouthOpen: 1)
        let half = a.blended(toward: b, amount: 0.5)
        XCTAssertEqual(half.leftEye, CGPoint(x: 5, y: 5))
        XCTAssertEqual(half.rightEye, CGPoint(x: 15, y: 5))
        XCTAssertEqual(half.mouth, CGPoint(x: 2, y: 2))
        XCTAssertEqual(half.mouthOpen, 0.5, accuracy: 1e-9)
    }

    func testTheCaptureIsTheMirroredCenterSquare() throws {
        // Left half red, right half blue, 64 × 32: the square is x 16...48; mirrored, blue comes first.
        let width = 64
        let height = 32
        let context = try TestImages.makeContext(width: width, height: height)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        let frame = CIImage(cgImage: try TestImages.makeImage(context))

        let square = CaptureRenderer.mirroredSquare(frame, width: CGFloat(width), height: CGFloat(height))
        XCTAssertEqual(square.extent, CGRect(x: 0, y: 0, width: 32, height: 32))
        let rendered = try XCTUnwrap(CIContext().createCGImage(square, from: square.extent))
        let pixels = try pixelColors(rendered)
        XCTAssertGreaterThan(pixels.left.blue, 0.8)     // the right of the frame is on the left of the picture
        XCTAssertLessThan(pixels.left.red, 0.2)
        XCTAssertGreaterThan(pixels.right.red, 0.8)
    }

    /// RGB (0...1) at the left and right edge of the middle row.
    private func pixelColors(_ image: CGImage) throws -> (left: (red: Double, blue: Double), right: (red: Double, blue: Double)) {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn)
        func color(atX x: Int) -> (red: Double, blue: Double) {
            let offset = ((height / 2) * width + x) * 4
            return (Double(bytes[offset]) / 255, Double(bytes[offset + 2]) / 255)
        }
        return (color(atX: 2), color(atX: width - 3))
    }
}

final class ClipTimingTests: XCTestCase {
    func testAGIFPlaysAtTheSpeedItWasRecorded() {
        // A 30 fps camera keeps every third frame: 0.1 s apart.
        XCTAssertEqual(CaptureRenderer.frameDelay(frameCount: 31, first: 10, last: 13), 0.1, accuracy: 1e-9)
        // Dim light, 15 fps: every second frame, 0.133 s apart → 0.13.
        XCTAssertEqual(CaptureRenderer.frameDelay(frameCount: 4, first: 0, last: 0.4), 0.13, accuracy: 1e-9)
        XCTAssertEqual(CaptureRenderer.frameDelay(frameCount: 3, first: 1, last: 1.01), 0.02, accuracy: 1e-9)
    }

    func testTooFewFramesUseTheDefaultDelay() {
        XCTAssertEqual(CaptureRenderer.frameDelay(frameCount: 1, first: 2, last: 2), CaptureRenderer.clipFrameDelay)
        XCTAssertEqual(CaptureRenderer.frameDelay(frameCount: 0, first: nil, last: nil), CaptureRenderer.clipFrameDelay)
        XCTAssertEqual(CaptureRenderer.frameDelay(frameCount: 5, first: 3, last: 3), CaptureRenderer.clipFrameDelay)
    }
}
