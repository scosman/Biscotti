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
        .library(name: "AppLinks", targets: ["AppLinks"]),
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
        .library(name: "MarkdownEditorUI", targets: ["MarkdownEditorUI"]),
        .library(name: "Intelligence", targets: ["Intelligence"]),
        .library(name: "ModelManagementUI", targets: ["ModelManagementUI"]),
        .library(name: "SummaryPromptUI", targets: ["SummaryPromptUI"]),
        .library(name: "Vocabulary", targets: ["Vocabulary"]),
        .library(name: "MCPServer", targets: ["MCPServer"])
    ],
    dependencies: [
        .package(name: "Transcription", path: "../Transcription"),
        .package(name: "AudioCapture", path: "../AudioCapture"),
        .package(name: "LocalLLM", path: "../LocalLLM"),
        .package(url: "https://github.com/nodes-app/swift-markdown-engine", from: "0.7.1"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.65.0"),
        // MCP swift-sdk — version decided by the Phase 1 spike (architecture §2.1):
        // 0.12.1 resolved and built cleanly (its swift-docc-plugin `branch: "main"`
        // dependency did not trip resolution), so the 0.11.0 fallback was not needed.
        // Pinned exact: pre-1.0 protocol implementation, upgrades are deliberate.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1")
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
            dependencies: [
                "DataStore"
            ],
            resources: [.process("Resources")],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "DesignSystemTests",
            dependencies: ["DesignSystem", "DataStore"],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "Permissions",
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "PermissionsTests",
            dependencies: ["Permissions", "BiscottiTestSupport"],
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
                "Vocabulary",
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
                "Vocabulary",
                .product(name: "Transcription", package: "Transcription")
            ],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "AppLinks",
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "AppLinksTests",
            dependencies: ["AppLinks"],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "AppCore",
            dependencies: [
                "AppLinks",
                "DataStore",
                "Intelligence",
                "MCPServer",
                "Permissions",
                "Recording",
                "TranscriptionService",
                "Vocabulary",
                "Calendar",
                "MeetingCatalog",
                "MeetingDetection",
                "Notifications",
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "LocalLLM", package: "LocalLLM"),
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
                "Intelligence",
                "MCPServer",
                "MeetingCatalog",
                "MeetingDetection",
                "Notifications",
                "Permissions",
                "Recording",
                "TranscriptionService",
                "Vocabulary",
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "LocalLLM", package: "LocalLLM"),
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
                "Intelligence",
                "MCPServer",
                "MeetingCatalog",
                "MeetingDetailUI",
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
                "Calendar",
                "DataStore",
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
                "Calendar",
                "DataStore",
                "MeetingDetection",
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
                "AppLinks",
                "Calendar",
                "DataStore",
                "DesignSystem",
                "Intelligence",
                "MarkdownEditorUI",
                "SummaryPromptUI",
                "TranscriptionService",
                "Vocabulary"
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
                "Intelligence",
                "MeetingCatalog",
                "Permissions",
                "Recording",
                "TranscriptionService",
                "Vocabulary",
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "LocalLLM", package: "LocalLLM"),
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
                "DataStore",
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
                "Intelligence",
                "LocalLLM",
                "MCPServer",
                "ModelManagementUI",
                "Permissions",
                "SummaryPromptUI",
                "Vocabulary"
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
                "Intelligence",
                "MCPServer",
                "MeetingCatalog",
                "MeetingDetection",
                "Notifications",
                "Permissions",
                "Recording",
                "TranscriptionService",
                "Vocabulary",
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
                "Intelligence",
                "ModelManagementUI",
                "Permissions",
                "TranscriptionService",
                .product(name: "LocalLLM", package: "LocalLLM")
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
                "Intelligence",
                "MeetingCatalog",
                "Permissions",
                "Recording",
                "TranscriptionService",
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "LocalLLM", package: "LocalLLM"),
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
        .target(
            name: "Intelligence",
            dependencies: [
                "DataStore",
                .product(name: "LocalLLM", package: "LocalLLM")
            ],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "IntelligenceTests",
            dependencies: [
                "Intelligence",
                "DataStore",
                .product(name: "LocalLLM", package: "LocalLLM"),
                .product(name: "Transcription", package: "Transcription")
            ],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "ModelManagementUI",
            dependencies: [
                "AppCore",
                "DesignSystem",
                "Intelligence",
                .product(name: "LocalLLM", package: "LocalLLM")
            ],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "ModelManagementUITests",
            dependencies: [
                "ModelManagementUI",
                "AppCore",
                "BiscottiTestSupport",
                "Intelligence",
                .product(name: "LocalLLM", package: "LocalLLM")
            ],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "SummaryPromptUI",
            dependencies: [
                "DesignSystem",
                "MarkdownEditorUI"
            ],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "SummaryPromptUITests",
            dependencies: [
                "SummaryPromptUI"
            ],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "Vocabulary",
            dependencies: ["DataStore"],
            resources: [.process("Resources")],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "VocabularyTests",
            dependencies: ["Vocabulary", "DataStore"],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "MCPServer",
            dependencies: [
                "AppLinks",
                "DataStore",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio")
            ],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "MCPServerTests",
            dependencies: [
                "MCPServer",
                "DataStore",
                .product(name: "Transcription", package: "Transcription")
            ],
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
