// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "GifCapture",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "GifCapture",
            path: "Sources/GifCapture"
        ),
        .testTarget(
            name: "GifCaptureTests",
            dependencies: ["GifCapture"],
            path: "Tests/GifCaptureTests"
        ),
    ]
)
