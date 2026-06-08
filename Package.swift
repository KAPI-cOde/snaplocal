// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SnapLocal",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "SnapLocal",
            targets: ["SnapLocalApp"]),
    ],
    targets: [
        .executableTarget(
            name: "SnapLocalApp",
            path: "Sources/SnapLocalApp",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]),
        .testTarget(
            name: "SnapLocalTests",
            dependencies: [],
            path: "Tests/SnapLocalTests"),
    ]
)
