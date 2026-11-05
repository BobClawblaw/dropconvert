import XCTest
@testable import DropConvertCore

final class QueueStoreTests: XCTestCase {
    func testRecordRoundTrip() throws {
        let record = JobRecord(
            source: .link(URL(string: "https://youtu.be/abc")!),
            formatID: "mp4-h264",
            quality: "high",
            resolution: 1080,
            hardware: true,
            remux: false,
            title: "YouTube · abc",
            outputPath: nil,
            state: "queued",
            note: "test",
            phase: "downloading")
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(JobRecord.self, from: data)
        XCTAssertEqual(decoded.source, record.source)
        XCTAssertEqual(decoded.formatID, record.formatID)
        XCTAssertEqual(decoded.resolution, 1080)
        XCTAssertEqual(decoded.title, record.title)
        XCTAssertEqual(decoded.phase, "downloading")
    }

    func testStoreSaveLoadAndClear() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropConvertQueue-\(UUID().uuidString).json")
        let store = QueueStore(url: url)
        let record = JobRecord(
            source: .file(URL(fileURLWithPath: "/tmp/clip.mp4")),
            formatID: "mp3",
            quality: "medium",
            resolution: 0,
            hardware: false,
            remux: false,
            title: "clip.mp4",
            outputPath: "/tmp/clip.mp3",
            state: "failed",
            error: "No audio track",
            phase: "converting")
        store.save([record])
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.source, record.source)
        XCTAssertEqual(loaded.first?.state, "failed")
        store.clear()
        XCTAssertTrue(store.load().isEmpty)
    }
}
