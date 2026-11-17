// swift-tools-version:6.0
import PackageDescription

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
            ]
        ),
        .executableTarget(name: "TapeloopSnapshots", dependencies: ["TapeloopCore", "TapeloopUI"]),
        .testTarget(name: "TapeloopCoreTests", dependencies: ["TapeloopCore"]),
        .testTarget(name: "TapeloopAudioTests", dependencies: ["TapeloopCore", "TapeloopAudio", "TapeloopExport"]),
    ],
    swiftLanguageModes: [.v6]
)
