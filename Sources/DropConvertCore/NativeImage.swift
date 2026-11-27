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
    private static let supportedIdentifiers: Set<String> = {
        Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    }()

    public static func supports(_ ext: String) -> Bool {
        guard let type = UTType(filenameExtension: ext) else { return false }
        return supportedIdentifiers.contains(type.identifier)
    }

    public static func convert(input: URL, output: URL, format: OutputFormat,
                               resolution: Resolution, quality: Quality) throws {
        guard let type = UTType(filenameExtension: format.ext),
              supports(format.ext) else {
            throw NativeImageError.unsupported(format.ext)
        }
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw NativeImageError.unreadable(input.lastPathComponent)
        }

        let sourceProperties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let rawWidth = (sourceProperties[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let rawHeight = (sourceProperties[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let orientation = (sourceProperties[kCGImagePropertyOrientation] as? Int) ?? 1
        let swapped = (5...8).contains(orientation)
        let orientedWidth = swapped ? rawHeight : rawWidth
        let orientedHeight = swapped ? rawWidth : rawHeight
        let shortSide = min(orientedWidth, orientedHeight)
        let longSide = max(orientedWidth, orientedHeight)

        if resolution != .original, shortSide > resolution.rawValue, shortSide > 0 {
            let maxPixelSize = max(1, Int((Double(longSide) * Double(resolution.rawValue) / Double(shortSide)).rounded()))
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
                var properties = strippedOrientationProperties(from: sourceProperties)
                if format.hasQuality {
                    properties[kCGImageDestinationLossyCompressionQuality] = compressionQuality(quality)
                }
                try write(image: thumbnail, output: output, type: type, properties: properties)
                return
            }
        }

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NativeImageError.unreadable(input.lastPathComponent)
        }
        var properties = sourceProperties
        if format.hasQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = compressionQuality(quality)
        }
        try write(image: image, output: output, type: type, properties: properties)
    }

    public static func convert(image: CGImage, output: URL, format: OutputFormat,
                               resolution: Resolution, quality: Quality) throws {
        guard let type = UTType(filenameExtension: format.ext),
              supports(format.ext) else {
            throw NativeImageError.unsupported(format.ext)
        }

        let scaled = scale(image, to: resolution) ?? image
        var properties: [CFString: Any] = [:]
        if format.hasQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = compressionQuality(quality)
        }
        try write(image: scaled, output: output, type: type, properties: properties)
    }

    private static func write(image: CGImage, output: URL, type: UTType,
                              properties: [CFString: Any]) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, type.identifier as CFString, 1, nil) else {
            throw NativeImageError.writeFailed(output.path)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NativeImageError.writeFailed(output.path)
        }
    }

    private static func strippedOrientationProperties(from source: [CFString: Any]) -> [CFString: Any] {
        var props = source
        props[kCGImagePropertyOrientation] = 1
        props.removeValue(forKey: kCGImagePropertyPixelWidth)
        props.removeValue(forKey: kCGImagePropertyPixelHeight)
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        return props
    }

    private static func compressionQuality(_ quality: Quality) -> Double {
        switch quality {
        case .high: 0.9
        case .medium: 0.75
        case .low: 0.55
        }
    }

    /// Scale so the image's short side is at most the chosen size; never upscale.
    private static func scale(_ image: CGImage, to resolution: Resolution) -> CGImage? {
        let shortSide = min(image.width, image.height)
        guard resolution != .original, shortSide > resolution.rawValue, shortSide > 0 else { return nil }
        let ratio = Double(resolution.rawValue) / Double(shortSide)
        let width = max(1, Int((Double(image.width) * ratio).rounded()))
        let height = max(1, Int((Double(image.height) * ratio).rounded()))
        let targetSpace: CGColorSpace = {
            if let cs = image.colorSpace, cs.supportsOutput { return cs }
            return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: targetSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ?? CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
