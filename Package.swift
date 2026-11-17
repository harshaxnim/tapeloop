// swift-tools-version:6.0
import PackageDescription

var targets: [Target] = []
var appDependencies: [Target.Dependency] = []

#if os(macOS)
    // On-device Parakeet transcription through transcribe.cpp (MIT): its prebuilt macOS library (universal, Metal) and
    // its Swift wrapper, both vendored in ThirdParty/TranscribeCpp. macOS only, so Linux CI never sees them.
    targets += [
        .binaryTarget(name: "CTranscribe", path: "ThirdParty/TranscribeCpp/CTranscribe.xcframework"),
        .target(
            name: "TranscribeCpp",
            dependencies: ["CTranscribe"],
            path: "ThirdParty/TranscribeCpp/Sources",
            linkerSettings: [
                .linkedLibrary("c++"), .linkedLibrary("z"), .linkedFramework("Accelerate"),
                .linkedFramework("Metal"), .linkedFramework("MetalKit"),
            ]
        ),
        .target(name: "TapeloopParakeet", dependencies: ["TapeloopCore", "TapeloopIntelligence", "TranscribeCpp"]),
        .testTarget(name: "TapeloopParakeetTests", dependencies: ["TapeloopCore", "TapeloopParakeet"]),
    ]
    appDependencies = ["TapeloopParakeet"]
#endif

let package = Package(
    name: "Tapeloop",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TapeloopCore", targets: ["TapeloopCore"]),
        .executable(name: "Tapeloop", targets: ["Tapeloop"]),
    ],
    targets: [
        // Pure Swift. Builds and tests on Linux too.
        .target(name: "TapeloopCore"),
        // macOS-only modules. Their sources are wrapped in `#if os(macOS)` so the package still resolves on Linux.
        .target(name: "TapeloopAudio", dependencies: ["TapeloopCore"]),
        .target(name: "TapeloopExport", dependencies: ["TapeloopCore"]),
        .target(name: "TapeloopIntelligence", dependencies: ["TapeloopCore"]),
        .target(name: "TapeloopUI", dependencies: ["TapeloopCore"]),
        .executableTarget(
            name: "Tapeloop",
            dependencies: [
                "TapeloopCore", "TapeloopAudio", "TapeloopExport", "TapeloopIntelligence", "TapeloopUI",
            ] + appDependencies
        ),
        .executableTarget(name: "TapeloopSnapshots", dependencies: ["TapeloopCore", "TapeloopUI"]),
        // Stress, sponge and soak tests of the recording pipeline (a developer tool; see docs/TESTING.md).
        .executableTarget(
            name: "TapeloopBench",
            dependencies: [
                "TapeloopCore", "TapeloopAudio", "TapeloopExport", "TapeloopParakeet", "TapeloopIntelligence",
            ]),
        .testTarget(name: "TapeloopCoreTests", dependencies: ["TapeloopCore"]),
        .testTarget(name: "TapeloopAudioTests", dependencies: ["TapeloopCore", "TapeloopAudio", "TapeloopExport"]),
        .testTarget(name: "TapeloopIntelligenceTests", dependencies: ["TapeloopCore", "TapeloopIntelligence"]),
        .testTarget(name: "TapeloopUITests", dependencies: ["TapeloopCore", "TapeloopUI"]),
    ] + targets,
    swiftLanguageModes: [.v6]
)
