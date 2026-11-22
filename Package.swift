// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TeachOverlay",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "TeachOverlay", path: "Sources/TeachOverlay")
    ]
)
