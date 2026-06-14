// swift-tools-version: 6.0
// LlamaSwift requires swift-tools-version 6.0. Swift 6 strict concurrency on.

import PackageDescription

let package = Package(
    name: "LocalLLM",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "LocalLLM", targets: ["LocalLLM"]),
        // Binary ships as "localllm" per spec (architecture §1, §8). The target name is
        // "llm-cli" (not "localllm") to avoid an APFS case-insensitive collision with the
        // "LocalLLM" library target's Sources/LocalLLM directory. SPM allows the product
        // name to differ from the target name.
        .executable(name: "localllm", targets: ["llm-cli"]),
        // Service binary for out-of-process LLM hosting. Spawned by RemoteBackend;
        // speaks the framed-JSON wire protocol over stdin/stdout pipes.
        .executable(name: "localllm-service", targets: ["llm-service"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mattt/llama.swift", .upToNextMajor(from: "2.9601.0")),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "LocalLLM",
            dependencies: [
                .product(name: "LlamaSwift", package: "llama.swift"),
            ],
            path: "Sources/LocalLLM"
        ),
        .executableTarget(
            name: "llm-cli",
            dependencies: [
                "LocalLLM",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/CLI"
        ),
        .executableTarget(
            name: "llm-service",
            dependencies: ["LocalLLM"],
            path: "Sources/Service"
        ),
        .testTarget(
            name: "LocalLLMTests",
            dependencies: ["LocalLLM"],
            path: "Tests/LocalLLMTests"
        ),
    ]
)
