import XCTest
@testable import DropConvertCore

final class OutputNamerTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropConvertTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func testAvoidsExistingFile() throws {
        let existing = folder.appendingPathComponent("clip.mp4")
        try Data().write(to: existing)
        let input = folder.appendingPathComponent("clip.mov")
        try Data().write(to: input)

        let output = OutputNamer.uniqueOutput(input: input, ext: "mp4", folder: folder,
                                              avoiding: [])
        XCTAssertEqual(output.lastPathComponent, "clip 2.mp4")
    }

    func testAvoidsClaimedPath() throws {
        let claimed = folder.appendingPathComponent("clip.mp4").standardizedFileURL.path
        let output = OutputNamer.uniqueOutput(base: "clip", folder: folder, ext: "mp4",
                                              avoiding: [claimed])
        XCTAssertEqual(output.lastPathComponent, "clip 2.mp4")
    }

    func testNeverReturnsInput() throws {
        let input = folder.appendingPathComponent("clip.mp4")
        try Data().write(to: input)
        let output = OutputNamer.uniqueOutput(input: input, ext: "mp4", folder: folder,
                                              avoiding: [])
        XCTAssertNotEqual(output.standardizedFileURL, input.standardizedFileURL)
        XCTAssertEqual(output.lastPathComponent, "clip 2.mp4")
    }

    func testSafeBaseTruncatesAndSanitizes() {
        XCTAssertEqual(OutputNamer.safeBase("a/b"), "a-b")
        let long = String(repeating: "a", count: 400)
        let safe = OutputNamer.safeBase(long)
        XCTAssertLessThanOrEqual(safe.utf8.count, 200)
        XCTAssertEqual(OutputNamer.safeBase("   "), "video")
    }
}
