import XCTest
@testable import DropConvertCore

final class MediaFilesTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropConvertMedia-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func testExpandsFolderAndSkipsNonMedia() throws {
        try Data().write(to: folder.appendingPathComponent("clip.mp4"))
        try Data().write(to: folder.appendingPathComponent("notes.txt"))
        let sub = folder.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data().write(to: sub.appendingPathComponent("song.wav"))

        let files = MediaFiles.expand([folder])
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["clip.mp4", "song.wav"])
    }

    func testIgnoresUnknownFiles() {
        XCTAssertFalse(MediaFiles.isMedia(folder.appendingPathComponent("notes.txt")))
        XCTAssertTrue(MediaFiles.isMedia(folder.appendingPathComponent("clip.mkv")))
    }
}
