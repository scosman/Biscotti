// swift-tools-version: 6.0
// Using 6.0 (not 6.2) because argmax-oss-swift v1.0.0 requires swift-tools-version 6.0.

import PackageDescription

let package = Package(
    name: "STTLab",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "STTLabCore", targets: ["STTLabCore"]),
        .library(name: "STTLabHome", targets: ["STTLabHome"]),
        .library(name: "STTLabAnalysis", targets: ["STTLabAnalysis"]),
        .executable(name: "sttlab", targets: ["sttlab"]),
        .executable(name: "STTLabRunner", targets: ["STTLabRunner"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.0.0"),
        .package(name: "Transcription", path: "../../Packages/Transcription"),
        .package(name: "BiscottiKit", path: "../../Packages/BiscottiKit"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "STTLabCore",
            path: "Sources/STTLabCore"
        ),
        .target(
            name: "STTLabHome",
            dependencies: [
                "STTLabCore",
                .product(name: "Transcription", package: "Transcription"),
                .product(name: "DataStore", package: "BiscottiKit"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift")
            ],
            path: "Sources/STTLabHome"
        ),
        .target(
            name: "STTLabAnalysis",
            dependencies: ["STTLabCore"],
            path: "Sources/STTLabAnalysis"
        ),
        .executableTarget(
            name: "sttlab",
            dependencies: [
                "STTLabHome",
                "STTLabAnalysis",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/sttlab"
        ),
        .executableTarget(
            name: "STTLabRunner",
            dependencies: ["STTLabCore"],
            path: "Sources/STTLabRunner"
        ),
        .testTarget(
            name: "STTLabCoreTests",
            dependencies: ["STTLabCore"],
            path: "Tests/STTLabCoreTests"
        ),
        .testTarget(
            name: "STTLabHomeTests",
            dependencies: ["STTLabHome", "STTLabCore"],
            path: "Tests/STTLabHomeTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
