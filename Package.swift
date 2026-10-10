// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalBar",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "LocalBar", targets: ["LocalBar"])],
    targets: [
        .target(name: "LocalBarCore"),
        .executableTarget(name: "LocalBar", dependencies: ["LocalBarCore"]),
        .executableTarget(name: "LocalBarSetup", dependencies: ["LocalBarCore"]),
        .testTarget(name: "LocalBarCoreTests", dependencies: ["LocalBarCore"]),
        .testTarget(name: "LocalBarTests", dependencies: ["LocalBar", "LocalBarCore"])
    ]
)
