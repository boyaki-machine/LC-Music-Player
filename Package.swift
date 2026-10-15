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
        .target(name: "AnalysisTransport"),
        .target(name: "AnalysisCore", dependencies: ["AnalysisTransport"]),
        .target(name: "PlaybackCore", dependencies: ["SFBAudioEngine", "AnalysisCore"]),
        .target(name: "LibraryCore", dependencies: ["PlaybackCore"]),
        .target(name: "PlayerUI", dependencies: ["PlaybackCore", "LibraryCore"]),
        .executableTarget(name: "LCMPApp", dependencies: ["PlaybackCore", "LibraryCore", "PlayerUI"]),
        .testTarget(name: "LibraryCoreTests", dependencies: ["LibraryCore", "PlaybackCore"]),
        .testTarget(name: "AnalysisCoreTests", dependencies: ["AnalysisCore", "AnalysisTransport"]),
        .testTarget(name: "PlayerUITests", dependencies: ["PlayerUI"]),
        .testTarget(name: "PlaybackCoreTests", dependencies: ["PlaybackCore", "SFBAudioEngine"],
                    resources: [.copy("Fixtures")]),
    ]
)
