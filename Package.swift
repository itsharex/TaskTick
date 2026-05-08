// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TaskTick",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "TaskTickCore",
            path: "Sources/TaskTickCore",
            resources: [
                .process("Localization")
            ]
        ),
        .executableTarget(
            name: "TaskTick",
            dependencies: ["TaskTickCore"],
            path: "Sources",
            exclude: ["TaskTickCore", "CLI"]
        ),
        .testTarget(
            name: "TaskTickTests",
            dependencies: ["TaskTick", "TaskTickCore"],
            path: "Tests"
        )
    ]
)
