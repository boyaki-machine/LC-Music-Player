// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LCMP",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LCMP", targets: ["LCMPApp"]),
        .library(name: "PlaybackCore", targets: ["PlaybackCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sbooth/SFBAudioEngine.git", exact: "0.14.0"),
    ],
    targets: [
        .target(name: "PlaybackCore", dependencies: ["SFBAudioEngine"]),
        .target(name: "PlayerUI", dependencies: ["PlaybackCore"]),
        .executableTarget(name: "LCMPApp", dependencies: ["PlaybackCore", "PlayerUI"]),
        .testTarget(name: "PlayerUITests", dependencies: ["PlayerUI"]),
        .testTarget(name: "PlaybackCoreTests", dependencies: ["PlaybackCore", "SFBAudioEngine"],
                    resources: [.copy("Fixtures")]),
    ]
)
