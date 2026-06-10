// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "AudioCapture",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AudioCapture", targets: ["AudioCapture"])
    ],
    targets: [
        .target(
            name: "AudioCapture",
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "AudioCaptureTests",
            dependencies: ["AudioCapture"],
            swiftSettings: warningsAsErrors
        )
    ],
    swiftLanguageModes: [.v6]
)

/// Applied to every target so the whole package is held to the strict bar.
/// Uses the `-warnings-as-errors` flag rather than the 6.2-only `treatAllWarnings(as:)`
/// API so the manifest stays buildable on Swift 6.1+ toolchains (e.g. the stock macos-15
/// CI runner). The `unsafeFlags` dependency restriction doesn't apply: the app consumes
/// AudioCapture as a local path dependency, which is exempt.
let warningsAsErrors: [SwiftSetting] = [.unsafeFlags(["-warnings-as-errors"])]
