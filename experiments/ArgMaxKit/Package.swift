// swift-tools-version: 6.0
// Using 6.0 (not 6.2) because argmax-oss-swift v1.0.0 requires swift-tools-version 6.0.
// Strict concurrency is enabled by default with Swift 6 language mode.

import PackageDescription

let package = Package(
    name: "ArgMaxKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "ArgMaxKit", targets: ["ArgMaxKit"]),
        .executable(name: "argmaxkit-cli", targets: ["argmaxkit-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "ArgMaxKit",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/ArgMaxKit"
        ),
        .executableTarget(
            name: "argmaxkit-cli",
            dependencies: [
                "ArgMaxKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/argmaxkit-cli"
        ),
        .testTarget(
            name: "ArgMaxKitTests",
            dependencies: ["ArgMaxKit"],
            path: "Tests/ArgMaxKitTests"
        ),
    ]
)
