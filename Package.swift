// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Configgy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Configgy", path: "Sources/Configgy"),
    ],
    swiftLanguageModes: [.v5]
)
