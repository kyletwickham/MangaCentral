import UIKit
import ImageIO

/// How big a decoded page should be, in pixels.
/// `height == nil` means "fit to width" (used for webtoon strips).
struct ImageTarget: Hashable {
    var width: CGFloat
    var height: CGFloat?

    /// The longest side (in pixels) the decoded image should have.
    func longSide(pixelWidth w: CGFloat, pixelHeight h: CGFloat) -> CGFloat {
        guard w > 0, h > 0 else { return max(width, height ?? width) }
        var scale = width / w
        if let height { scale = min(scale, height / h) }
        scale = min(scale, 1) // never upscale
        return min(max(w, h) * scale, 16_384)
    }
}

enum ImageDecoder {
    /// Decodes and downsizes in one step so huge scans don't eat memory.
    static func decode(source: CGImageSource, target: ImageTarget) -> UIImage? {
        var maxPixel = max(target.width, target.height ?? target.width)
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue {
            maxPixel = target.longSide(pixelWidth: CGFloat(w), pixelHeight: CGFloat(h))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel.rounded(.up))
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    static func decode(data: Data, target: ImageTarget) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return decode(source: src, target: target)
    }

    static func decode(url: URL, target: ImageTarget) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return decode(source: src, target: target)
    }
}

enum ImageCompositor {
    /// Joins two pages into one image for a two-page spread.
    static func sideBySide(left: UIImage, right: UIImage) -> UIImage {
        let h = max(left.size.height, right.size.height)
        let lw = left.size.width * h / max(left.size.height, 1)
        let rw = right.size.width * h / max(right.size.height, 1)
        let size = CGSize(width: lw + rw, height: h)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            left.draw(in: CGRect(x: 0, y: 0, width: lw, height: h))
            right.draw(in: CGRect(x: lw, y: 0, width: rw, height: h))
        }
    }
}
