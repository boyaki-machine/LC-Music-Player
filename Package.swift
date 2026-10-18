// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LCMP",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LCMP", targets: ["LCMPApp"]),
        .library(name: "PlaybackCore", targets: ["PlaybackCore"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "AnalysisTransport"),
        .target(name: "AnalysisCore", dependencies: ["AnalysisTransport"]),
        .target(name: "LevelDSP", cSettings: [.unsafeFlags(["-O2"])]),
        .target(name: "AudioProcessingCore", dependencies: ["LevelDSP"]),
        .target(name: "PreprocessingCore", dependencies: ["AudioProcessingCore", "LevelDSP", "CSQLite"]),
        .target(name: "PlaybackCore", dependencies: ["AnalysisCore", "PreprocessingCore", "AudioProcessingCore"]),
        .target(name: "LibraryCore", dependencies: ["PlaybackCore", "PreprocessingCore", "AudioProcessingCore"]),
        .target(name: "VisualizationKit"),
        .target(name: "PlayerUI", dependencies: ["PlaybackCore", "LibraryCore", "VisualizationKit", "AnalysisCore"]),
        .executableTarget(name: "LCMPApp", dependencies: ["PlaybackCore", "LibraryCore", "PlayerUI"]),
        .testTarget(name: "PreprocessingCoreTests", dependencies: ["PreprocessingCore", "AudioProcessingCore"]),
        .testTarget(name: "AudioProcessingCoreTests", dependencies: ["AudioProcessingCore", "PreprocessingCore"]),
        .testTarget(name: "LibraryCoreTests", dependencies: ["LibraryCore", "PlaybackCore"]),
        .testTarget(name: "AnalysisCoreTests", dependencies: ["AnalysisCore", "AnalysisTransport"]),
        .testTarget(name: "PlayerUITests", dependencies: ["PlayerUI", "VisualizationKit", "PlaybackCore", "AnalysisCore"]),
        .testTarget(name: "PlaybackCoreTests", dependencies: ["PlaybackCore"],
                    resources: [.copy("Fixtures")]),
    ]
)
