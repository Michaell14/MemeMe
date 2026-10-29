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
    /// How far apart the inner lips are, across the mouth (`lipGap`), as a fraction of the face box.
    var mouthOpen: CGFloat
    /// The middle of the nose landmarks (else of the nose crest); nil when Vision gave neither.
    var nose: CGPoint? = nil

    /// nil without both eyes.
    static func geometry(from face: VNFaceObservation) -> FaceGeometry? {
        guard let landmarks = face.landmarks else { return nil }
        let box = face.boundingBox
        func toImage(_ point: CGPoint) -> CGPoint {
            CGPoint(x: box.minX + point.x * box.width, y: box.minY + point.y * box.height)
        }
        // In the face box (0...1 across it).
        func boxCenter(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let points = region?.normalizedPoints, !points.isEmpty else { return nil }
            let x = points.reduce(0) { $0 + $1.x } / CGFloat(points.count)
            let y = points.reduce(0) { $0 + $1.y } / CGFloat(points.count)
            return CGPoint(x: x, y: y)
        }
        func center(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            boxCenter(region).map(toImage)
        }
        guard let firstInBox = boxCenter(landmarks.leftPupil) ?? boxCenter(landmarks.leftEye),
              let secondInBox = boxCenter(landmarks.rightPupil) ?? boxCenter(landmarks.rightEye) else { return nil }
        let first = toImage(firstInBox)
        let second = toImage(secondInBox)
        let mouth = center(landmarks.outerLips) ?? CGPoint(x: (first.x + second.x) / 2, y: box.minY + box.height * 0.25)
        var open: CGFloat = 0
        if let inner = landmarks.innerLips?.normalizedPoints, inner.count >= 2 {
            open = lipGap(inner, firstEye: firstInBox, secondEye: secondInBox)
        }
        let nose = center(landmarks.nose) ?? center(landmarks.noseCrest)
        return FaceGeometry(firstEye: first, secondEye: second, mouth: mouth, mouthOpen: open, nose: nose)
    }

    /// How far apart the inner-lip `points` reach across the mouth: their spread along the face's up direction (square
    /// to the line through the eyes), so a tilted head doesn't open a closed mouth. Everything in the face box.
    static func lipGap(_ points: [CGPoint], firstEye: CGPoint, secondEye: CGPoint) -> CGFloat {
        guard points.count >= 2 else { return 0 }
        let angle = atan2(secondEye.y - firstEye.y, secondEye.x - firstEye.x)
        let across = points.map { -$0.x * sin(angle) + $0.y * cos(angle) }
        return (across.max() ?? 0) - (across.min() ?? 0)
    }
}

/// The face in the capture picture: pixels of the centered square, mirrored (origin bottom-left, as Core Image).
struct FaceAnchors: Equatable, Sendable {
    /// The eye on the left of the picture.
    var leftEye: CGPoint
    var rightEye: CGPoint
    var mouth: CGPoint
    var mouthOpen: CGFloat
    var nose: CGPoint

    /// Without a `nose`, it is estimated from the eyes and the mouth.
    init(leftEye: CGPoint, rightEye: CGPoint, mouth: CGPoint, mouthOpen: CGFloat, nose: CGPoint? = nil) {
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.mouth = mouth
        self.mouthOpen = mouthOpen
        self.nose = nose ?? FaceAnchors.estimatedNose(leftEye: leftEye, rightEye: rightEye, mouth: mouth)
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
                  mouthOpen: geometry.mouthOpen,
                  nose: geometry.nose.map { map($0) })
    }

    /// Where the nose is when Vision didn't say: 55 % of the way from between the eyes to the mouth.
    static func estimatedNose(leftEye: CGPoint, rightEye: CGPoint, mouth: CGPoint) -> CGPoint {
        let middle = CGPoint(x: (leftEye.x + rightEye.x) / 2, y: (leftEye.y + rightEye.y) / 2)
        return CGPoint(x: middle.x + (mouth.x - middle.x) * 0.55, y: middle.y + (mouth.y - middle.y) * 0.55)
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

    /// How open the mouth is for the filters that react to it: 0 up to a gap of 0.06 (closed, or talking), 1 from 0.18.
    var mouthOpenness: CGFloat {
        min(1, max(0, (mouthOpen - 0.06) / 0.12))
    }

    /// `distance` along the face's up direction from `point`.
    func above(_ point: CGPoint, by distance: CGFloat) -> CGPoint {
        CGPoint(x: point.x - sin(angle) * distance, y: point.y + cos(angle) * distance)
    }

    /// `right` along the eye line (toward the right eye) and `up` along the face's up direction from `point`.
    func offset(_ point: CGPoint, right: CGFloat, up: CGFloat) -> CGPoint {
        CGPoint(x: point.x + cos(angle) * right - sin(angle) * up, y: point.y + sin(angle) * right + cos(angle) * up)
    }

    /// Moves `amount` (0...1) of the way toward `target`, so overlays glide between the 10-per-second face readings.
    func blended(toward target: FaceAnchors, amount: CGFloat) -> FaceAnchors {
        func mix(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * amount, y: a.y + (b.y - a.y) * amount)
        }
        return FaceAnchors(leftEye: mix(leftEye, target.leftEye),
                           rightEye: mix(rightEye, target.rightEye),
                           mouth: mix(mouth, target.mouth),
                           mouthOpen: mouthOpen + (target.mouthOpen - mouthOpen) * amount,
                           nose: mix(nose, target.nose))
    }
}

/// A look for the capture view: a color effect or something drawn on the face. Applied to the mirrored square
/// before it is shown or captured, so a capture looks exactly like the picture.
enum CameraFilter: String, CaseIterable, Identifiable, Sendable {
    // The looks, then the face filters, most popular first (the order of the chips and of ← →).
    case none, noir, comic, pixel, deepFried
    case dog, cat, bunny, rainbow, flowerCrown, hearts, shades, devil, angel, crown, bugEyes, clown, mustache, pig

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .noir: return "Noir"
        case .comic: return "Comic"
        case .pixel: return "8-bit"
        case .deepFried: return "Deep fried"
        case .dog: return "Dog"
        case .cat: return "Cat"
        case .bunny: return "Bunny"
        case .rainbow: return "Rainbow"
        case .flowerCrown: return "Flowers"
        case .hearts: return "Heart eyes"
        case .shades: return "Deal with it"
        case .devil: return "Devil"
        case .angel: return "Angel"
        case .crown: return "Crown"
        case .bugEyes: return "Bug eyes"
        case .clown: return "Clown"
        case .mustache: return "Mustache"
        case .pig: return "Pig"
        }
    }

    /// Drawn on the face: shows nothing until a face is found.
    var followsFace: Bool {
        switch self {
        case .dog, .cat, .bunny, .rainbow, .flowerCrown, .hearts, .shades, .devil, .angel, .crown, .bugEyes, .clown,
             .mustache, .pig:
            return true
        case .none, .noir, .comic, .pixel, .deepFried:
            return false
        }
    }

    /// The filtered picture, cropped to `image`'s extent. `face` is where the face is in `image`; `time` animates.
    /// Sizes and places on the face are in eye distances (d), along the eye line and the face's up direction: the top of
    /// the head is about 1.75 d above the eyes, the face about 2.4 d wide.
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
        case .dog:
            // Floppy ears hanging from the top of the head, a shiny nose, and the tongue out while the mouth is open.
            guard let face, face.eyeDistance > 1 else { return image }
            let distance = face.eyeDistance
            let sprites = FilterSprites.shared
            var dog = image
            for mirrored in [false, true] {
                let side: CGFloat = mirrored ? 1 : -1
                dog = CameraFilter.place(sprites.dogEar, at: face.offset(face.eyeMidpoint, right: side * distance * 0.68, up: distance * 1.55),
                                         anchor: CGPoint(x: 0.75, y: 0.93), width: distance * 1.15, angle: face.angle,
                                         mirrored: mirrored, over: dog)
            }
            if face.mouthOpenness > 0 {
                dog = CameraFilter.place(sprites.tongue, at: face.above(face.mouth, by: distance * 0.06), anchor: CGPoint(x: 0.5, y: 0.94),
                                         width: distance * 0.7, angle: face.angle, stretch: 0.4 + 0.6 * face.mouthOpenness, over: dog)
            }
            output = CameraFilter.place(sprites.dogNose, at: face.above(face.nose, by: distance * 0.06), width: distance * 0.82,
                                        angle: face.angle, over: dog)
        case .cat:
            guard let face, face.eyeDistance > 1 else { return image }
            let distance = face.eyeDistance
            let sprites = FilterSprites.shared
            var cat = image
            for mirrored in [false, true] {
                let side: CGFloat = mirrored ? 1 : -1
                cat = CameraFilter.place(sprites.catEar, at: face.offset(face.eyeMidpoint, right: side * distance * 0.72, up: distance * 1.45),
                                         anchor: CGPoint(x: 0.53, y: 0.1), width: distance * 0.95, angle: face.angle,
                                         mirrored: mirrored, over: cat)
                cat = CameraFilter.place(sprites.whiskers, at: face.offset(face.nose, right: side * distance * 0.3, up: -distance * 0.12),
                                         anchor: CGPoint(x: 0.96, y: 0.51), width: distance * 1.05, angle: face.angle,
                                         mirrored: mirrored, over: cat)
            }
            output = CameraFilter.place(sprites.pinkNose, at: face.above(face.nose, by: distance * 0.04), width: distance * 0.42,
                                        angle: face.angle, over: cat)
        case .bunny:
            guard let face, face.eyeDistance > 1 else { return image }
            let distance = face.eyeDistance
            let sprites = FilterSprites.shared
            var bunny = image
            for side in [-1, 1] as [CGFloat] {
                // Upright ears, each leaning out a little.
                bunny = CameraFilter.place(sprites.bunnyEar, at: face.offset(face.eyeMidpoint, right: side * distance * 0.4, up: distance * 1.5),
                                           anchor: CGPoint(x: 0.5, y: 0.04), width: distance * 0.7, angle: face.angle - side * 0.22,
                                           over: bunny)
            }
            bunny = CameraFilter.place(sprites.buckTeeth, at: CameraFilter.between(face.nose, face.mouth, fraction: 0.62),
                                       anchor: CGPoint(x: 0.5, y: 0.93), width: distance * 0.36, angle: face.angle, over: bunny)
            output = CameraFilter.place(sprites.pinkNose, at: face.above(face.nose, by: distance * 0.04), width: distance * 0.4,
                                        angle: face.angle, over: bunny)
        case .rainbow:
            // A rainbow pouring from the open mouth, longer the wider it opens, swaying a little.
            guard let face, face.eyeDistance > 1, face.mouthOpenness > 0 else { return image }
            let distance = face.eyeDistance
            let sway = 0.05 * CGFloat(sin(time * 2 * Double.pi * 1.1))
            let stretch = (0.45 + 0.55 * face.mouthOpenness) * (1 + 0.06 * CGFloat(sin(time * 2 * Double.pi * 2.5)))
            output = CameraFilter.place(FilterSprites.shared.rainbow, at: face.above(face.mouth, by: distance * 0.05),
                                        anchor: CGPoint(x: 0.5, y: 0.96), width: distance * 1.8, angle: face.angle + sway,
                                        stretch: stretch, over: image)
        case .flowerCrown:
            guard let face, face.eyeDistance > 1 else { return image }
            output = CameraFilter.place(FilterSprites.shared.flowerCrown, at: face.above(face.eyeMidpoint, by: face.eyeDistance * 1.13),
                                        width: face.eyeDistance * 2.8, angle: face.angle, over: image)
        case .hearts:
            guard let face, face.eyeDistance > 1 else { return image }
            let pulse = 1 + 0.08 * CGFloat(sin(time * 2 * Double.pi * 2))
            let width = face.eyeDistance * 0.9 * pulse
            var hearts = image
            for eye in [face.leftEye, face.rightEye] {
                hearts = CameraFilter.place(FilterSprites.shared.heart, at: eye, width: width, angle: face.angle, over: hearts)
            }
            output = hearts
        case .shades:
            guard let face, face.eyeDistance > 1 else { return image }
            let center = face.above(face.eyeMidpoint, by: face.eyeDistance * 0.05)
            output = CameraFilter.place(FilterSprites.shared.shades, at: center, width: face.eyeDistance * 2.4,
                                        angle: face.angle, over: image, sharp: true)
        case .devil:
            guard let face, face.eyeDistance > 1 else { return image }
            let distance = face.eyeDistance
            var devil = image
            for mirrored in [false, true] {
                let side: CGFloat = mirrored ? 1 : -1
                devil = CameraFilter.place(FilterSprites.shared.horn, at: face.offset(face.eyeMidpoint, right: side * distance * 0.55, up: distance * 1.45),
                                           anchor: CGPoint(x: 0.62, y: 0.06), width: distance * 0.72, angle: face.angle,
                                           mirrored: mirrored, over: devil)
            }
            output = devil
        case .angel:
            guard let face, face.eyeDistance > 1 else { return image }
            let bob = face.eyeDistance * 0.07 * CGFloat(sin(time * 2 * Double.pi * 0.8))
            output = CameraFilter.place(FilterSprites.shared.halo, at: face.above(face.eyeMidpoint, by: face.eyeDistance * 2 + bob),
                                        width: face.eyeDistance * 1.9, angle: face.angle, over: image)
        case .crown:
            guard let face, face.eyeDistance > 1 else { return image }
            let center = face.above(face.eyeMidpoint, by: face.eyeDistance * 1.75)
            output = CameraFilter.place(FilterSprites.shared.crown, at: center, width: face.eyeDistance * 2.3,
                                        angle: face.angle, over: image)
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
        case .clown:
            guard let face, face.eyeDistance > 1 else { return image }
            let distance = face.eyeDistance
            let sprites = FilterSprites.shared
            var clown = image
            for side in [-1, 1] as [CGFloat] {
                clown = CameraFilter.place(sprites.blush, at: face.offset(face.eyeMidpoint, right: side * distance * 0.78, up: -distance * 0.62),
                                           width: distance * 0.75, angle: face.angle, over: clown)
            }
            output = CameraFilter.place(sprites.clownNose, at: face.above(face.nose, by: distance * 0.02), width: distance * 0.72,
                                        angle: face.angle, over: clown)
        case .mustache:
            guard let face, face.eyeDistance > 1 else { return image }
            output = CameraFilter.place(FilterSprites.shared.mustache, at: CameraFilter.between(face.nose, face.mouth, fraction: 0.42),
                                        anchor: CGPoint(x: 0.5, y: 0.7), width: face.eyeDistance * 1.35, angle: face.angle, over: image)
        case .pig:
            guard let face, face.eyeDistance > 1 else { return image }
            let distance = face.eyeDistance
            let sprites = FilterSprites.shared
            var pig = image
            for mirrored in [false, true] {
                let side: CGFloat = mirrored ? 1 : -1
                pig = CameraFilter.place(sprites.pigEar, at: face.offset(face.eyeMidpoint, right: side * distance * 0.72, up: distance * 1.45),
                                         anchor: CGPoint(x: 0.53, y: 0.1), width: distance * 0.8, angle: face.angle,
                                         mirrored: mirrored, over: pig)
            }
            output = CameraFilter.place(sprites.pigNose, at: face.nose, width: distance * 0.62, angle: face.angle, over: pig)
        }
        return output.cropped(to: extent)
    }

    /// `sprite` scaled to `width` (flipped left to right when `mirrored`, its height times `stretch`), turned by `angle`
    /// and put with its `anchor` (a fraction of its width and height from its bottom-left corner; the middle by default)
    /// on `point`, over `base`. One sprite drawn for the left of the face serves the right one mirrored.
    private static func place(_ sprite: CIImage, at point: CGPoint, anchor: CGPoint = CGPoint(x: 0.5, y: 0.5), width: CGFloat,
                              angle: CGFloat, mirrored: Bool = false, stretch: CGFloat = 1, over base: CIImage,
                              sharp: Bool = false) -> CIImage {
        let size = sprite.extent.size
        guard size.width > 0, size.height > 0, width > 0, stretch > 0 else { return base }
        let scale = width / size.width
        let transform = CGAffineTransform(translationX: point.x, y: point.y)
            .rotated(by: angle)
            .scaledBy(x: mirrored ? -scale : scale, y: scale * stretch)
            .translatedBy(x: -size.width * anchor.x, y: -size.height * anchor.y)
        let source = sharp ? sprite.samplingNearest() : sprite
        return source.transformed(by: transform).composited(over: base)
    }

    /// The point `fraction` of the way from `start` to `end`.
    private static func between(_ start: CGPoint, _ end: CGPoint, fraction: CGFloat) -> CGPoint {
        CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
    }
}

/// The drawings the face filters place, made once with Core Graphics (no bundled art). Coordinates are Core Graphics'
/// (origin bottom-left); a drawing for one side of the face is the one for the left of the picture.
final class FilterSprites: @unchecked Sendable {
    static let shared = FilterSprites()

    let shades: CIImage
    let heart: CIImage
    let crown: CIImage
    let dogEar: CIImage
    let dogNose: CIImage
    let tongue: CIImage
    let catEar: CIImage
    let pinkNose: CIImage
    let whiskers: CIImage
    let bunnyEar: CIImage
    let buckTeeth: CIImage
    let flowerCrown: CIImage
    let horn: CIImage
    let halo: CIImage
    let clownNose: CIImage
    let blush: CIImage
    let mustache: CIImage
    let rainbow: CIImage
    let pigNose: CIImage
    let pigEar: CIImage

    private init() {
        shades = FilterSprites.makeShades()
        heart = FilterSprites.makeHeart()
        crown = FilterSprites.makeCrown()
        dogEar = FilterSprites.makeDogEar()
        dogNose = FilterSprites.makeDogNose()
        tongue = FilterSprites.makeTongue()
        catEar = FilterSprites.makeCatEar()
        pinkNose = FilterSprites.makePinkNose()
        whiskers = FilterSprites.makeWhiskers()
        bunnyEar = FilterSprites.makeBunnyEar()
        buckTeeth = FilterSprites.makeBuckTeeth()
        flowerCrown = FilterSprites.makeFlowerCrown()
        horn = FilterSprites.makeHorn()
        halo = FilterSprites.makeHalo()
        clownNose = FilterSprites.makeClownNose()
        blush = FilterSprites.makeBlush()
        mustache = FilterSprites.makeMustache()
        rainbow = FilterSprites.makeRainbow()
        pigNose = FilterSprites.makePigNose()
        pigEar = FilterSprites.makePigEar()
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

    // MARK: Drawing helpers

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    private static func ellipse(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: x, y: y, width: width, height: height), transform: nil)
    }

    private static func fill(_ path: CGPath, _ color: CGColor, in context: CGContext) {
        context.addPath(path)
        context.setFillColor(color)
        context.fillPath()
    }

    /// Round joins; round ends when `roundEnds`.
    private static func stroke(_ path: CGPath, _ color: CGColor, width: CGFloat, roundEnds: Bool = false, in context: CGContext) {
        context.addPath(path)
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.setLineJoin(.round)
        context.setLineCap(roundEnds ? .round : .butt)
        context.strokePath()
    }

    private static func makeGradient(_ colors: [CGColor]) -> CGGradient? {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)
    }

    /// Fills `path` with `colors` spread evenly from `start` to `end` (the end colors carry on past them).
    private static func fillGradient(_ path: CGPath, from start: CGPoint, to end: CGPoint, colors: [CGColor], in context: CGContext) {
        guard let gradient = makeGradient(colors) else { return }
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    /// `colors` spread evenly from `center` out to `radius`: within `path` (the last color carrying on past `radius`),
    /// or, without one, a soft disc.
    private static func fillRadialGradient(_ path: CGPath?, center: CGPoint, radius: CGFloat, colors: [CGColor], in context: CGContext) {
        guard let gradient = makeGradient(colors) else { return }
        let options: CGGradientDrawingOptions = path == nil ? [] : [.drawsAfterEndLocation]
        context.saveGState()
        if let path {
            context.addPath(path)
            context.clip()
        }
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                                   options: options)
        context.restoreGState()
    }

    // MARK: Glasses, hearts, crown

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

    // MARK: Dog

    /// A floppy ear for the left of the head, hanging from its top right corner.
    private static func makeDogEar() -> CIImage {
        image(width: 150, height: 200) { context in
            let ear = CGMutablePath()
            ear.move(to: CGPoint(x: 84, y: 194))
            ear.addCurve(to: CGPoint(x: 16, y: 50), control1: CGPoint(x: 38, y: 196), control2: CGPoint(x: 4, y: 120))
            ear.addCurve(to: CGPoint(x: 76, y: 14), control1: CGPoint(x: 24, y: 6), control2: CGPoint(x: 60, y: 0))
            ear.addCurve(to: CGPoint(x: 144, y: 166), control1: CGPoint(x: 100, y: 60), control2: CGPoint(x: 116, y: 124))
            ear.addCurve(to: CGPoint(x: 84, y: 194), control1: CGPoint(x: 134, y: 192), control2: CGPoint(x: 110, y: 200))
            ear.closeSubpath()
            fill(ear, rgb(0.58, 0.37, 0.2), in: context)
            let inner = CGMutablePath()
            inner.move(to: CGPoint(x: 86, y: 168))
            inner.addCurve(to: CGPoint(x: 36, y: 58), control1: CGPoint(x: 56, y: 166), control2: CGPoint(x: 28, y: 114))
            inner.addCurve(to: CGPoint(x: 74, y: 34), control1: CGPoint(x: 42, y: 32), control2: CGPoint(x: 62, y: 24))
            inner.addCurve(to: CGPoint(x: 124, y: 152), control1: CGPoint(x: 94, y: 74), control2: CGPoint(x: 110, y: 120))
            inner.addCurve(to: CGPoint(x: 86, y: 168), control1: CGPoint(x: 116, y: 168), control2: CGPoint(x: 100, y: 174))
            inner.closeSubpath()
            fill(inner, rgb(0.4, 0.23, 0.11), in: context)
            stroke(ear, rgb(0.27, 0.15, 0.07), width: 5, in: context)
        }
    }

    /// Black and shiny.
    private static func makeDogNose() -> CIImage {
        image(width: 160, height: 120) { context in
            let nose = CGMutablePath()
            nose.move(to: CGPoint(x: 80, y: 10))
            nose.addCurve(to: CGPoint(x: 8, y: 76), control1: CGPoint(x: 40, y: 12), control2: CGPoint(x: 8, y: 42))
            nose.addCurve(to: CGPoint(x: 80, y: 114), control1: CGPoint(x: 8, y: 106), control2: CGPoint(x: 40, y: 114))
            nose.addCurve(to: CGPoint(x: 152, y: 76), control1: CGPoint(x: 120, y: 114), control2: CGPoint(x: 152, y: 106))
            nose.addCurve(to: CGPoint(x: 80, y: 10), control1: CGPoint(x: 152, y: 42), control2: CGPoint(x: 120, y: 12))
            nose.closeSubpath()
            fill(nose, rgb(0.13, 0.09, 0.08), in: context)
            fill(ellipse(36, 34, 30, 20), rgb(0, 0, 0), in: context)
            fill(ellipse(94, 34, 30, 20), rgb(0, 0, 0), in: context)
            fill(ellipse(34, 76, 40, 20), rgb(1, 1, 1, 0.75), in: context)
            fill(ellipse(96, 90, 16, 9), rgb(1, 1, 1, 0.55), in: context)
        }
    }

    /// Hangs from its top edge (inside the mouth).
    private static func makeTongue() -> CIImage {
        image(width: 100, height: 170) { context in
            let tongue = CGMutablePath()
            tongue.move(to: CGPoint(x: 12, y: 168))
            tongue.addLine(to: CGPoint(x: 88, y: 168))
            tongue.addCurve(to: CGPoint(x: 92, y: 44), control1: CGPoint(x: 92, y: 120), control2: CGPoint(x: 96, y: 74))
            tongue.addCurve(to: CGPoint(x: 50, y: 4), control1: CGPoint(x: 90, y: 16), control2: CGPoint(x: 72, y: 4))
            tongue.addCurve(to: CGPoint(x: 8, y: 44), control1: CGPoint(x: 28, y: 4), control2: CGPoint(x: 10, y: 16))
            tongue.addCurve(to: CGPoint(x: 12, y: 168), control1: CGPoint(x: 4, y: 74), control2: CGPoint(x: 8, y: 120))
            tongue.closeSubpath()
            fill(tongue, rgb(1, 0.45, 0.56), in: context)
            // Darker where it leaves the mouth.
            fillGradient(tongue, from: CGPoint(x: 50, y: 168), to: CGPoint(x: 50, y: 120),
                         colors: [rgb(0.72, 0.16, 0.28, 0.75), rgb(0.72, 0.16, 0.28, 0)], in: context)
            let crease = CGMutablePath()
            crease.move(to: CGPoint(x: 50, y: 150))
            crease.addLine(to: CGPoint(x: 50, y: 62))
            stroke(crease, rgb(0.84, 0.27, 0.38), width: 5, roundEnds: true, in: context)
            stroke(tongue, rgb(0.8, 0.24, 0.36), width: 4, in: context)
        }
    }

    // MARK: Cat, bunny, pig

    /// A pointed ear for the left of the head, the tip leaning out; its base is along the bottom.
    private static func makePointedEar(outer: CGColor, inner innerColor: CGColor, line: CGColor) -> CIImage {
        image(width: 140, height: 160) { context in
            let ear = CGMutablePath()
            ear.move(to: CGPoint(x: 14, y: 16))
            ear.addCurve(to: CGPoint(x: 22, y: 142), control1: CGPoint(x: 8, y: 60), control2: CGPoint(x: 12, y: 116))
            ear.addQuadCurve(to: CGPoint(x: 44, y: 146), control: CGPoint(x: 30, y: 160))
            ear.addCurve(to: CGPoint(x: 132, y: 36), control1: CGPoint(x: 70, y: 122), control2: CGPoint(x: 110, y: 72))
            ear.addCurve(to: CGPoint(x: 14, y: 16), control1: CGPoint(x: 92, y: 8), control2: CGPoint(x: 48, y: 2))
            ear.closeSubpath()
            fill(ear, outer, in: context)
            let inner = CGMutablePath()
            inner.move(to: CGPoint(x: 32, y: 32))
            inner.addCurve(to: CGPoint(x: 34, y: 118), control1: CGPoint(x: 28, y: 70), control2: CGPoint(x: 30, y: 100))
            inner.addQuadCurve(to: CGPoint(x: 48, y: 122), control: CGPoint(x: 40, y: 132))
            inner.addCurve(to: CGPoint(x: 108, y: 42), control1: CGPoint(x: 68, y: 102), control2: CGPoint(x: 94, y: 68))
            inner.addCurve(to: CGPoint(x: 32, y: 32), control1: CGPoint(x: 80, y: 26), control2: CGPoint(x: 54, y: 22))
            inner.closeSubpath()
            fill(inner, innerColor, in: context)
            stroke(ear, line, width: 5, in: context)
        }
    }

    private static func makeCatEar() -> CIImage {
        makePointedEar(outer: rgb(0.38, 0.36, 0.4), inner: rgb(1, 0.66, 0.76), line: rgb(0.18, 0.16, 0.2))
    }

    private static func makePinkNose() -> CIImage {
        image(width: 80, height: 60) { context in
            let nose = CGMutablePath()
            nose.move(to: CGPoint(x: 40, y: 6))
            nose.addCurve(to: CGPoint(x: 8, y: 44), control1: CGPoint(x: 28, y: 10), control2: CGPoint(x: 8, y: 30))
            nose.addCurve(to: CGPoint(x: 72, y: 44), control1: CGPoint(x: 8, y: 58), control2: CGPoint(x: 72, y: 58))
            nose.addCurve(to: CGPoint(x: 40, y: 6), control1: CGPoint(x: 72, y: 30), control2: CGPoint(x: 52, y: 10))
            nose.closeSubpath()
            fill(nose, rgb(1, 0.55, 0.66), in: context)
            stroke(nose, rgb(0.76, 0.3, 0.42), width: 4, in: context)
            fill(ellipse(24, 34, 16, 10), rgb(1, 1, 1, 0.7), in: context)
        }
    }

    /// Three whiskers for the left cheek, fanning out from the right edge (by the nose).
    private static func makeWhiskers() -> CIImage {
        image(width: 200, height: 110) { context in
            let whiskers = CGMutablePath()
            whiskers.move(to: CGPoint(x: 192, y: 70))
            whiskers.addQuadCurve(to: CGPoint(x: 10, y: 100), control: CGPoint(x: 100, y: 92))
            whiskers.move(to: CGPoint(x: 192, y: 56))
            whiskers.addQuadCurve(to: CGPoint(x: 6, y: 58), control: CGPoint(x: 100, y: 62))
            whiskers.move(to: CGPoint(x: 192, y: 42))
            whiskers.addQuadCurve(to: CGPoint(x: 12, y: 14), control: CGPoint(x: 100, y: 34))
            // A light edge keeps them visible on dark skin and hair.
            stroke(whiskers, rgb(1, 1, 1, 0.55), width: 10, roundEnds: true, in: context)
            stroke(whiskers, rgb(0.12, 0.12, 0.14), width: 5, roundEnds: true, in: context)
        }
    }

    /// Upright; leaned out when placed.
    private static func makeBunnyEar() -> CIImage {
        image(width: 90, height: 260) { context in
            let ear = CGMutablePath()
            ear.move(to: CGPoint(x: 45, y: 254))
            ear.addCurve(to: CGPoint(x: 8, y: 150), control1: CGPoint(x: 20, y: 254), control2: CGPoint(x: 8, y: 200))
            ear.addCurve(to: CGPoint(x: 26, y: 6), control1: CGPoint(x: 8, y: 90), control2: CGPoint(x: 18, y: 30))
            ear.addLine(to: CGPoint(x: 64, y: 6))
            ear.addCurve(to: CGPoint(x: 82, y: 150), control1: CGPoint(x: 72, y: 30), control2: CGPoint(x: 82, y: 90))
            ear.addCurve(to: CGPoint(x: 45, y: 254), control1: CGPoint(x: 82, y: 200), control2: CGPoint(x: 70, y: 254))
            ear.closeSubpath()
            fill(ear, rgb(0.97, 0.95, 0.96), in: context)
            let inner = CGMutablePath()
            inner.move(to: CGPoint(x: 45, y: 228))
            inner.addCurve(to: CGPoint(x: 24, y: 150), control1: CGPoint(x: 32, y: 228), control2: CGPoint(x: 24, y: 190))
            inner.addCurve(to: CGPoint(x: 36, y: 30), control1: CGPoint(x: 24, y: 100), control2: CGPoint(x: 30, y: 50))
            inner.addLine(to: CGPoint(x: 54, y: 30))
            inner.addCurve(to: CGPoint(x: 66, y: 150), control1: CGPoint(x: 60, y: 50), control2: CGPoint(x: 66, y: 100))
            inner.addCurve(to: CGPoint(x: 45, y: 228), control1: CGPoint(x: 66, y: 190), control2: CGPoint(x: 58, y: 228))
            inner.closeSubpath()
            fill(inner, rgb(1, 0.68, 0.78), in: context)
            stroke(ear, rgb(0.62, 0.58, 0.62), width: 4, in: context)
        }
    }

    /// Two front teeth, hanging from their top edge.
    private static func makeBuckTeeth() -> CIImage {
        image(width: 80, height: 60) { context in
            for x in [6, 42] as [CGFloat] {
                let tooth = CGMutablePath()
                tooth.move(to: CGPoint(x: x, y: 56))
                tooth.addLine(to: CGPoint(x: x, y: 14))
                tooth.addQuadCurve(to: CGPoint(x: x + 8, y: 4), control: CGPoint(x: x, y: 4))
                tooth.addLine(to: CGPoint(x: x + 24, y: 4))
                tooth.addQuadCurve(to: CGPoint(x: x + 32, y: 14), control: CGPoint(x: x + 32, y: 4))
                tooth.addLine(to: CGPoint(x: x + 32, y: 56))
                tooth.closeSubpath()
                fill(tooth, rgb(1, 1, 0.97), in: context)
                stroke(tooth, rgb(0.55, 0.52, 0.5), width: 3, in: context)
            }
        }
    }

    private static func makePigNose() -> CIImage {
        image(width: 120, height: 90) { context in
            let snout = ellipse(6, 6, 108, 78)
            fill(snout, rgb(1, 0.63, 0.72), in: context)
            stroke(snout, rgb(0.85, 0.4, 0.52), width: 5, in: context)
            fill(ellipse(30, 26, 20, 34), rgb(0.6, 0.2, 0.3), in: context)
            fill(ellipse(70, 26, 20, 34), rgb(0.6, 0.2, 0.3), in: context)
            fill(ellipse(28, 58, 26, 12), rgb(1, 1, 1, 0.5), in: context)
        }
    }

    private static func makePigEar() -> CIImage {
        makePointedEar(outer: rgb(1, 0.63, 0.72), inner: rgb(0.93, 0.44, 0.55), line: rgb(0.8, 0.36, 0.48))
    }

    // MARK: Flowers

    /// Petal colors from the left end of the crown to the right.
    private static let flowerColors: [(CGFloat, CGFloat, CGFloat)] = [
        (1, 0.45, 0.66),
        (0.5, 0.78, 1),
        (1, 0.86, 0.3),
        (0.72, 0.52, 1),
        (1, 1, 1),
        (1, 0.6, 0.32),
        (1, 0.86, 0.3),
        (0.5, 0.78, 1),
        (1, 0.45, 0.66),
    ]

    /// A ring of flowers with leaves between them, seen from the front: an arc bending down to the temples.
    private static func makeFlowerCrown() -> CIImage {
        image(width: 340, height: 190) { context in
            // t = 0 on top, ±spread at the ends.
            func crownPoint(_ t: CGFloat) -> CGPoint {
                CGPoint(x: 170 + 148 * sin(t), y: 26 + 120 * cos(t))
            }
            let count = flowerColors.count
            let spread: CGFloat = 1.35
            for index in 0..<(count - 1) {
                let t = -spread + 2 * spread * (CGFloat(index) + 0.5) / CGFloat(count - 1)
                // Two leaves between each pair of flowers, pointing out of the ring.
                let out = atan2(cos(t) * 148, sin(t) * 120)
                drawLeaf(at: crownPoint(t), angle: out + 0.6, length: 36, in: context)
                drawLeaf(at: crownPoint(t), angle: out - 0.6, length: 36, in: context)
            }
            for (index, petals) in flowerColors.enumerated() {
                let t = -spread + 2 * spread * CGFloat(index) / CGFloat(count - 1)
                drawFlower(at: crownPoint(t), radius: 31 - 8 * abs(t) / spread, color: petals, in: context)
            }
        }
    }

    /// A leaf from `point`, pointing along `angle`.
    private static func drawLeaf(at point: CGPoint, angle: CGFloat, length: CGFloat, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.rotate(by: angle)
        let leaf = CGMutablePath()
        leaf.move(to: CGPoint(x: 0, y: 0))
        leaf.addQuadCurve(to: CGPoint(x: length, y: 0), control: CGPoint(x: length / 2, y: length * 0.45))
        leaf.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: length / 2, y: -length * 0.45))
        leaf.closeSubpath()
        fill(leaf, rgb(0.25, 0.65, 0.3), in: context)
        stroke(leaf, rgb(0.13, 0.42, 0.18), width: 2, in: context)
        context.restoreGState()
    }

    /// Five petals around a yellow middle.
    private static func drawFlower(at point: CGPoint, radius: CGFloat, color: (CGFloat, CGFloat, CGFloat), in context: CGContext) {
        let (red, green, blue) = color
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        for petal in 0..<5 {
            context.saveGState()
            context.rotate(by: CGFloat(petal) * 2 * .pi / 5)
            let shape = ellipse(-radius * 0.38, radius * 0.08, radius * 0.76, radius * 0.92)
            fill(shape, rgb(red, green, blue), in: context)
            stroke(shape, rgb(red * 0.78, green * 0.78, blue * 0.78), width: 2, in: context)
            context.restoreGState()
        }
        fill(ellipse(-radius * 0.3, -radius * 0.3, radius * 0.6, radius * 0.6), rgb(1, 0.74, 0.16), in: context)
        fill(ellipse(-radius * 0.12, radius * 0.02, radius * 0.16, radius * 0.12), rgb(1, 1, 1, 0.7), in: context)
        context.restoreGState()
    }

    // MARK: Devil, angel, clown, mustache

    /// The left horn: a crescent from its base along the bottom, bulging out to the left, the tip pointing up.
    private static func makeHorn() -> CIImage {
        image(width: 130, height: 160) { context in
            let horn = CGMutablePath()
            horn.move(to: CGPoint(x: 48, y: 10))
            horn.addCurve(to: CGPoint(x: 40, y: 154), control1: CGPoint(x: 10, y: 40), control2: CGPoint(x: 10, y: 110))
            horn.addCurve(to: CGPoint(x: 112, y: 14), control1: CGPoint(x: 34, y: 116), control2: CGPoint(x: 50, y: 58))
            horn.addCurve(to: CGPoint(x: 48, y: 10), control1: CGPoint(x: 96, y: 0), control2: CGPoint(x: 64, y: 0))
            horn.closeSubpath()
            fillGradient(horn, from: CGPoint(x: 20, y: 150), to: CGPoint(x: 100, y: 10),
                         colors: [rgb(1, 0.32, 0.24), rgb(0.7, 0.02, 0.06)], in: context)
            let shine = CGMutablePath()
            shine.move(to: CGPoint(x: 40, y: 28))
            shine.addCurve(to: CGPoint(x: 32, y: 126), control1: CGPoint(x: 22, y: 54), control2: CGPoint(x: 20, y: 100))
            stroke(shine, rgb(1, 1, 1, 0.4), width: 5, roundEnds: true, in: context)
            stroke(horn, rgb(0.42, 0.01, 0.04), width: 4, in: context)
        }
    }

    /// A golden ring seen from a little above, glowing.
    private static func makeHalo() -> CIImage {
        image(width: 240, height: 90) { context in
            let ring = ellipse(30, 25, 180, 40)
            context.saveGState()
            context.setShadow(offset: .zero, blur: 14, color: rgb(1, 0.86, 0.35))
            stroke(ring, rgb(1, 0.8, 0.25), width: 10, in: context)
            context.restoreGState()
            let top = CGMutablePath()
            top.move(to: CGPoint(x: 46, y: 52))
            top.addCurve(to: CGPoint(x: 194, y: 52), control1: CGPoint(x: 90, y: 70), control2: CGPoint(x: 150, y: 70))
            stroke(top, rgb(1, 0.97, 0.78), width: 3, roundEnds: true, in: context)
        }
    }

    private static func makeClownNose() -> CIImage {
        image(width: 120, height: 120) { context in
            let ball = ellipse(6, 6, 108, 108)
            fillRadialGradient(ball, center: CGPoint(x: 46, y: 74), radius: 74,
                               colors: [rgb(1, 0.36, 0.3), rgb(0.7, 0.02, 0.06)], in: context)
            fill(ellipse(30, 70, 30, 20), rgb(1, 1, 1, 0.8), in: context)
        }
    }

    /// A rosy cheek, fading out at the edge.
    private static func makeBlush() -> CIImage {
        image(width: 100, height: 100) { context in
            fillRadialGradient(nil, center: CGPoint(x: 50, y: 50), radius: 50,
                               colors: [rgb(1, 0.32, 0.42, 0.6), rgb(1, 0.32, 0.42, 0)], in: context)
        }
    }

    /// A curly handlebar: the left half, then the same mirrored.
    private static func makeMustache() -> CIImage {
        image(width: 240, height: 90) { context in
            for mirrored in [false, true] {
                context.saveGState()
                if mirrored {
                    context.translateBy(x: 240, y: 0)
                    context.scaleBy(x: -1, y: 1)
                }
                let half = CGMutablePath()
                half.move(to: CGPoint(x: 122, y: 62))
                half.addCurve(to: CGPoint(x: 60, y: 58), control1: CGPoint(x: 102, y: 78), control2: CGPoint(x: 80, y: 70))
                half.addCurve(to: CGPoint(x: 20, y: 82), control1: CGPoint(x: 40, y: 48), control2: CGPoint(x: 28, y: 60))
                half.addCurve(to: CGPoint(x: 48, y: 30), control1: CGPoint(x: 8, y: 62), control2: CGPoint(x: 18, y: 28))
                half.addCurve(to: CGPoint(x: 122, y: 40), control1: CGPoint(x: 78, y: 34), control2: CGPoint(x: 104, y: 26))
                half.closeSubpath()
                fill(half, rgb(0.13, 0.09, 0.07), in: context)
                context.restoreGState()
            }
        }
    }

    // MARK: Rainbow

    private static let rainbowColors: [CGColor] = [
        rgb(0.96, 0.2, 0.22),
        rgb(1, 0.55, 0.15),
        rgb(1, 0.88, 0.2),
        rgb(0.3, 0.8, 0.3),
        rgb(0.2, 0.6, 1),
        rgb(0.4, 0.33, 0.9),
        rgb(0.7, 0.36, 0.92),
    ]

    /// The stream: stripes side by side, narrow at the top (the mouth) and widening down, with a gentle S.
    private static func makeRainbow() -> CIImage {
        image(width: 200, height: 300) { context in
            let count = CGFloat(rainbowColors.count)
            // Where the edge left of stripe `index` meets the top and the bottom.
            func edge(_ index: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
                (72 + 56 * index / count, 200 * index / count)
            }
            for (index, stripe) in rainbowColors.enumerated() {
                let left = edge(CGFloat(index))
                let right = edge(CGFloat(index + 1))
                let band = CGMutablePath()
                band.move(to: CGPoint(x: left.top, y: 300))
                band.addCurve(to: CGPoint(x: left.bottom, y: 0), control1: CGPoint(x: left.top - 10, y: 200),
                              control2: CGPoint(x: left.bottom + 16, y: 110))
                band.addLine(to: CGPoint(x: right.bottom, y: 0))
                band.addCurve(to: CGPoint(x: right.top, y: 300), control1: CGPoint(x: right.bottom + 16, y: 110),
                              control2: CGPoint(x: right.top - 10, y: 200))
                band.closeSubpath()
                fill(band, stripe, in: context)
            }
        }
    }
}
