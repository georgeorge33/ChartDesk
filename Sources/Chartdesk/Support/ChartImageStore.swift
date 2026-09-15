import AppKit
import CoreGraphics
import Foundation
import ImageIO

struct ChartImageError: Error {
    let message: String
}

/// Loads chart images at full resolution and applies the rotation.
/// `image(...)` is synchronous and safe to call from a background queue; results are cached
/// so turning a plate back and forth is instant.
final class ChartImageStore {

    static let shared = ChartImageStore()

    private final class ImageBox {
        let image: NSImage
        init(_ image: NSImage) { self.image = image }
    }

    private let cache = NSCache<NSString, ImageBox>()

    private init() {
        cache.countLimit = countLimit
    }

    // MARK: - Statistics

    /// Counters for the Performance window. `NSCache` does not expose its own count, so
    /// occupancy is tracked here; it is an upper bound, because the cache may evict without
    /// telling us.
    struct Statistics {
        var count = 0
        var limit = 0
        var hits = 0
        var misses = 0
        var lastDecodeSeconds: Double?
        var slowestDecodeSeconds: Double?
    }

    private let countLimit = 10
    private let statsLock = NSLock()
    private var stats = Statistics()

    func statistics() -> Statistics {
        statsLock.lock()
        defer { statsLock.unlock() }
        var snapshot = stats
        snapshot.limit = countLimit
        return snapshot
    }

    func resetStatistics() {
        statsLock.lock()
        let occupancy = stats.count
        stats = Statistics()
        stats.count = occupancy
        statsLock.unlock()
    }

    func clearCache() {
        cache.removeAllObjects()
        statsLock.lock()
        stats.count = 0
        statsLock.unlock()
    }

    func image(url: URL, rotation: Int) -> Result<NSImage, ChartImageError> {
        let key = "\(url.path)|\(rotation)" as NSString
        if let cached = cache.object(forKey: key) {
            statsLock.lock()
            stats.hits += 1
            statsLock.unlock()
            return .success(cached.image)
        }

        let startedAt = DispatchTime.now()

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let loaded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return .failure(ChartImageError(message: "“\(url.lastPathComponent)” couldn’t be opened as an image."))
        }

        var cgImage = loaded
        let normalisedRotation = ((rotation % 360) + 360) % 360
        if normalisedRotation != 0, let rotated = rotate(cgImage, degrees: normalisedRotation) {
            cgImage = rotated
        }

        let size = NSSize(width: cgImage.width, height: cgImage.height)
        guard size.width > 0, size.height > 0 else {
            return .failure(ChartImageError(message: "“\(url.lastPathComponent)” has no usable image data."))
        }

        let image = NSImage(cgImage: cgImage, size: size)
        cache.setObject(ImageBox(image), forKey: key)

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000_000
        statsLock.lock()
        stats.misses += 1
        stats.count = min(stats.count + 1, countLimit)
        stats.lastDecodeSeconds = elapsed
        stats.slowestDecodeSeconds = max(stats.slowestDecodeSeconds ?? 0, elapsed)
        statsLock.unlock()

        return .success(image)
    }

    // MARK: - Filters

    /// Rotates clockwise by 90 / 180 / 270 degrees.
    private func rotate(_ image: CGImage, degrees: Int) -> CGImage? {
        let width = image.width
        let height = image.height
        let quarterTurn = degrees % 180 != 0
        let newWidth = quarterTurn ? height : width
        let newHeight = quarterTurn ? width : height

        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.translateBy(x: CGFloat(newWidth) / 2, y: CGFloat(newHeight) / 2)
        // Core Graphics rotates counter-clockwise for positive angles, so negate for a
        // clockwise "rotate right".
        context.rotate(by: -CGFloat(degrees) * .pi / 180)
        context.draw(image, in: CGRect(x: -CGFloat(width) / 2,
                                       y: -CGFloat(height) / 2,
                                       width: CGFloat(width),
                                       height: CGFloat(height)))
        return context.makeImage()
    }
}
