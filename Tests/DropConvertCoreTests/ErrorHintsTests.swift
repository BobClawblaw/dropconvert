import XCTest
@testable import DropConvertCore

final class ErrorHintsTests: XCTestCase {
    func testBotCheck() {
        XCTAssertTrue(ErrorHints.message(for: "Sign in to confirm you're not a bot")?
            .contains("cookies") == true)
    }

    func testDiskFull() {
        XCTAssertTrue(ErrorHints.message(for: "No space left on device")?
            .contains("disk is full") == true)
    }

    func testNoStreams() {
        XCTAssertTrue(ErrorHints.message(for: "Stream map '0:a:0' matches no streams")?
            .contains("no audio or video stream") == true)
    }

    func testRemuxFailure() {
        XCTAssertTrue(ErrorHints.message(for: "Could not find tag for codec vp9")?
            .contains("Copy streams") == true)
    }

    func testUnknownReturnsNil() {
        XCTAssertNil(ErrorHints.message(for: "something entirely different"))
    }

    func testFFmpegLocationOnlyTriggersOnErrors() {
        XCTAssertNil(ErrorHints.message(for: "debug: --ffmpeg-location /opt/homebrew/bin"))
        XCTAssertNotNil(ErrorHints.message(for: "ERROR: ffmpeg-location /bad/path does not exist"))
    }

    func testVideoToolboxHint() {
        let message = ErrorHints.message(for: "[h264_videotoolbox] Error: cannot create compression session")
        XCTAssertTrue(message?.contains("Hardware encoding") == true)
    }
}
