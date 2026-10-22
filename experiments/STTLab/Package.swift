// swift-tools-version: 6.0
// Using 6.0 (not 6.2) because argmax-oss-swift v1.0.0 requires swift-tools-version 6.0.
// Phase 1: STTLabCore only. Later phases add STTLabHome, STTLabAnalysis, sttlab CLI,
// and STTLabRunner with their dependencies (argmax, Transcription, BiscottiKit, ArgumentParser).

import PackageDescription

let package = Package(
    name: "STTLab",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "STTLabCore", targets: ["STTLabCore"])
    ],
    targets: [
        .target(
            name: "STTLabCore",
            path: "Sources/STTLabCore"
        ),
        .testTarget(
            name: "STTLabCoreTests",
            dependencies: ["STTLabCore"],
            path: "Tests/STTLabCoreTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
