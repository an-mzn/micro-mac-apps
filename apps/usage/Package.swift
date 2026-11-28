// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Usage",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(name: "Usage", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"])
    ]
)
