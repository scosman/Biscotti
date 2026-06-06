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
        .library(name: "Transcription", targets: ["Transcription"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0")
    ],
    targets: [
        // Note: Transcription has no target-level dependency on argmax-oss-swift yet.
        // The package dependency is pinned now; it will be linked to this target in
        // Phase 1.2 when the WhisperKit/SpeakerKit integration is built.
        .target(
            name: "Transcription",
            path: "Sources/Transcription",
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "TranscriptionTests",
            dependencies: ["Transcription"],
            path: "Tests/TranscriptionTests",
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
