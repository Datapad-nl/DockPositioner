// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DockPositioner",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DockPositionerCore"),
        .executableTarget(name: "DockPositioner", dependencies: ["DockPositionerCore"]),
        .testTarget(name: "DockPositionerCoreTests", dependencies: ["DockPositionerCore"]),
    ]
)
