// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowOffset",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "WindowOffset", targets: ["WindowOffset"])],
    targets: [
        .target(name: "OffsetCore"),
        .executableTarget(name: "WindowOffset", dependencies: ["OffsetCore"]),
        .executableTarget(name: "LayoutChecks", dependencies: ["OffsetCore"], path: "Tests/OffsetCoreTests")
    ]
)
