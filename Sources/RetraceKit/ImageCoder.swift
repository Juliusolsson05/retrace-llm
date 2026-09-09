import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Encodes model-ready image payloads: bounded long edge, JPEG, no metadata.
public enum ImageCoder {
    /// Downscales so the long edge is at most `maxDimension` (never upscales) and
    /// returns JPEG bytes. Screens are visually dense; JPEG at this size is the
    /// doc-locked model payload shape (≤768px, low media resolution).
    public static func jpegData(from image: CGImage, maxDimension: Int) -> Data? {
        let longEdge = max(image.width, image.height)
        guard longEdge > 0 else { return nil }
        let scale = min(1.0, Double(maxDimension) / Double(longEdge))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
