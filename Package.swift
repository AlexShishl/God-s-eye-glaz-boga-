// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchDrawer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "NotchDrawer", path: "Sources/NotchDrawer")
    ]
)
