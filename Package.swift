// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Zennly",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Zennly", path: "Sources/Zennly"),
    ],
    swiftLanguageModes: [.v5]
)
