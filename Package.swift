// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DropConvert",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DropConvert", path: "Sources/DropConvert")
    ]
)
