import XCTest
@testable import DropConvertCore

final class ToolLocatorTests: XCTestCase {
    func testFindsSystemTool() {
        let url = ToolLocator.locate(named: "ls")
        XCTAssertNotNil(url)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url!.path))
    }

    func testVersionOutput() {
        let echo = URL(fileURLWithPath: "/bin/echo")
        XCTAssertEqual(ToolLocator.version(of: echo, arguments: ["hello"]), "hello")
    }

    func testEnvironmentContainsSearchPaths() {
        let env = ToolLocator.environment()
        XCTAssertTrue(env["PATH"]?.contains("/opt/homebrew/bin") == true)
        XCTAssertTrue(env["PATH"]?.contains("/usr/bin") == true)
    }
}
