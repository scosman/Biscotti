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
        .library(name: "Calendar", targets: ["Calendar"]),
        .library(name: "MeetingCatalog", targets: ["MeetingCatalog"]),
        .library(name: "MeetingDetection", targets: ["MeetingDetection"]),
        .library(name: "Notifications", targets: ["Notifications"]),
        .library(name: "SettingsUI", targets: ["SettingsUI"]),
        .library(name: "MenuBarUI", targets: ["MenuBarUI"]),
        .library(name: "HomeUI", targets: ["HomeUI"]),
        .library(name: "OnboardingUI", targets: ["OnboardingUI"]),
        .library(name: "ManualTestKit", targets: ["ManualTestKit"]),
        .library(name: "MarkdownEditorUI", targets: ["MarkdownEditorUI"])
    ],
    dependencies: [
        .package(name: "Transcription", path: "../Transcription"),
        .package(name: "AudioCapture", path: "../AudioCapture"),
        .package(url: "https://github.com/nodes-app/swift-markdown-engine", exact: "0.7.0")
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
            resources: [.process("Resources")],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "DesignSystemTests",
            dependencies: ["DesignSystem"],
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
                "Calendar",
                "MeetingCatalog",
                "MeetingDetection",
                "Notifications",
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
                "Calendar",
                "DataStore",
                "MeetingCatalog",
                "MeetingDetection",
                "Notifications",
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
                "Calendar",
                "DataStore",
                "DesignSystem",
                "MeetingCatalog",
                "MeetingDetection",
                "Notifications",
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
                "Calendar",
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
                "Calendar",
                "DataStore",
                "MeetingCatalog",
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
                "Calendar",
                "DataStore",
                "DesignSystem",
                "MarkdownEditorUI",
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
                "Calendar",
                "DataStore",
                "MeetingCatalog",
                "Permissions",
                "Recording",
                "TranscriptionService",
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "Transcription", package: "Transcription")
            ],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "HomeUI",
            dependencies: [
                "AppCore",
                "Calendar",
                "DataStore",
                "DesignSystem"
            ],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "HomeUITests",
            dependencies: [
                "HomeUI",
                "AppCore",
                "BiscottiTestSupport",
                "Calendar",
                "DataStore",
                "MeetingCatalog",
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
                "Calendar",
                "DesignSystem",
                "HomeUI",
                "MeetingListUI",
                "MeetingDetailUI",
                "OnboardingUI",
                "RecordingUI",
                "SettingsUI"
            ],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "AppShellUITests",
            dependencies: [
                "AppShellUI",
                "AppCore",
                "BiscottiTestSupport",
                "Calendar",
                "DataStore",
                "HomeUI",
                "MeetingCatalog",
                "Permissions",
                "Recording",
                "TranscriptionService",
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "Transcription", package: "Transcription")
            ],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "Calendar",
            dependencies: [
                "DataStore",
                "MeetingCatalog"
            ],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "CalendarTests",
            dependencies: [
                "Calendar",
                "DataStore",
                "MeetingCatalog"
            ],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "SettingsUI",
            dependencies: [
                "AppCore",
                "Calendar",
                "DataStore",
                "DesignSystem",
                "Permissions"
            ],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "SettingsUITests",
            dependencies: [
                "SettingsUI",
                "AppCore",
                "BiscottiTestSupport",
                "Calendar",
                "DataStore",
                "MeetingCatalog",
                "Permissions",
                "Recording",
                "TranscriptionService",
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "Transcription", package: "Transcription")
            ],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "MenuBarUI",
            dependencies: [
                "AppCore",
                "Calendar",
                "DataStore",
                "DesignSystem"
            ],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "MenuBarUITests",
            dependencies: [
                "MenuBarUI",
                "AppCore",
                "BiscottiTestSupport",
                "Calendar",
                "DataStore",
                "MeetingCatalog",
                "MeetingDetection",
                "Notifications",
                "Permissions",
                "Recording",
                "TranscriptionService",
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "Transcription", package: "Transcription")
            ],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "OnboardingUI",
            dependencies: [
                "AppCore",
                "Calendar",
                "DataStore",
                "DesignSystem",
                "Permissions",
                "TranscriptionService"
            ],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "OnboardingUITests",
            dependencies: [
                "OnboardingUI",
                "AppCore",
                "BiscottiTestSupport",
                "Calendar",
                "DataStore",
                "MeetingCatalog",
                "Permissions",
                "Recording",
                "TranscriptionService",
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "Transcription", package: "Transcription")
            ],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "MeetingCatalog",
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "MeetingCatalogTests",
            dependencies: ["MeetingCatalog"],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "MeetingDetection",
            dependencies: [
                "MeetingCatalog",
                .product(name: "AudioCapture", package: "AudioCapture")
            ],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "MeetingDetectionTests",
            dependencies: [
                "MeetingDetection",
                "MeetingCatalog",
                .product(name: "AudioCapture", package: "AudioCapture")
            ],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "Notifications",
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "NotificationsTests",
            dependencies: ["Notifications"],
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
        .target(
            name: "MarkdownEditorUI",
            dependencies: [
                "DesignSystem",
                .product(name: "MarkdownEngine", package: "swift-markdown-engine")
            ],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "MarkdownEditorUITests",
            dependencies: ["MarkdownEditorUI"],
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
