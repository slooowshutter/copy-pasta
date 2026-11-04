// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CopyPasta",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "CopyPasta", path: "Sources/CopyPasta")
    ]
)
