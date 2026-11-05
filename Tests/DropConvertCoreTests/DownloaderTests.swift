import XCTest
@testable import DropConvertCore

final class DownloaderTests: XCTestCase {
    func testParsesAndNormalizesLinks() {
        let text = """
        https://www.youtube.com/watch?v=abc123
        youtu.be/abc123
        example.com/clip.mp4
        (https://vimeo.com/123), https://youtu.be/def456
        """
        let links = Downloader.links(in: text)
        XCTAssertEqual(links.map(\.absoluteString), [
            "https://www.youtube.com/watch?v=abc123",
            "https://example.com/clip.mp4",
            "https://vimeo.com/123",
            "https://www.youtube.com/watch?v=def456",
        ])
    }

    func testKeepsPlaylistContext() {
        let links = Downloader.links(in: "https://www.youtube.com/watch?v=abc123&list=PL123")
        XCTAssertEqual(links.first?.absoluteString,
                       "https://www.youtube.com/watch?v=abc123&list=PL123")
    }

    func testRejectsProseAndUnsupportedSchemes() {
        XCTAssertTrue(Downloader.links(in: "e.g. this is prose").isEmpty)
        XCTAssertTrue(Downloader.links(in: "ftp://example.com/file.mp4").isEmpty)
        XCTAssertTrue(Downloader.links(in: "not-a-link").isEmpty)
    }

    func testBareHostGetsHTTPS() {
        let links = Downloader.links(in: "www.example.com/video")
        XCTAssertEqual(links.first?.absoluteString, "https://www.example.com/video")
    }
}

extension DownloaderTests {
    func testHomebrewDetection() {
        let brew = Downloader(ytDlp: URL(fileURLWithPath: "/opt/homebrew/Cellar/yt-dlp/2026.08.19/bin/yt-dlp"))
        XCTAssertTrue(brew.isHomebrew)
        let system = Downloader(ytDlp: URL(fileURLWithPath: "/usr/bin/yt-dlp"))
        XCTAssertFalse(system.isHomebrew)
    }
}
