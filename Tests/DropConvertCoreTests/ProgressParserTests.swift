import XCTest
@testable import DropConvertCore

final class ProgressParserTests: XCTestCase {
    func testFFmpegProgress() {
        let parser = FFmpegProgressParser()
        let first = parser.feed(Data("out_time_us=2500000\n".utf8))
        XCTAssertEqual(first?.seconds ?? 0, 2.5, accuracy: 0.001)
        let second = parser.feed(Data("speed=1.5x\nprogress=end\n".utf8))
        XCTAssertEqual(second?.speed, "1.5x")
        XCTAssertEqual(second?.finished, true)
    }

    func testDownloadProgress() {
        let parser = DownloadProgressParser()
        let update = parser.feed(Data("[download]  12.3% of 100.00MiB at 4.20MiB/s ETA 00:42\n".utf8))
        XCTAssertEqual(update?.fraction ?? 0, 0.123, accuracy: 0.001)
        XCTAssertEqual(update?.speed, "4.20MiB/s")
        XCTAssertEqual(update?.eta, "00:42")
    }

    func testDownloadCompletionLine() {
        let parser = DownloadProgressParser()
        let update = parser.feed(Data("[download] 100% of 10.00MiB in 00:03 at 3.00MiB/s\n".utf8))
        XCTAssertEqual(update?.fraction, 1)
        XCTAssertEqual(update?.speed, "3.00MiB/s")
        XCTAssertNil(update?.eta)
    }

    func testErrorTailKeepsLastLine() {
        let tail = ErrorTail()
        tail.append(Data("warning: one\nERROR: the real problem\n".utf8))
        XCTAssertEqual(tail.lastLine, "ERROR: the real problem")
        XCTAssertTrue(tail.text.contains("warning: one"))
    }

    func testPartialLineIsBuffered() {
        let parser = FFmpegProgressParser()
        XCTAssertNil(parser.feed(Data("out_time_us=1000000".utf8)))
        let update = parser.feed(Data("\n".utf8))
        XCTAssertEqual(update?.seconds ?? 0, 1.0, accuracy: 0.001)
    }

    func testPlaylistItemTracking() {
        let parser = DownloadProgressParser()
        let first = parser.feed(Data("[download] Downloading item 2 of 15\n".utf8))
        XCTAssertEqual(first?.itemIndex, 2)
        XCTAssertEqual(first?.itemCount, 15)
        let second = parser.feed(Data("[download]  40.0% of 20.00MiB at 5.00MiB/s ETA 00:03\n".utf8))
        XCTAssertEqual(second?.itemIndex, 2)
        XCTAssertEqual(second?.itemCount, 15)
        XCTAssertEqual(second?.fraction ?? 0, 0.4, accuracy: 0.001)
        XCTAssertEqual(second?.speed, "5.00MiB/s")
    }
}
