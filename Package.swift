// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LatexWriter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "LatexWriter", path: "Sources/LatexWriter"),
        .testTarget(name: "LatexWriterTests", dependencies: ["LatexWriter"], path: "Tests/LatexWriterTests"),
    ]
)
