import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

struct ChartImageError: Error {
    let message: String
}

/// Loads chart images at full resolution and applies the night-mode / rotation treatment.
/// `image(...)` is synchronous and safe to call from a background queue; results are cached
/// so toggling night mode back and forth is instant.
final class ChartImageStore {

    static let shared = ChartImageStore()

    private final class ImageBox {
        let image: NSImage
        init(_ image: NSImage) { self.image = image }
    }

    private let cache = NSCache<NSString, ImageBox>()
    private let ciContext = CIContext(options: nil)

    private init() {
        cache.countLimit = 10
    }

    func clearCache() {
        cache.removeAllObjects()
    }

    func image(url: URL, night: Bool, desaturate: Bool, rotation: Int) -> Result<NSImage, ChartImageError> {
        let key = "\(url.path)|\(night ? 1 : 0)|\(desaturate ? 1 : 0)|\(rotation)" as NSString
        if let cached = cache.object(forKey: key) {
            return .success(cached.image)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let loaded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return .failure(ChartImageError(message: "“\(url.lastPathComponent)” couldn’t be opened as an image."))
        }

        var cgImage = loaded
        if night, let inverted = invert(cgImage, desaturate: desaturate) {
            cgImage = inverted
        }
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
        return .success(image)
    }

    // MARK: - Filters

    private func invert(_ image: CGImage, desaturate: Bool) -> CGImage? {
        let input = CIImage(cgImage: image)

        guard let invertFilter = CIFilter(name: "CIColorInvert") else { return nil }
        invertFilter.setValue(input, forKey: kCIInputImageKey)
        guard let invertedImage = invertFilter.outputImage else { return nil }
        var output = invertedImage

        if desaturate, let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(output, forKey: kCIInputImageKey)
            controls.setValue(0.0, forKey: kCIInputSaturationKey)
            if let desaturated = controls.outputImage {
                output = desaturated
            }
        }

        return ciContext.createCGImage(output, from: output.extent)
    }

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
