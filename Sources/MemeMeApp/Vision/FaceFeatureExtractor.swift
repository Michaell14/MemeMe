import CoreGraphics
import CoreVideo
import Foundation
import MemeMeCore
import Vision

/// Maps Vision face landmarks and body joints to MemeMe's normalized expression features.
///
/// Landmark `normalizedPoints` are relative to the face bounding box (origin bottom-left);
/// body joint locations are Vision-normalized image coordinates (origin bottom-left).
enum FaceFeatureExtractor {
    /// Padding added on each side of the eyes and mouth rects, as a fraction of the rect's size.
    private static let regionPadding: CGFloat = 0.25

    /// The picture's color at a face-box-normalized point (nil outside the picture), as `FaceShapeMeasure` reads it.
    typealias ColorReader = (CGPoint) -> FaceShapeMeasure.Sample?

    /// nil when the observation has no landmarks.
    static func features(from face: VNFaceObservation) -> FaceFeatures? {
        guard let landmarks = FaceFeatureExtractor.landmarks(of: face) else { return nil }
        return features(from: landmarks, roll: face.roll?.doubleValue ?? 0)
    }

    /// The seven features from a face's landmark contours (face-box-normalized), measured in the face's own frame:
    /// the contours are first turned about the eyes' midpoint until the line through the eyes is level
    /// (`FaceShapeMeasure.leveled`), so a tilted head doesn't read as an open mouth or raised brows. An upright face
    /// measures as it is. `roll` is the head's roll in radians (headTilt). nil without eyes and lips.
    static func features(from landmarks: FaceShapeMeasure.Landmarks, roll: Double) -> FaceFeatures? {
        let neutral = FaceFeatures.populationNeutral
        let leveled = FaceShapeMeasure.leveled(landmarks)

        let leftEye = leveled.leftEye
        let rightEye = leveled.rightEye
        let leftBrow = leveled.leftBrow
        let rightBrow = leveled.rightBrow
        let outerLips = leveled.outerLips
        let innerLips = leveled.innerLips

        let eyeContours = [leftEye, rightEye].filter { $0.count >= 2 }
        guard !eyeContours.isEmpty || outerLips.count >= 2 else { return nil }

        // Eyes: height / width of each eye contour, averaged.
        var eyeOpenness = neutral.eyeOpenness
        let eyeRatios: [Double] = eyeContours.compactMap { (contour: [CGPoint]) -> Double? in
            let box = bounds(of: contour)
            guard box.width > 1e-6 else { return nil }
            return Double(box.height / box.width)
        }
        if let ratio = mean(eyeRatios) {
            eyeOpenness = clamp((ratio - 0.05) / 0.5)
        }

        // Brows: vertical gap between the brows and the eyes.
        var browRaise = neutral.browRaise
        let browPoints = leftBrow + rightBrow
        let eyePoints = eyeContours.flatMap { $0 }
        if let browY = meanY(browPoints), let eyeY = meanY(eyePoints) {
            browRaise = clamp((browY - eyeY - 0.02) / 0.2)
        }

        // Mouth opening from the inner lips.
        var mouthOpenness = neutral.mouthOpenness
        if innerLips.count >= 2 {
            mouthOpenness = clamp(Double(bounds(of: innerLips).height) / 0.25)
        }

        // Mouth width and smile from the outer lips.
        var mouthWidth = neutral.mouthWidth
        var smile = neutral.smile
        if outerLips.count >= 2 {
            let lipBox = bounds(of: outerLips)
            let lipWidth = Double(lipBox.width)
            mouthWidth = clamp((lipWidth - 0.2) / 0.5)
            if let leftCorner = outerLips.min(by: { $0.x < $1.x }),
               let rightCorner = outerLips.max(by: { $0.x < $1.x }),
               let lipsY = meanY(outerLips) {
                let cornerY = (Double(leftCorner.y) + Double(rightCorner.y)) / 2
                let lift = (cornerY - lipsY) / max(lipWidth, 0.01)
                smile = clamp(0.5 + 2.5 * lift)
            }
        }

        // Head tilt from the roll angle (radians).
        let headTilt = clamp(abs(roll) / (Double.pi / 4))

        // Gaze: signed pupil offset from each eye's center, averaged over both eyes.
        var gazeOffsets: [Double] = []
        if let offset = gazeOffset(pupil: leveled.leftPupil, eye: leftEye) {
            gazeOffsets.append(offset)
        }
        if let offset = gazeOffset(pupil: leveled.rightPupil, eye: rightEye) {
            gazeOffsets.append(offset)
        }
        let gazeSide: Double
        if let offset = mean(gazeOffsets) {
            gazeSide = clamp(abs(offset) * 3)
        } else {
            gazeSide = 0.1
        }

        return FaceFeatures(
            browRaise: browRaise,
            eyeOpenness: eyeOpenness,
            mouthOpenness: mouthOpenness,
            mouthWidth: mouthWidth,
            smile: smile,
            headTilt: headTilt,
            gazeSide: gazeSide
        )
    }

    /// The face's landmark contours (face-box-normalized); nil when the observation has no landmarks.
    static func landmarks(of face: VNFaceObservation) -> FaceShapeMeasure.Landmarks? {
        guard let landmarks = face.landmarks else { return nil }
        return FaceShapeMeasure.Landmarks(
            leftEye: points(of: landmarks.leftEye),
            rightEye: points(of: landmarks.rightEye),
            leftBrow: points(of: landmarks.leftEyebrow),
            rightBrow: points(of: landmarks.rightEyebrow),
            outerLips: points(of: landmarks.outerLips),
            innerLips: points(of: landmarks.innerLips),
            leftPupil: points(of: landmarks.leftPupil),
            rightPupil: points(of: landmarks.rightPupil)
        )
    }

    // MARK: - Face shape

    /// The face's `FaceShape` in a camera frame, its tongue read from the frame's colors (a frame that isn't 32BGRA
    /// gives a shape without the tongue). nil without landmarks or both eyes.
    static func shape(from face: VNFaceObservation, pixelBuffer: CVPixelBuffer) -> FaceShape? {
        guard let landmarks = FaceFeatureExtractor.landmarks(of: face) else { return nil }
        return withColors(of: pixelBuffer, box: face.boundingBox) { color in
            FaceShapeMeasure.shape(of: landmarks, color: color)
        }
    }

    /// The face's `FaceShape` in an image, its tongue read from `pixels` (the image drawn by `RGBAPixels`; nil gives
    /// a shape without the tongue). nil without landmarks or both eyes.
    static func shape(from face: VNFaceObservation, pixels: RGBAPixels?) -> FaceShape? {
        guard let landmarks = FaceFeatureExtractor.landmarks(of: face) else { return nil }
        guard let pixels else { return FaceShapeMeasure.shape(of: landmarks, color: nil) }
        return pixels.withColors(box: face.boundingBox) { color in
            FaceShapeMeasure.shape(of: landmarks, color: color)
        }
    }

    /// Calls `body` with the colors of a 32BGRA camera frame at face-box-normalized points of `box` (a
    /// Vision-normalized face box), or with nil for another pixel format or a frame that can't be read. The buffer is
    /// locked read-only while `body` runs; the reader must not be kept.
    static func withColors<T>(of pixelBuffer: CVPixelBuffer, box: CGRect, _ body: (ColorReader?) -> T) -> T {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(pixelBuffer),
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return body(nil)
        }
        defer { _ = CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer), width > 0, height > 0, bytesPerRow >= width * 4 else {
            return body(nil)
        }
        let sampler = PixelSampler(bytes: UnsafeRawBufferPointer(start: base, count: bytesPerRow * height),
                                   width: width, height: height, bytesPerRow: bytesPerRow,
                                   channels: PixelSampler.bgra, box: box)
        return body({ point in sampler.sample(at: point) })
    }

    /// The body pose of the person whose face is `faceBox` (Vision-normalized), with the strongest sign of their
    /// hands; nil when no body was found.
    static func pose(bodies: [VNHumanBodyPoseObservation], hands: [VNHumanHandPoseObservation] = [],
                     faceBox: CGRect?, imageWidth: Int, imageHeight: Int) -> PoseFeatures? {
        guard let body = primaryBody(bodies, faceBox: faceBox, imageWidth: imageWidth, imageHeight: imageHeight) else {
            return nil
        }
        let box = poseBox(faceBox, imageWidth: imageWidth, imageHeight: imageHeight)
        let own = body.ownHands(handJoints(hands, imageWidth: imageWidth, imageHeight: imageHeight))
        return PoseFeatures(joints: body, hand: HandShape.strongest(of: own, faceBox: box))
    }

    /// The body that goes with the face (see `BodyJoints.primary`).
    static func primaryBody(_ bodies: [VNHumanBodyPoseObservation], faceBox: CGRect?, imageWidth: Int, imageHeight: Int) -> BodyJoints? {
        let joints = bodies.map { bodyJoints(from: $0, imageWidth: Double(imageWidth), imageHeight: Double(imageHeight)) }
        return BodyJoints.primary(of: joints, faceBox: poseBox(faceBox, imageWidth: imageWidth, imageHeight: imageHeight))
    }

    /// A Vision-normalized face box in the pose's aspect-corrected units.
    static func poseBox(_ faceBox: CGRect?, imageWidth: Int, imageHeight: Int) -> PoseBox? {
        faceBox.map {
            PoseBox(normalizedX: Double($0.minX), y: Double($0.minY), width: Double($0.width), height: Double($0.height),
                    imageWidth: Double(imageWidth), imageHeight: Double(imageHeight))
        }
    }

    static func handJoints(_ hands: [VNHumanHandPoseObservation], imageWidth: Int, imageHeight: Int) -> [HandJoints] {
        hands.map { hand in
            var readings: [HandJoint: JointReading] = [:]
            if let points = try? hand.recognizedPoints(.all) {
                for (name, joint) in handJointNames {
                    if let point = points[name] {
                        readings[joint] = reading(point)
                    }
                }
            }
            return HandJoints(readings: readings, imageWidth: Double(imageWidth), imageHeight: Double(imageHeight))
        }
    }

    private static func bodyJoints(from body: VNHumanBodyPoseObservation, imageWidth: Double, imageHeight: Double) -> BodyJoints {
        var readings: [BodyJoint: JointReading] = [:]
        if let points = try? body.recognizedPoints(.all) {
            for (name, joint) in bodyJointNames {
                if let point = points[name] {
                    readings[joint] = reading(point)
                }
            }
        }
        return BodyJoints(readings: readings, imageWidth: imageWidth, imageHeight: imageHeight)
    }

    private static func reading(_ point: VNRecognizedPoint) -> JointReading {
        JointReading(x: Double(point.location.x), y: Double(point.location.y), confidence: Double(point.confidence))
    }

    private static let bodyJointNames: [(VNHumanBodyPoseObservation.JointName, BodyJoint)] = [
        (.nose, .nose), (.leftEye, .leftEye), (.rightEye, .rightEye), (.leftEar, .leftEar), (.rightEar, .rightEar),
        (.neck, .neck), (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
        (.leftElbow, .leftElbow), (.rightElbow, .rightElbow), (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
        (.root, .root), (.leftHip, .leftHip), (.rightHip, .rightHip),
    ]

    private static let handJointNames: [(VNHumanHandPoseObservation.JointName, HandJoint)] = [
        (.wrist, .wrist),
        (.thumbCMC, .thumbCMC), (.thumbMP, .thumbMP), (.thumbIP, .thumbIP), (.thumbTip, .thumbTip),
        (.indexMCP, .indexMCP), (.indexPIP, .indexPIP), (.indexDIP, .indexDIP), (.indexTip, .indexTip),
        (.middleMCP, .middleMCP), (.middlePIP, .middlePIP), (.middleDIP, .middleDIP), (.middleTip, .middleTip),
        (.ringMCP, .ringMCP), (.ringPIP, .ringPIP), (.ringDIP, .ringDIP), (.ringTip, .ringTip),
        (.littleMCP, .littleMCP), (.littlePIP, .littlePIP), (.littleDIP, .littleDIP), (.littleTip, .littleTip),
    ]

    /// Vision-normalized image rects (origin bottom-left) for .eyes (union of both eyes) and .mouth (outer lips), padded 25 %; .brows (union of brows).
    static func regionRects(from face: VNFaceObservation) -> [FaceRegion: CGRect] {
        guard let landmarks = face.landmarks else { return [:] }
        let box = face.boundingBox
        var rects: [FaceRegion: CGRect] = [:]
        if let eyes = imageRect(of: [landmarks.leftEye, landmarks.rightEye], in: box) {
            rects[.eyes] = padded(eyes)
        }
        if let mouth = imageRect(of: [landmarks.outerLips], in: box) {
            rects[.mouth] = padded(mouth)
        }
        if let brows = imageRect(of: [landmarks.leftEyebrow, landmarks.rightEyebrow], in: box) {
            rects[.brows] = brows
        }
        return rects
    }

    // MARK: - Helpers

    private static func points(of region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
        guard let region else { return [] }
        return region.normalizedPoints.filter { $0.x.isFinite && $0.y.isFinite }
    }

    /// Bounding rect of the points; `.zero` for an empty array.
    private static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Converts the union of landmark regions from face-box coordinates to Vision-normalized image coordinates.
    private static func imageRect(of regions: [VNFaceLandmarkRegion2D?], in box: CGRect) -> CGRect? {
        let regionPoints = regions.flatMap { points(of: $0) }
        guard regionPoints.count >= 2 else { return nil }
        let local = bounds(of: regionPoints)
        return CGRect(
            x: box.minX + local.minX * box.width,
            y: box.minY + local.minY * box.height,
            width: local.width * box.width,
            height: local.height * box.height
        )
    }

    private static func padded(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: -rect.width * regionPadding, dy: -rect.height * regionPadding)
    }

    /// Pupil offset from the eye's horizontal center, in eye widths (signed).
    private static func gazeOffset(pupil: [CGPoint], eye: [CGPoint]) -> Double? {
        guard !pupil.isEmpty, eye.count >= 2 else { return nil }
        let eyeBox = bounds(of: eye)
        guard eyeBox.width > 1e-6 else { return nil }
        let pupilX = pupil.reduce(0.0) { $0 + Double($1.x) } / Double(pupil.count)
        return (pupilX - Double(eyeBox.midX)) / Double(eyeBox.width)
    }

    private static func meanY(_ points: [CGPoint]) -> Double? {
        guard !points.isEmpty else { return nil }
        return points.reduce(0.0) { $0 + Double($1.y) } / Double(points.count)
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

// MARK: - Pixels

/// Reads 8-bit, four-channel pixels (rows top-down, as they lie in memory) at face-box-normalized points of a
/// Vision-normalized face `box`: x = (box.minX + p.x · box.width) · width, y = (box.minY + p.y · box.height) · height,
/// row = height − 1 − y. Colors are BT.601: luma = 0.299 R + 0.587 G + 0.114 B, Cr = 128 + 0.5 R − 0.4187 G − 0.0813 B.
struct PixelSampler {
    /// Byte offsets of red, green and blue in a pixel.
    struct Channels: Sendable {
        let red: Int
        let green: Int
        let blue: Int
    }

    /// A camera frame's 32BGRA.
    static let bgra = Channels(red: 2, green: 1, blue: 0)
    /// `RGBAPixels`.
    static let rgba = Channels(red: 0, green: 1, blue: 2)

    let bytes: UnsafeRawBufferPointer
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let channels: Channels
    let box: CGRect

    /// The color at `point`; nil outside the picture.
    func sample(at point: CGPoint) -> FaceShapeMeasure.Sample? {
        let x = (Double(box.minX) + Double(point.x) * Double(box.width)) * Double(width)
        let y = (Double(box.minY) + Double(point.y) * Double(box.height)) * Double(height)
        guard x >= 0, x < Double(width), y >= 0, y < Double(height) else { return nil }
        let row = height - 1 - Int(y)
        let offset = row * bytesPerRow + Int(x) * 4
        guard offset >= 0, offset + 3 < bytes.count else { return nil }
        let red = Double(bytes[offset + channels.red])
        let green = Double(bytes[offset + channels.green])
        let blue = Double(bytes[offset + channels.blue])
        return FaceShapeMeasure.Sample(luma: 0.299 * red + 0.587 * green + 0.114 * blue,
                                       redness: 128 + 0.5 * red - 0.4187 * green - 0.0813 * blue)
    }
}

/// An image drawn once into 8-bit RGBA (sRGB, premultiplied), at most `maximumSide` pixels on its longer side, to read
/// a face's colors from (face boxes are normalized, so the size doesn't move them).
struct RGBAPixels: Sendable {
    static let maximumSide = 512

    let width: Int
    let height: Int
    /// Rows top-down, four bytes a pixel: red, green, blue, alpha.
    let bytes: [UInt8]

    /// nil for an empty image or when it can't be drawn.
    init?(image: CGImage, maximumSide: Int = RGBAPixels.maximumSide) {
        guard image.width > 0, image.height > 0, maximumSide > 0 else { return nil }
        let scale = min(1, Double(maximumSide) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// Calls `body` with the colors at face-box-normalized points of `box` (a Vision-normalized face box); the reader
    /// must not be kept.
    func withColors<T>(box: CGRect, _ body: (FaceFeatureExtractor.ColorReader?) -> T) -> T {
        bytes.withUnsafeBytes { raw in
            let sampler = PixelSampler(bytes: raw, width: width, height: height, bytesPerRow: width * 4,
                                       channels: PixelSampler.rgba, box: box)
            return body({ point in sampler.sample(at: point) })
        }
    }
}
