// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CopyPasta",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Self-updates. A binary framework: build.sh copies it into CopyPasta.app/Contents/Frameworks.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "CopyPasta",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/CopyPasta",
            // Where dyld finds Sparkle.framework: Contents/Frameworks inside CopyPasta.app, and
            // next to the binary in .build/ (for `.build/debug/CopyPasta --render-cards …`).
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", "@loader_path",
            ])]
        ),
        .testTarget(
            name: "CopyPastaTests", dependencies: ["CopyPasta"], path: "Tests/CopyPastaTests",
            // Sparkle.framework sits next to CopyPastaTests.xctest in .build/, three levels up
            // from the bundle's binary (Contents/MacOS).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])]
        ),
    ]
)
