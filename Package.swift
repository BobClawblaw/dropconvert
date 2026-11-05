// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DropConvert",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "DropConvertCore",
            path: "Sources/DropConvertCore",
            swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]
        ),
        .executableTarget(
            name: "DropConvert",
            dependencies: ["DropConvertCore"],
            path: "Sources/DropConvert",
            swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]
        ),
        .testTarget(
            name: "DropConvertCoreTests",
            dependencies: ["DropConvertCore"],
            path: "Tests/DropConvertCoreTests"
        ),
    ]
)
