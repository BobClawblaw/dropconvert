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

extension FormatTests {
    func testMP3WritesID3v23() throws {
        let format = try XCTUnwrap(OutputFormat.all.first { $0.id == "mp3" })
        let args = format.arguments(input: "/tmp/in.webm", output: "/tmp/out.mp3", options: options())
        let index = try XCTUnwrap(args.firstIndex(of: "-id3v2_version"))
        XCTAssertEqual(args[index + 1], "3")
    }

    func testAIFFWritesTags() throws {
        let format = try XCTUnwrap(OutputFormat.all.first { $0.id == "aiff" })
        let args = format.arguments(input: "/tmp/in.webm", output: "/tmp/out.aiff", options: options())
        let index = try XCTUnwrap(args.firstIndex(of: "-write_id3v2"))
        XCTAssertEqual(args[index + 1], "1")
    }

    func testCoverArtIsEmbeddedAsSquareAttachedPicture() throws {
        let format = try XCTUnwrap(OutputFormat.all.first { $0.id == "mp3" })
        let args = format.arguments(input: "/tmp/in.webm", output: "/tmp/out.mp3",
                                    options: options(), cover: "/tmp/in.jpg")
        XCTAssertEqual(args.filter { $0 == "-i" }.count, 2)
        XCTAssertTrue(args.contains("/tmp/in.jpg"))
        XCTAssertTrue(args.contains("1:v:0"))
        XCTAssertTrue(args.contains("attached_pic"))
        XCTAssertFalse(args.contains("-vn"))
        XCTAssertEqual(args.last, "/tmp/out.mp3")
    }

    func testCoverArtRemuxCopiesOnlyAudio() throws {
        let format = try XCTUnwrap(OutputFormat.all.first { $0.id == "m4a" })
        let args = format.arguments(input: "/tmp/in.m4a", output: "/tmp/out.m4a",
                                    options: options(remux: true), cover: "/tmp/in.jpg")
        XCTAssertTrue(args.contains("-c:a"))
        XCTAssertFalse(args.contains("-c"))
        XCTAssertTrue(args.contains("mjpeg"))
    }

    func testCoverArtSkippedWhereContainerCantHoldIt() throws {
        for id in ["ogg-opus", "wav", "caf", "mp4-h264"] {
            let format = try XCTUnwrap(OutputFormat.all.first { $0.id == id })
            XCTAssertFalse(format.canEmbedCover, id)
            let args = format.arguments(input: "/tmp/in.webm", output: "/tmp/out",
                                        options: options(), cover: "/tmp/in.jpg")
            XCTAssertFalse(args.contains("/tmp/in.jpg"), id)
        }
    }

    func testSubtitleMappingForMP4AndMKV() throws {
        let mp4 = try XCTUnwrap(OutputFormat.all.first { $0.id == "mp4-h264" })
        let mp4Args = mp4.arguments(input: "/tmp/in.mkv", output: "/tmp/out.mp4", options: options())
        XCTAssertTrue(mp4Args.contains("0:s?"))
        let subIdx = try XCTUnwrap(mp4Args.firstIndex(of: "-c:s"))
        XCTAssertEqual(mp4Args[subIdx + 1], "mov_text")

        let mp4Remux = mp4.arguments(input: "/tmp/in.mkv", output: "/tmp/out.mp4",
                                     options: options(remux: true))
        XCTAssertTrue(mp4Remux.contains("0:s?"))
        XCTAssertTrue(mp4Remux.contains("mov_text"))

        let mp4NoSubs = mp4.arguments(input: "/tmp/in.mkv", output: "/tmp/out.mp4",
                                      options: options(), includeSubtitles: false)
        XCTAssertFalse(mp4NoSubs.contains("0:s?"))

        let mkv = try XCTUnwrap(OutputFormat.all.first { $0.id == "mkv-h264" })
        let mkvArgs = mkv.arguments(input: "/tmp/in.mkv", output: "/tmp/out.mkv", options: options())
        XCTAssertTrue(mkvArgs.contains("0:s?"))
        let mkvSubIdx = try XCTUnwrap(mkvArgs.firstIndex(of: "-c:s"))
        XCTAssertEqual(mkvArgs[mkvSubIdx + 1], "copy")

        let webm = try XCTUnwrap(OutputFormat.all.first { $0.id == "webm-vp9" })
        let webmArgs = webm.arguments(input: "/tmp/in.mkv", output: "/tmp/out.webm", options: options())
        XCTAssertFalse(webmArgs.contains("0:s?"))
    }

    func testAvailabilityRequiresAudioEncoderWithHardware() throws {
        let mp4 = try XCTUnwrap(OutputFormat.all.first { $0.id == "mp4-h264" })
        XCTAssertFalse(mp4.isAvailable(["h264_videotoolbox"]))
        XCTAssertTrue(mp4.isAvailable(["h264_videotoolbox", "aac"]))
    }

    func testShortSideScaleFilterUsesOrientationAwareExpression() throws {
        let mp4 = try XCTUnwrap(OutputFormat.all.first { $0.id == "mp4-h264" })
        let opts = EncodeOptions(quality: .medium, resolution: .p1080, hardware: false,
                                 remux: false, encoders: encoders)
        let args = mp4.arguments(input: "/tmp/in.mov", output: "/tmp/out.mp4", options: opts)
        let vfIndex = try XCTUnwrap(args.firstIndex(of: "-vf"))
        let filter = args[vfIndex + 1]
        XCTAssertTrue(filter.contains("lte(ih,iw)"))
        XCTAssertTrue(filter.contains("1080"))
    }
}
