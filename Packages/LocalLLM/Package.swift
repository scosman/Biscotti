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
        // Upper-bounded on purpose: llama.swift version numbers track llama.cpp
        // build numbers, and the C API is not stable across them. 2.10545.0
        // (llama.cpp b10545) added an `n_vocab` parameter to
        // llama_sampler_init_penalties, which fails to compile against
        // Sampling.swift. `.upToNextMajor` let the app target resolve to it —
        // Package.resolved keeps `swift build` on a working version, but the
        // generated Xcode project has no checked-in resolution, so `make
        // build-app` broke on any fresh checkout. Raise the bound once the
        // sampler call has been updated for the newer signature.
        .package(url: "https://github.com/mattt/llama.swift", "2.9601.0" ..< "2.9734.0"),
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
