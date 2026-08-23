// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AIMeter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AIMeter", path: "Sources/AIMeter")
    ]
)
