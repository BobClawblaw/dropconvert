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

    func testNormalizesYouTubeMusicLinks() {
        let links = Downloader.links(in: """
        https://music.youtube.com/watch?v=abc123&list=RDAMVMabc123
        https://youtu.be/abc123?list=RDAMVMabc123
        """)
        XCTAssertEqual(links.map(\.absoluteString), [
            "https://www.youtube.com/watch?v=abc123&list=RDAMVMabc123",
        ])
    }
}

extension DownloaderTests {
    func testHomebrewDetection() {
        let brew = Downloader(ytDlp: URL(fileURLWithPath: "/opt/homebrew/Cellar/yt-dlp/2026.08.19/bin/yt-dlp"))
        XCTAssertTrue(brew.isHomebrew)
        let system = Downloader(ytDlp: URL(fileURLWithPath: "/usr/bin/yt-dlp"))
        XCTAssertFalse(system.isHomebrew)
        let standalone = Downloader(ytDlp: URL(fileURLWithPath: "/usr/local/bin/standalone-yt-dlp-nonexistent"))
        XCTAssertFalse(standalone.isHomebrew)
    }
}

extension DownloaderTests {
    func testDownloadsEmbedMetadata() {
        XCTAssertTrue(Downloader.metadataArguments.contains("--embed-metadata"))
    }

    /// Runs the tagging rules through the installed yt-dlp on offline video
    /// info, so no network is needed. Skipped when yt-dlp isn't installed.
    func testMetadataRulesPickTitleAndArtist() throws {
        guard let downloader = Downloader.locate() else { throw XCTSkip("yt-dlp isn't installed") }
        let cases: [(title: String, uploader: String, artist: String?, track: String?,
                     expected: String)] = [
            ("Daft Punk - Get Lucky (Official Video) ft. Pharrell", "DaftPunkVEVO", nil, nil,
             "Get Lucky ft. Pharrell|Daft Punk|"),
            ("Get Lucky", "Daft Punk - Topic", "Daft Punk", "Get Lucky", "Get Lucky|Daft Punk|2013-04-19"),
            ("Radiohead – Creep [Official Music Video]", "Radiohead", nil, nil, "Creep|Radiohead|"),
            ("Adele - Hello (Official Music Video) [HD]", "AdeleVEVO", "Adele", nil, "Hello|Adele|"),
            ("Song Title (Lyrics)", "SomeoneVEVO", nil, nil, "Song Title|Someone|"),
            ("My trip to the coast", "Some Channel", nil, nil, "My trip to the coast|Some Channel|"),
        ]
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        for (index, item) in cases.enumerated() {
            var info: [String: Any] = [
                "id": "test\(index)", "extractor": "youtube", "extractor_key": "Youtube",
                "webpage_url": "https://www.youtube.com/watch?v=test\(index)",
                "title": item.title, "uploader": item.uploader, "upload_date": "20240102",
                "formats": [["format_id": "1", "url": "https://example.invalid/a", "ext": "m4a",
                             "acodec": "aac", "vcodec": "none"]],
            ]
            info["artist"] = item.artist
            info["track"] = item.track
            if item.track != nil { info["release_date"] = "20130419" }
            let file = folder.appendingPathComponent("\(index).info.json")
            try JSONSerialization.data(withJSONObject: info).write(to: file)

            let args = ["--ignore-config", "--no-warnings", "--load-info-json", file.path,
                        "--skip-download"]
                + Downloader.metadataArguments
                + ["--print", "%(meta_title)s|%(meta_artist)s|%(meta_date)s"]
            let result = try XCTUnwrap(ProcessRunner.run(downloader.ytDlp, args,
                                                         environment: ToolLocator.environment(),
                                                         timeout: 60))
            XCTAssertTrue(result.succeeded, result.stderr)
            XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                           item.expected, item.title)
        }
    }
}
