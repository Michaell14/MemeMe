import Foundation

/// An 8-bit RGB picture, rows top-down, the way the benchmark's PIL images hold it. The hybrid matcher's
/// preprocessing works on this so it can copy PIL and torchvision step by step (and be tested off the Mac).
public struct RGBImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]   // width × height × 3

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0 && pixels.count == width * height * 3, "RGBImage: size and pixels disagree")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// From four-channel rows (`bytesPerRow` apart): RGBA or BGRA order, the fourth byte dropped (PIL's convert("RGB")).
    public init(fourChannel bytes: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int, bgra: Bool) {
        var out = [UInt8](repeating: 0, count: width * height * 3)
        let r = bgra ? 2 : 0, b = bgra ? 0 : 2
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let i = row + x * 4, o = (y * width + x) * 3
                out[o] = bytes[i + r]
                out[o + 1] = bytes[i + 1]
                out[o + 2] = bytes[i + b]
            }
        }
        self.init(width: width, height: height, pixels: out)
    }

    /// PIL's `Image.crop` of an integer box already inside the picture.
    public func cropped(to rect: PixelRect) -> RGBImage {
        let x0 = max(0, min(width - 1, rect.x0)), y0 = max(0, min(height - 1, rect.y0))
        let x1 = max(x0 + 1, min(width, rect.x1)), y1 = max(y0 + 1, min(height, rect.y1))
        let w = x1 - x0, h = y1 - y0
        var out = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            let src = ((y0 + y) * width + x0) * 3
            out.replaceSubrange((y * w * 3)..<((y + 1) * w * 3), with: pixels[src..<(src + w * 3)])
        }
        return RGBImage(width: w, height: h, pixels: out)
    }

    /// PIL's `Image.resize(size, Image.BICUBIC)` for an RGB image (antialiased: the kernel widens when shrinking),
    /// with its 8-bit fixed-point arithmetic, so the result matches Pillow's to the byte.
    public func resizedBicubic(width newWidth: Int, height newHeight: Int) -> RGBImage {
        if newWidth == width && newHeight == height { return self }
        var image = self
        if newWidth != width {
            image = image.resampled(horizontal: true, to: newWidth)
        }
        if newHeight != height {
            image = image.resampled(horizontal: false, to: newHeight)
        }
        return image
    }

    private func resampled(horizontal: Bool, to outSize: Int) -> RGBImage {
        let inSize = horizontal ? width : height
        let (bounds, kernel, ksize) = PILResample.coefficients(inSize: inSize, outSize: outSize)
        let outW = horizontal ? outSize : width, outH = horizontal ? height : outSize
        var out = [UInt8](repeating: 0, count: outW * outH * 3)
        let shift = PILResample.precisionBits
        let half = Int64(1) << (shift - 1)
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for o in 0..<outSize {
                    let xmin = bounds[o * 2], count = bounds[o * 2 + 1]
                    let k = o * ksize
                    let lines = horizontal ? height : width
                    for line in 0..<lines {
                        var s0 = half, s1 = half, s2 = half
                        for t in 0..<count {
                            let i = xmin + t
                            let p = horizontal ? (line * width + i) * 3 : (i * width + line) * 3
                            let c = Int64(kernel[k + t])
                            s0 += Int64(src[p]) * c
                            s1 += Int64(src[p + 1]) * c
                            s2 += Int64(src[p + 2]) * c
                        }
                        let q = horizontal ? (line * outW + o) * 3 : (o * outW + line) * 3
                        dst[q] = PILResample.clip8(s0 >> Int64(shift))
                        dst[q + 1] = PILResample.clip8(s1 >> Int64(shift))
                        dst[q + 2] = PILResample.clip8(s2 >> Int64(shift))
                    }
                }
            }
        }
        return RGBImage(width: outW, height: outH, pixels: out)
    }

    /// Scaled to 0...1, normalized per channel, channels first (1 × 3 × height × width as a flat array).
    public func normalizedCHW(mean: [Float], std: [Float]) -> [Float] {
        let n = width * height
        var out = [Float](repeating: 0, count: 3 * n)
        for i in 0..<n {
            for c in 0..<3 {
                out[c * n + i] = (Float(pixels[i * 3 + c]) / 255 - mean[c]) / std[c]
            }
        }
        return out
    }
}

/// An integer box in pixels (x1, y1 exclusive), PIL's (left, upper, right, lower).
public struct PixelRect: Equatable, Sendable {
    public var x0, y0, x1, y1: Int
    public init(x0: Int, y0: Int, x1: Int, y1: Int) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }
    public var width: Int { x1 - x0 }
    public var height: Int { y1 - y0 }
}

/// The two models' inputs, exactly as the benchmark made them.
public enum HybridPreprocess {
    public static let side = 224
    public static let clipMean: [Float] = [0.48145466, 0.4578275, 0.40821073]
    public static let clipStd: [Float] = [0.26862954, 0.26130258, 0.27577711]
    public static let imageNetMean: [Float] = [0.485, 0.456, 0.406]
    public static let imageNetStd: [Float] = [0.229, 0.224, 0.225]
    /// Boxes narrower or shorter than this are ignored, as the benchmark's detector did.
    public static let minimumFaceSide = 12
    public static let faceMargin = 0.15

    /// open_clip's transform: the shorter side to 224 (bicubic; torchvision truncates the longer side), a centered
    /// 224 × 224 crop (torchvision rounds its offset half to even), CLIP's mean and std.
    public static func clipInput(_ image: RGBImage) -> [Float] {
        let short = min(image.width, image.height), long = max(image.width, image.height)
        let newLong = Int(Double(side) * Double(long) / Double(short))
        let (w, h) = image.width <= image.height ? (side, newLong) : (newLong, side)
        let resized = image.resizedBicubic(width: w, height: h)
        let top = Int((Double(h - side) / 2).rounded(.toNearestOrEven))
        let left = Int((Double(w - side) / 2).rounded(.toNearestOrEven))
        let crop = resized.cropped(to: PixelRect(x0: left, y0: top, x1: left + side, y1: top + side))
        return crop.normalizedCHW(mean: clipMean, std: clipStd)
    }

    /// HSEmotion's input: straight to 224 × 224 (bicubic, no padding), ImageNet's mean and std.
    public static func emotionInput(_ face: RGBImage) -> [Float] {
        face.resizedBicubic(width: side, height: side).normalizedCHW(mean: imageNetMean, std: imageNetStd)
    }

    /// The benchmark's face crop for a detector box in pixels (top-left origin): the box truncated to whole pixels and
    /// clipped to the picture, `faceMargin` of its larger side added on every side, clipped again, then rounded the way
    /// PIL's crop rounds (half to even). nil for a box under `minimumFaceSide`.
    public static func faceCrop(x1 bx1: Double, y1 by1: Double, x2 bx2: Double, y2 by2: Double,
                                imageWidth w: Int, imageHeight h: Int) -> PixelRect? {
        let x1 = max(0, Int(bx1)), y1 = max(0, Int(by1)), x2 = min(w, Int(bx2)), y2 = min(h, Int(by2))
        guard x2 - x1 >= minimumFaceSide, y2 - y1 >= minimumFaceSide else { return nil }
        let m = faceMargin * Double(max(x2 - x1, y2 - y1))
        func r(_ v: Double) -> Int { Int(v.rounded(.toNearestOrEven)) }
        let rect = PixelRect(x0: r(max(0, Double(x1) - m)), y0: r(max(0, Double(y1) - m)),
                             x1: r(min(Double(w), Double(x2) + m)), y1: r(min(Double(h), Double(y2) + m)))
        guard rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    /// `faceCrop` for a Vision box (normalized, origin bottom-left).
    public static func faceCrop(visionBox x: Double, y: Double, width bw: Double, height bh: Double,
                                imageWidth w: Int, imageHeight h: Int) -> PixelRect? {
        faceCrop(x1: x * Double(w), y1: (1 - y - bh) * Double(h), x2: (x + bw) * Double(w), y2: (1 - y) * Double(h),
                 imageWidth: w, imageHeight: h)
    }
}

/// Pillow's resampling (libImaging/Resample.c): bicubic filter (a = −0.5), support scaled when shrinking, coefficients
/// normalized then fixed to 22 fractional bits.
enum PILResample {
    static let precisionBits = 32 - 8 - 2

    static func bicubic(_ v: Double) -> Double {
        let a = -0.5
        let x = abs(v)
        if x < 1 { return ((a + 2) * x - (a + 3)) * x * x + 1 }
        if x < 2 { return (((x - 5) * x + 8) * x - 4) * a }
        return 0
    }

    /// (bounds: [xmin, count] per output pixel, fixed-point kernel rows of `ksize`, ksize)
    static func coefficients(inSize: Int, outSize: Int) -> ([Int], [Int32], Int) {
        let support0 = 2.0
        let scale = Double(inSize) / Double(outSize)
        let filterscale = max(scale, 1)
        let support = support0 * filterscale
        let ksize = Int(support.rounded(.up)) * 2 + 1
        var bounds = [Int](repeating: 0, count: outSize * 2)
        var kernel = [Int32](repeating: 0, count: outSize * ksize)
        var k = [Double](repeating: 0, count: ksize)
        for xx in 0..<outSize {
            let center = (Double(xx) + 0.5) * scale
            var ww = 0.0
            let ss = 1.0 / filterscale
            var xmin = Int(center - support + 0.5)   // C truncation toward zero
            if xmin < 0 { xmin = 0 }
            var xmax = Int(center + support + 0.5)
            if xmax > inSize { xmax = inSize }
            xmax -= xmin
            for x in 0..<ksize { k[x] = 0 }
            for x in 0..<xmax {
                let w = bicubic((Double(x + xmin) - center + 0.5) * ss)
                k[x] = w
                ww += w
            }
            for x in 0..<xmax where ww != 0 { k[x] /= ww }
            for x in 0..<ksize {
                let scaled = k[x] * Double(1 << precisionBits)
                kernel[xx * ksize + x] = Int32(k[x] < 0 ? (-0.5 + scaled).rounded(.towardZero) : (0.5 + scaled).rounded(.towardZero))
            }
            bounds[xx * 2] = xmin
            bounds[xx * 2 + 1] = xmax
        }
        return (bounds, kernel, ksize)
    }

    static func clip8(_ v: Int64) -> UInt8 {
        v <= 0 ? 0 : (v >= 255 ? 255 : UInt8(v))
    }
}
