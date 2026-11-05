import XCTest
@testable import DropConvertCore

final class FormatTests: XCTestCase {
    private let encoders: Set<String> = ["libx264", "aac", "libx265", "hevc_videotoolbox",
                                         "h264_videotoolbox", "libsvtav1", "libopus",
                                         "libmp3lame", "pcm_s16le", "pcm_s16be", "flac",
                                         "alac", "mjpeg", "png", "tiff", "bmp", "qoi", "gif"]

    private func options(remux: Bool = false, hardware: Bool = false) -> EncodeOptions {
        EncodeOptions(quality: .high, resolution: .original, hardware: hardware,
                      remux: remux, encoders: encoders)
    }

    func testMP4Arguments() throws {
        let format = try XCTUnwrap(OutputFormat.all.first { $0.id == "mp4-h264" })
        let args = format.arguments(input: "/tmp/in.mov", output: "/tmp/out.mp4",
                                    options: options())
        XCTAssertTrue(args.contains("libx264"))
        XCTAssertTrue(args.contains("aac"))
        XCTAssertTrue(args.contains("-movflags"))
        XCTAssertEqual(args.last, "/tmp/out.mp4")
    }

    func testAudioMapsOnlyAudio() throws {
        let format = try XCTUnwrap(OutputFormat.all.first { $0.id == "aiff" })
        let args = format.arguments(input: "/tmp/in.mp4", output: "/tmp/out.aiff",
                                    options: options())
        XCTAssertTrue(args.contains("-map"))
        XCTAssertTrue(args.contains("0:a:0"))
        XCTAssertTrue(args.contains("-vn"))
        XCTAssertTrue(args.contains("pcm_s16be"))
    }

    func testRemuxUsesCopy() throws {
        let format = try XCTUnwrap(OutputFormat.all.first { $0.id == "mkv-h264" })
        let args = format.arguments(input: "/tmp/in.mp4", output: "/tmp/out.mkv",
                                    options: options(remux: true))
        XCTAssertTrue(args.contains("-c"))
        XCTAssertTrue(args.contains("copy"))
    }

    func testImageIOFormatsHaveNoFFmpegArguments() throws {
        let format = try XCTUnwrap(OutputFormat.all.first { $0.id == "heic" })
        XCTAssertEqual(format.engine, .imageIO)
        XCTAssertTrue(format.arguments(input: "/tmp/in.png", output: "/tmp/out.heic",
                                       options: options()).isEmpty)
        XCTAssertTrue(NativeImage.supports("heic"))
    }

    func testAvailabilityRequiresEncoders() throws {
        let format = try XCTUnwrap(OutputFormat.all.first { $0.id == "webm-vp9" })
        XCTAssertFalse(format.isAvailable(["libx264", "aac"]))
        XCTAssertTrue(format.isAvailable(["libvpx-vp9", "libopus"]))
    }

    func testHardwareFallback() {
        XCTAssertTrue(OutputFormat.hw("libx264", "h264_videotoolbox", options(hardware: true)))
        XCTAssertFalse(OutputFormat.hw("libx264", "h264_videotoolbox", options(hardware: false)))
    }
}
