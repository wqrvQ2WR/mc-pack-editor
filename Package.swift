// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "McPackEditor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "McPackEditor", path: "Sources/McPackEditor")
    ]
)
