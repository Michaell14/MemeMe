import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

/// Where the face is in one analyzed camera frame: Vision-normalized coordinates of the unmirrored buffer
/// (0...1, origin bottom-left).
struct FaceGeometry: Equatable, Sendable {
    var firstEye: CGPoint
    var secondEye: CGPoint
    var mouth: CGPoint
    /// Inner-lip height as a fraction of the face box's height.
    var mouthOpen: CGFloat

    /// nil without both eyes.
    static func geometry(from face: VNFaceObservation) -> FaceGeometry? {
        guard let landmarks = face.landmarks else { return nil }
        let box = face.boundingBox
        func toImage(_ point: CGPoint) -> CGPoint {
            CGPoint(x: box.minX + point.x * box.width, y: box.minY + point.y * box.height)
        }
        func center(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let points = region?.normalizedPoints, !points.isEmpty else { return nil }
            let x = points.reduce(0) { $0 + $1.x } / CGFloat(points.count)
            let y = points.reduce(0) { $0 + $1.y } / CGFloat(points.count)
            return toImage(CGPoint(x: x, y: y))
        }
        guard let first = center(landmarks.leftPupil) ?? center(landmarks.leftEye),
              let second = center(landmarks.rightPupil) ?? center(landmarks.rightEye) else { return nil }
        let mouth = center(landmarks.outerLips) ?? CGPoint(x: (first.x + second.x) / 2, y: box.minY + box.height * 0.25)
        var open: CGFloat = 0
        if let inner = landmarks.innerLips?.normalizedPoints, inner.count >= 2 {
            let ys = inner.map(\.y)
            open = (ys.max() ?? 0) - (ys.min() ?? 0)
        }
        return FaceGeometry(firstEye: first, secondEye: second, mouth: mouth, mouthOpen: open)
    }
}

/// The face in the capture picture: pixels of the centered square, mirrored (origin bottom-left, as Core Image).
struct FaceAnchors: Equatable, Sendable {
    /// The eye on the left of the picture.
    var leftEye: CGPoint
    var rightEye: CGPoint
    var mouth: CGPoint
    var mouthOpen: CGFloat

    init(leftEye: CGPoint, rightEye: CGPoint, mouth: CGPoint, mouthOpen: CGFloat) {
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.mouth = mouth
        self.mouthOpen = mouthOpen
    }

    /// Maps a face found in a `imageWidth` × `imageHeight` buffer into its centered square, mirrored.
    init(geometry: FaceGeometry, imageWidth: CGFloat, imageHeight: CGFloat) {
        let side = min(imageWidth, imageHeight)
        let offsetX = (imageWidth - side) / 2
        let offsetY = (imageHeight - side) / 2
        func map(_ point: CGPoint) -> CGPoint {
            CGPoint(x: side - (point.x * imageWidth - offsetX), y: point.y * imageHeight - offsetY)
        }
        let first = map(geometry.firstEye)
        let second = map(geometry.secondEye)
        self.init(leftEye: first.x <= second.x ? first : second,
                  rightEye: first.x <= second.x ? second : first,
                  mouth: map(geometry.mouth),
                  mouthOpen: geometry.mouthOpen)
    }

    var eyeDistance: CGFloat {
        hypot(rightEye.x - leftEye.x, rightEye.y - leftEye.y)
    }

    /// The tilt of the eye line, radians.
    var angle: CGFloat {
        atan2(rightEye.y - leftEye.y, rightEye.x - leftEye.x)
    }

    var eyeMidpoint: CGPoint {
        CGPoint(x: (leftEye.x + rightEye.x) / 2, y: (leftEye.y + rightEye.y) / 2)
    }

    /// `distance` along the face's up direction from `point`.
    func above(_ point: CGPoint, by distance: CGFloat) -> CGPoint {
        CGPoint(x: point.x - sin(angle) * distance, y: point.y + cos(angle) * distance)
    }

    /// Moves `amount` (0...1) of the way toward `target`, so overlays glide between the 10-per-second face readings.
    func blended(toward target: FaceAnchors, amount: CGFloat) -> FaceAnchors {
        func mix(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * amount, y: a.y + (b.y - a.y) * amount)
        }
        return FaceAnchors(leftEye: mix(leftEye, target.leftEye),
                           rightEye: mix(rightEye, target.rightEye),
                           mouth: mix(mouth, target.mouth),
                           mouthOpen: mouthOpen + (target.mouthOpen - mouthOpen) * amount)
    }
}

/// A look for the capture view: a color effect or something drawn on the face. Applied to the mirrored square
/// before it is shown or captured, so a capture looks exactly like the picture.
enum CameraFilter: String, CaseIterable, Identifiable, Sendable {
    case none, noir, comic, pixel, deepFried, shades, hearts, bugEyes, crown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .noir: return "Noir"
        case .comic: return "Comic"
        case .pixel: return "8-bit"
        case .deepFried: return "Deep fried"
        case .shades: return "Deal with it"
        case .hearts: return "Heart eyes"
        case .bugEyes: return "Bug eyes"
        case .crown: return "Crown"
        }
    }

    /// Drawn on the face: shows nothing until a face is found.
    var followsFace: Bool {
        switch self {
        case .shades, .hearts, .bugEyes, .crown: return true
        case .none, .noir, .comic, .pixel, .deepFried: return false
        }
    }

    /// The filtered picture, cropped to `image`'s extent. `face` is where the face is in `image`; `time` animates.
    func apply(to image: CIImage, face: FaceAnchors?, time: TimeInterval) -> CIImage {
        let extent = image.extent
        let output: CIImage
        switch self {
        case .none:
            return image
        case .noir:
            let noir = CIFilter.photoEffectNoir()
            noir.inputImage = image
            let vignette = CIFilter.vignette()
            vignette.inputImage = noir.outputImage
            vignette.intensity = 1
            vignette.radius = 2
            output = vignette.outputImage ?? image
        case .comic:
            let comic = CIFilter.comicEffect()
            comic.inputImage = image.clampedToExtent()
            output = comic.outputImage ?? image
        case .pixel:
            let pixellate = CIFilter.pixellate()
            pixellate.inputImage = image.clampedToExtent()
            pixellate.center = CGPoint(x: extent.midX, y: extent.midY)
            pixellate.scale = Float(max(4, extent.width / 40))
            let posterize = CIFilter.colorPosterize()
            posterize.inputImage = pixellate.outputImage
            posterize.levels = 6
            output = posterize.outputImage ?? image
        case .deepFried:
            let colors = CIFilter.colorControls()
            colors.inputImage = image
            colors.saturation = 2.6
            colors.contrast = 1.5
            colors.brightness = 0.04
            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = colors.outputImage
            sharpen.sharpness = 2
            let unsharp = CIFilter.unsharpMask()
            unsharp.inputImage = sharpen.outputImage?.clampedToExtent()
            unsharp.radius = 2.5
            unsharp.intensity = 1.5
            output = unsharp.outputImage ?? image
        case .bugEyes:
            guard let face, face.eyeDistance > 1 else { return image }
            var bulged = image.clampedToExtent()
            let distance = face.eyeDistance
            var bulges: [(center: CGPoint, radius: CGFloat, scale: Float)] = [
                (face.leftEye, distance * 0.75, 0.55),
                (face.rightEye, distance * 0.75, 0.55),
            ]
            if face.mouthOpen > 0.12 {
                bulges.append((face.mouth, distance * 0.9, 0.4))
            }
            for bulge in bulges {
                let bump = CIFilter.bumpDistortion()
                bump.inputImage = bulged
                bump.center = bulge.center
                bump.radius = Float(bulge.radius)
                bump.scale = bulge.scale
                bulged = bump.outputImage ?? bulged
            }
            output = bulged
        case .shades:
            guard let face, face.eyeDistance > 1 else { return image }
            let center = face.above(face.eyeMidpoint, by: face.eyeDistance * 0.05)
            output = CameraFilter.place(FilterSprites.shared.shades, center: center, width: face.eyeDistance * 2.4,
                                        angle: face.angle, over: image, sharp: true)
        case .hearts:
            guard let face, face.eyeDistance > 1 else { return image }
            let pulse = 1 + 0.08 * CGFloat(sin(time * 2 * Double.pi * 2))
            let width = face.eyeDistance * 0.9 * pulse
            var hearts = image
            for eye in [face.leftEye, face.rightEye] {
                hearts = CameraFilter.place(FilterSprites.shared.heart, center: eye, width: width, angle: face.angle, over: hearts)
            }
            output = hearts
        case .crown:
            guard let face, face.eyeDistance > 1 else { return image }
            let center = face.above(face.eyeMidpoint, by: face.eyeDistance * 1.75)
            output = CameraFilter.place(FilterSprites.shared.crown, center: center, width: face.eyeDistance * 2.3,
                                        angle: face.angle, over: image)
        }
        return output.cropped(to: extent)
    }

    /// `sprite` scaled to `width`, turned by `angle` and centered on `center`, over `base`.
    private static func place(_ sprite: CIImage, center: CGPoint, width: CGFloat, angle: CGFloat, over base: CIImage, sharp: Bool = false) -> CIImage {
        let size = sprite.extent.size
        guard size.width > 0, width > 0 else { return base }
        let scale = width / size.width
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: angle)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
        let source = sharp ? sprite.samplingNearest() : sprite
        return source.transformed(by: transform).composited(over: base)
    }
}

/// The drawings the face filters place, made once with Core Graphics (no bundled art).
final class FilterSprites: @unchecked Sendable {
    static let shared = FilterSprites()

    let shades: CIImage
    let heart: CIImage
    let crown: CIImage

    private init() {
        shades = FilterSprites.makeShades()
        heart = FilterSprites.makeHeart()
        crown = FilterSprites.makeCrown()
    }

    private static func image(width: Int, height: Int, draw: (CGContext) -> Void) -> CIImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return CIImage.empty()
        }
        draw(context)
        guard let made = context.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: made)
    }

    /// Pixel-art sunglasses ("deal with it"): one 10 px square per pixel, top row first.
    private static func makeShades() -> CIImage {
        let rows = [
            "XXXXXXXXXXXXXXXXXXXXXXXX",
            ".XXXXXXXXXX..XXXXXXXXXX.",
            ".XWWXXXXXXX..XWWXXXXXXX.",
            ".XXWWXXXXXX..XXWWXXXXXX.",
            "..XXXXXXXX....XXXXXXXX..",
            "...XXXXXX......XXXXXX...",
        ]
        let cell = 10
        let width = rows[0].count * cell
        let height = rows.count * cell
        return image(width: width, height: height) { context in
            for (rowIndex, row) in rows.enumerated() {
                for (columnIndex, character) in row.enumerated() {
                    switch character {
                    case "X": context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                    case "W": context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                    default: continue
                    }
                    // Core Graphics counts rows from the bottom.
                    let y = height - (rowIndex + 1) * cell
                    context.fill(CGRect(x: columnIndex * cell, y: y, width: cell, height: cell))
                }
            }
        }
    }

    private static func makeHeart() -> CIImage {
        image(width: 128, height: 120) { context in
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 64, y: 8))
            path.addCurve(to: CGPoint(x: 6, y: 78), control1: CGPoint(x: 40, y: 32), control2: CGPoint(x: 6, y: 52))
            path.addCurve(to: CGPoint(x: 64, y: 92), control1: CGPoint(x: 6, y: 114), control2: CGPoint(x: 52, y: 120))
            path.addCurve(to: CGPoint(x: 122, y: 78), control1: CGPoint(x: 76, y: 120), control2: CGPoint(x: 122, y: 114))
            path.addCurve(to: CGPoint(x: 64, y: 8), control1: CGPoint(x: 122, y: 52), control2: CGPoint(x: 88, y: 32))
            path.closeSubpath()
            context.addPath(path)
            context.setFillColor(CGColor(red: 1, green: 0.23, blue: 0.36, alpha: 1))
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(CGColor(red: 0.62, green: 0.05, blue: 0.16, alpha: 1))
            context.setLineWidth(5)
            context.strokePath()
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
            context.fillEllipse(in: CGRect(x: 26, y: 70, width: 18, height: 14))
        }
    }

    private static func makeCrown() -> CIImage {
        image(width: 256, height: 170) { context in
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 20, y: 20))
            path.addLine(to: CGPoint(x: 236, y: 20))
            path.addLine(to: CGPoint(x: 250, y: 150))
            path.addLine(to: CGPoint(x: 186, y: 80))
            path.addLine(to: CGPoint(x: 128, y: 162))
            path.addLine(to: CGPoint(x: 70, y: 80))
            path.addLine(to: CGPoint(x: 6, y: 150))
            path.closeSubpath()
            context.addPath(path)
            context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.16, alpha: 1))
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(CGColor(red: 0.72, green: 0.48, blue: 0.02, alpha: 1))
            context.setLineWidth(6)
            context.strokePath()
            let jewels: [(CGFloat, CGColor)] = [
                (64, CGColor(red: 0.2, green: 0.55, blue: 1, alpha: 1)),
                (128, CGColor(red: 1, green: 0.2, blue: 0.3, alpha: 1)),
                (192, CGColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1)),
            ]
            for (x, color) in jewels {
                context.setFillColor(color)
                context.fillEllipse(in: CGRect(x: x - 13, y: 34, width: 26, height: 26))
            }
        }
    }
}
