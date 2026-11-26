// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexUsage",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(name: "CodexUsage", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"])
    ]
)
