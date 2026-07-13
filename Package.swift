// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Pastey",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Pastey", path: "Sources/Pastey")
    ]
)
