// swift-tools-version: 6.0
// Strict concurrency is enabled by default with Swift 6 language mode.

import PackageDescription

let package = Package(
    name: "Transcription",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "Transcription", targets: ["Transcription"]),
        .library(name: "LiveTranscriptModel", targets: ["LiveTranscriptModel"]),
        .library(name: "LiveTranscription", targets: ["LiveTranscription"]),
        .library(name: "TranscriberWorker", targets: ["TranscriberWorker"]),
        .executable(name: "transcribe-cli", targets: ["transcribe-cli"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "LiveTranscriptModel",
            path: "Sources/LiveTranscriptModel",
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "LiveTranscription",
            dependencies: [
                "LiveTranscriptModel",
                "Transcription",
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            path: "Sources/LiveTranscription",
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "Transcription",
            dependencies: [
                "LiveTranscriptModel",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift")
            ],
            path: "Sources/Transcription",
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "TranscriberWorker",
            dependencies: [
                "LiveTranscription",
                "LiveTranscriptModel",
                "Transcription"
            ],
            path: "Sources/TranscriberWorker",
            swiftSettings: warningsAsErrors
        ),
        .executableTarget(
            name: "transcribe-cli",
            dependencies: [
                "Transcription",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/transcribe-cli",
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "TranscriptionTests",
            dependencies: [
                "Transcription",
                "LiveTranscriptModel",
                "transcribe-cli",
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            path: "Tests/TranscriptionTests",
            resources: [.copy("Fixtures")],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "LiveTranscriptModelTests",
            dependencies: ["LiveTranscriptModel"],
            path: "Tests/LiveTranscriptModelTests",
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "LiveTranscriptionTests",
            dependencies: [
                "LiveTranscription",
                "LiveTranscriptModel",
                "Transcription",
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            path: "Tests/LiveTranscriptionTests",
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "TranscriberWorkerTests",
            dependencies: [
                "TranscriberWorker",
                "LiveTranscription",
                "LiveTranscriptModel",
                "Transcription"
            ],
            path: "Tests/TranscriberWorkerTests",
            swiftSettings: warningsAsErrors
        )
    ],
    swiftLanguageModes: [.v6]
)

/// Applied to every target so the whole package is held to the strict bar.
/// Uses the `-warnings-as-errors` flag rather than the 6.2-only `treatAllWarnings(as:)`
/// API so the manifest stays buildable on Swift 6.0+ toolchains. The `unsafeFlags`
/// dependency restriction doesn't apply: the app consumes Transcription as a local
/// path dependency, which is exempt.
let warningsAsErrors: [SwiftSetting] = [.unsafeFlags(["-warnings-as-errors"])]
