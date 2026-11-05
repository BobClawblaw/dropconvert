import XCTest
@testable import DropConvertCore

final class LinkTextTests: XCTestCase {
    func testAddsLineFeedWhenAppendingWithoutOne() {
        XCTAssertEqual(LinkText.appending("https://example.com/b", to: "https://example.com/a"),
                       "https://example.com/a\nhttps://example.com/b")
    }

    func testNormalizesExistingTrailingNewline() {
        XCTAssertEqual(LinkText.appending("https://example.com/b", to: "https://example.com/a\n"),
                       "https://example.com/a\nhttps://example.com/b")
    }

    func testKeepsMultipleClipboardLines() {
        XCTAssertEqual(LinkText.appending("https://example.com/b\nhttps://example.com/c", to: ""),
                       "https://example.com/b\nhttps://example.com/c")
    }

    func testEmptyClipboardLeavesTextAlone() {
        XCTAssertEqual(LinkText.appending(" \n ", to: "https://example.com/a"),
                       "https://example.com/a")
    }
}
