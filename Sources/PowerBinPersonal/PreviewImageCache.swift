import AppKit
import ImageIO

/// Decoded preview images, cached and downsampled.
///
/// `PresetRow` and the Favorites / Most Used rows used to call `NSImage(contentsOf:)`
/// straight from their view bodies. SwiftUI re-evaluates a body on every scroll frame,
/// every selection change and every store mutation, so each visible row was doing a
/// synchronous disk read and a full-resolution PNG decode many times a second — for a
/// 52×36 thumbnail, from a file that is usually a full-screen Premiere screenshot. That is
/// the single largest source of scroll stutter in the panel.
///
/// Two things fix it: cache the result, and decode at the size actually drawn.
/// `CGImageSourceCreateThumbnailAtIndex` never materialises the full-size bitmap.
///
/// The cache key is the file path alone, which is safe because a preview is never edited
/// in place — `PresetStore.attachPreviewImage` always writes a fresh
/// `<presetID>-<uuid>.<ext>`, so a replaced preview is a new path and misses the cache.
final class PreviewImageCache {
    static let shared = PreviewImageCache()

    /// Long edge for list thumbnails, in pixels. 2× the ~52pt drawn size covers Retina.
    static let thumbnailPixels: CGFloat = 160
    /// Long edge for the preview pane's larger image.
    static let previewPixels: CGFloat = 900

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 400
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(for url: URL?, maxPixel: CGFloat) -> NSImage? {
        guard let url else { return nil }
        let key = "\(url.path)|\(Int(maxPixel))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = Self.downsample(url: url, maxPixel: maxPixel) else { return nil }
        cache.setObject(image, forKey: key, cost: Self.cost(of: image))
        return image
    }

    func thumbnail(for url: URL?) -> NSImage? {
        image(for: url, maxPixel: Self.thumbnailPixels)
    }

    func preview(for url: URL?) -> NSImage? {
        image(for: url, maxPixel: Self.previewPixels)
    }

    /// Only needed if a preview file is ever overwritten at the same path. Kept so callers
    /// have somewhere to go if that assumption changes.
    func invalidate(_ url: URL) {
        for pixels in [Self.thumbnailPixels, Self.previewPixels] {
            cache.removeObject(forKey: "\(url.path)|\(Int(pixels))" as NSString)
        }
    }

    private static func downsample(url: URL, maxPixel: CGFloat) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as [CFString: Any] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        return NSImage(cgImage: cgImage,
                       size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func cost(of image: NSImage) -> Int {
        Int(image.size.width * image.size.height * 4)
    }
}
