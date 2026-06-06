// swift-tools-version: 6.0
// Using 6.0 (not 6.2) because argmax-oss-swift v1.0.0 requires swift-tools-version 6.0.
// Strict concurrency is enabled by default with Swift 6 language mode.

import PackageDescription

let package = Package(
    name: "Transcription",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "Transcription", targets: ["Transcription"]),
        .executable(name: "transcribe-cli", targets: ["transcribe-cli"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "Transcription",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift")
            ],
            path: "Sources/Transcription",
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
                "transcribe-cli"
            ],
            path: "Tests/TranscriptionTests",
            resources: [.copy("Fixtures")],
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
