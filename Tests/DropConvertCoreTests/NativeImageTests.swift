import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DropConvertCore

final class NativeImageTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropConvertImageTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func makeJPEG(width: Int, height: Int, orientation: Int, make: String) throws -> URL {
        let cs = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = try XCTUnwrap(ctx.makeImage())

        let url = folder.appendingPathComponent("sample.jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: make,
                kCGImagePropertyTIFFOrientation: orientation,
            ],
        ]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testPreservesOrientationAndMetadataAtOriginalSize() throws {
        let heic = try XCTUnwrap(OutputFormat.all.first { $0.id == "heic" })
        guard NativeImage.supports("heic") else { throw XCTSkip("HEIC unsupported on this Mac") }

        let input = try makeJPEG(width: 800, height: 600, orientation: 6, make: "DropConvertCam")
        let output = folder.appendingPathComponent("out.heic")
        try NativeImage.convert(input: input, output: output, format: heic,
                                resolution: .original, quality: .high)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyOrientation] as? Int, 6)
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFMake] as? String, "DropConvertCam")
    }

    func testAppliesOrientationAndShortSideScaling() throws {
        let heic = try XCTUnwrap(OutputFormat.all.first { $0.id == "heic" })
        guard NativeImage.supports("heic") else { throw XCTSkip("HEIC unsupported on this Mac") }

        // Stored as 1600x1200 with orientation 6 (90 deg CW -> displayed 1200x1600 portrait).
        // Scaling short side to 480p should yield 480x640 with orientation reset to 1.
        let input = try makeJPEG(width: 1600, height: 1200, orientation: 6, make: "DropConvertCam")
        let output = folder.appendingPathComponent("scaled.heic")
        try NativeImage.convert(input: input, output: output, format: heic,
                                resolution: .p480, quality: .medium)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 480)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 640)
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        XCTAssertEqual(orientation, 1)
    }
}
