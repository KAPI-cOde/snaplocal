// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SnapLocal",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "SnapLocalCore",
            targets: ["SnapLocalCore"]),
        .executable(
            name: "SnapLocal",
            targets: ["SnapLocalApp"]),
        .executable(
            name: "snaplocal",
            targets: ["SnapLocalCLI"]),
    ],
    dependencies: [
        // No external dependencies needed for core library
    ],
    targets: [
        .target(
            name: "SnapLocalCore",
            dependencies: [],
            path: "Sources/SnapLocalCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]),
        .executableTarget(
            name: "SnapLocalApp",
            dependencies: ["SnapLocalCore"],
            path: "Sources/SnapLocalApp",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]),
        .executableTarget(
            name: "SnapLocalCLI",
            dependencies: ["SnapLocalCore"],
            path: "Sources/SnapLocalCLI"),
        .testTarget(
            name: "SnapLocalTests",
            dependencies: ["SnapLocalCore"],
            path: "Tests/SnapLocalTests"),
    ]
)