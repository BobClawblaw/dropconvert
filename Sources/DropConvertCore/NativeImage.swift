import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum NativeImageError: LocalizedError {
    case unreadable(String)
    case unsupported(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return "Couldn't read \(name) as an image."
        case .unsupported(let ext):
            return "This Mac can't write .\(ext) images."
        case .writeFailed(let path):
            return "Couldn't write \(path)."
        }
    }
}

/// HEIC and AVIF still images, produced with macOS ImageIO instead of ffmpeg.
public enum NativeImage {
    public static func supports(_ ext: String) -> Bool {
        guard let type = UTType(filenameExtension: ext) else { return false }
        let identifiers = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return identifiers.contains(type.identifier)
    }

    public static func convert(input: URL, output: URL, format: OutputFormat,
                               resolution: Resolution, quality: Quality) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NativeImageError.unreadable(input.lastPathComponent)
        }
        try convert(image: image, output: output, format: format,
                    resolution: resolution, quality: quality)
    }

    public static func convert(image: CGImage, output: URL, format: OutputFormat,
                               resolution: Resolution, quality: Quality) throws {
        guard let type = UTType(filenameExtension: format.ext),
              supports(format.ext) else {
            throw NativeImageError.unsupported(format.ext)
        }

        let scaled = scale(image, to: resolution) ?? image
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, type.identifier as CFString, 1, nil) else {
            throw NativeImageError.writeFailed(output.path)
        }

        var properties: [CFString: Any] = [:]
        if format.hasQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = compressionQuality(quality)
        }
        CGImageDestinationAddImage(destination, scaled, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NativeImageError.writeFailed(output.path)
        }
    }

    private static func compressionQuality(_ quality: Quality) -> Double {
        switch quality {
        case .high: 0.9
        case .medium: 0.75
        case .low: 0.55
        }
    }

    /// Scale so the image's height is at most the chosen size; never upscale.
    private static func scale(_ image: CGImage, to resolution: Resolution) -> CGImage? {
        guard resolution != .original, image.height > resolution.rawValue else { return nil }
        let height = resolution.rawValue
        let width = max(1, Int((Double(image.width) * Double(height) / Double(image.height)).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
