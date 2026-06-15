// swift-tools-version: 6.0
// LlamaSwift requires swift-tools-version 6.0. Swift 6 strict concurrency on.

import PackageDescription

let package = Package(
    name: "LocalLLM",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "LocalLLM", targets: ["LocalLLM"]),
        // Binary ships as "localllm". The target name is "llm-cli" (not "localllm")
        // to avoid an APFS case-insensitive collision with the "LocalLLM" library
        // target's Sources/LocalLLM directory.
        .executable(name: "localllm", targets: ["llm-cli"])
    ],
    dependencies: [
        .package(url: "https://github.com/mattt/llama.swift", .upToNextMajor(from: "2.9601.0")),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "LocalLLM",
            dependencies: [
                .product(name: "LlamaSwift", package: "llama.swift")
            ],
            path: "Sources/LocalLLM",
            swiftSettings: warningsAsErrors
        ),
        .executableTarget(
            name: "llm-cli",
            dependencies: [
                "LocalLLM",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/CLI",
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "LocalLLMTests",
            dependencies: ["LocalLLM"],
            path: "Tests/LocalLLMTests",
            resources: [.copy("Fixtures"), .copy("Prompts")],
            swiftSettings: warningsAsErrors
        )
    ],
    swiftLanguageModes: [.v6]
)

/// Applied to every target so the whole package is held to the strict bar.
/// Uses the `-warnings-as-errors` flag rather than the 6.2-only `treatAllWarnings(as:)`
/// API so the manifest stays buildable on Swift 6.0+ toolchains. The `unsafeFlags`
/// dependency restriction doesn't apply: the app consumes LocalLLM as a local
/// path dependency, which is exempt.
let warningsAsErrors: [SwiftSetting] = [.unsafeFlags(["-warnings-as-errors"])]
