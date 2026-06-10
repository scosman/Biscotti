// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "BiscottiKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BiscottiKit", targets: ["BiscottiKit"]),
        .library(name: "DataStore", targets: ["DataStore"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "Permissions", targets: ["Permissions"]),
        .library(name: "Recording", targets: ["Recording"]),
        .library(name: "TranscriptionService", targets: ["TranscriptionService"]),
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "MeetingListUI", targets: ["MeetingListUI"]),
        .library(name: "RecordingUI", targets: ["RecordingUI"]),
        .library(name: "MeetingDetailUI", targets: ["MeetingDetailUI"]),
        .library(name: "AppShellUI", targets: ["AppShellUI"]),
        .library(name: "ManualTestKit", targets: ["ManualTestKit"])
    ],
    dependencies: [
        .package(name: "Transcription", path: "../Transcription"),
        .package(name: "AudioCapture", path: "../AudioCapture")
    ],
    targets: [
        .target(
            name: "BiscottiKit",
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "BiscottiKitTests",
            dependencies: ["BiscottiKit"],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "DataStore",
            dependencies: [
                .product(name: "Transcription", package: "Transcription")
            ],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "DataStoreTests",
            dependencies: ["DataStore", .product(name: "Transcription", package: "Transcription")],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "DesignSystem",
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "Permissions",
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "PermissionsTests",
            dependencies: ["Permissions"],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "Recording",
            dependencies: [
                "DataStore",
                "Permissions",
                .product(name: "AudioCapture", package: "AudioCapture")
            ],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "RecordingTests",
            dependencies: [
                "Recording",
                "BiscottiTestSupport",
                "DataStore",
                "Permissions",
                .product(name: "AudioCapture", package: "AudioCapture")
            ],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "TranscriptionService",
            dependencies: [
                "DataStore",
                .product(name: "Transcription", package: "Transcription")
            ],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "TranscriptionServiceTests",
            dependencies: [
                "TranscriptionService",
                "BiscottiTestSupport",
                "DataStore",
                .product(name: "Transcription", package: "Transcription")
            ],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "AppCore",
            dependencies: [
                "DataStore",
                "Permissions",
                "Recording",
                "TranscriptionService",
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "Transcription", package: "Transcription")
            ],
            swiftSettings: warningsAsErrors
        ),
        // BiscottiTestSupport is a plain .target (not .testTarget) because SPM does not allow
        // a .testTarget to be listed as a dependency of another .testTarget. Multiple test
        // targets share these fakes, so it must be a regular target. It is intentionally
        // excluded from `products` so it never ships.
        .target(
            name: "BiscottiTestSupport",
            dependencies: [
                "AppCore",
                "DataStore",
                "Permissions",
                "Recording",
                "TranscriptionService",
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "Transcription", package: "Transcription")
            ],
            path: "Tests/BiscottiTestSupport",
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: [
                "AppCore",
                "BiscottiTestSupport",
                "DataStore",
                "Permissions",
                "Recording",
                "TranscriptionService",
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "Transcription", package: "Transcription")
            ],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "MeetingListUI",
            dependencies: [
                "AppCore",
                "DataStore",
                "DesignSystem"
            ],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "MeetingListUITests",
            dependencies: [
                "MeetingListUI",
                "AppCore",
                "BiscottiTestSupport",
                "DataStore",
                "Permissions",
                "Recording",
                "TranscriptionService",
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "Transcription", package: "Transcription")
            ],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "RecordingUI",
            dependencies: [
                "AppCore",
                "DesignSystem",
                "Permissions",
                "Recording"
            ],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "RecordingUITests",
            dependencies: [
                "RecordingUI",
                "AppCore",
                "BiscottiTestSupport",
                "DataStore",
                "Permissions",
                "Recording",
                "TranscriptionService",
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "Transcription", package: "Transcription")
            ],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "MeetingDetailUI",
            dependencies: [
                "AppCore",
                "DataStore",
                "DesignSystem",
                "TranscriptionService"
            ],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "MeetingDetailUITests",
            dependencies: [
                "MeetingDetailUI",
                "AppCore",
                "BiscottiTestSupport",
                "DataStore",
                "Permissions",
                "Recording",
                "TranscriptionService",
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "Transcription", package: "Transcription")
            ],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "AppShellUI",
            dependencies: [
                "AppCore",
                "DesignSystem",
                "MeetingListUI",
                "RecordingUI",
                "MeetingDetailUI"
            ],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "AppShellUITests",
            dependencies: [
                "AppShellUI",
                "AppCore",
                "BiscottiTestSupport",
                "DataStore",
                "Permissions",
                "Recording",
                "TranscriptionService",
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "Transcription", package: "Transcription")
            ],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "ManualTestKit",
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "ManualTestKitTests",
            dependencies: ["ManualTestKit"],
            swiftSettings: warningsAsErrors
        ),
        .executableTarget(
            name: "manual-tests-check",
            dependencies: ["ManualTestKit"],
            swiftSettings: warningsAsErrors
        )
    ],
    swiftLanguageModes: [.v6]
)

/// Applied to every target so the whole package is held to the strict bar.
/// Uses the `-warnings-as-errors` flag rather than the 6.2-only `treatAllWarnings(as:)`
/// API so the manifest stays buildable on Swift 6.1+ toolchains (e.g. the stock macos-15
/// CI runner). The `unsafeFlags` dependency restriction doesn't apply: the app consumes
/// BiscottiKit as a local path dependency, which is exempt.
let warningsAsErrors: [SwiftSetting] = [.unsafeFlags(["-warnings-as-errors"])]
