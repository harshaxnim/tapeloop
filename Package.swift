// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Rearview",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RearviewCore", targets: ["RearviewCore"]),
        .executable(name: "Rearview", targets: ["Rearview"]),
    ],
    targets: [
        // Pure Swift. Builds and tests on Linux too.
        .target(name: "RearviewCore"),
        // macOS-only modules. Their sources are wrapped in `#if os(macOS)` so the package still resolves on Linux.
        .target(name: "RearviewCapture", dependencies: ["RearviewCore"]),
        .target(name: "RearviewExport", dependencies: ["RearviewCore"]),
        .target(name: "RearviewIntelligence", dependencies: ["RearviewCore"]),
        .target(name: "RearviewUI", dependencies: ["RearviewCore"]),
        .executableTarget(
            name: "Rearview",
            dependencies: [
                "RearviewCore", "RearviewCapture", "RearviewExport", "RearviewIntelligence", "RearviewUI",
            ]
        ),
        .executableTarget(name: "RearviewSnapshots", dependencies: ["RearviewCore", "RearviewUI"]),
        .testTarget(name: "RearviewCoreTests", dependencies: ["RearviewCore"]),
    ],
    swiftLanguageModes: [.v6]
)
