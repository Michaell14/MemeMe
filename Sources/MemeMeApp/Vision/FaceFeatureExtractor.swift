import CoreGraphics
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

    /// nil when the observation has no landmarks.
    static func features(from face: VNFaceObservation) -> FaceFeatures? {
        guard let landmarks = face.landmarks else { return nil }
        let neutral = FaceFeatures.populationNeutral

        let leftEye = points(of: landmarks.leftEye)
        let rightEye = points(of: landmarks.rightEye)
        let leftBrow = points(of: landmarks.leftEyebrow)
        let rightBrow = points(of: landmarks.rightEyebrow)
        let outerLips = points(of: landmarks.outerLips)
        let innerLips = points(of: landmarks.innerLips)

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
        let roll = face.roll?.doubleValue ?? 0
        let headTilt = clamp(abs(roll) / (Double.pi / 4))

        // Gaze: signed pupil offset from each eye's center, averaged over both eyes.
        var gazeOffsets: [Double] = []
        if let offset = gazeOffset(pupil: points(of: landmarks.leftPupil), eye: leftEye) {
            gazeOffsets.append(offset)
        }
        if let offset = gazeOffset(pupil: points(of: landmarks.rightPupil), eye: rightEye) {
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

    /// The body pose of the person whose face is `faceBox` (Vision-normalized), with the strongest sign of their
    /// hands; nil when no body was found.
    static func pose(bodies: [VNHumanBodyPoseObservation], hands: [VNHumanHandPoseObservation] = [],
                     faceBox: CGRect?, imageWidth: Int, imageHeight: Int) -> PoseFeatures? {
        guard let body = primaryBody(bodies, faceBox: faceBox, imageWidth: imageWidth, imageHeight: imageHeight) else {
            return nil
        }
        let box = poseBox(faceBox, imageWidth: imageWidth, imageHeight: imageHeight)
        let shapes = body.ownHands(handJoints(hands, imageWidth: imageWidth, imageHeight: imageHeight)).compactMap { HandShape($0, faceBox: box) }
        return PoseFeatures(joints: body, hand: HandShape.strongest(shapes))
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
