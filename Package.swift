// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TaskTick",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
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
            name: "TaskTickApp",
            dependencies: ["TaskTickCore"],
            path: "Sources",
            exclude: ["TaskTickCore", "CLI"]
        ),
        .executableTarget(
            name: "tasktick",
            dependencies: [
                "TaskTickCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/CLI"
        ),
        .testTarget(
            name: "TaskTickTests",
            dependencies: ["TaskTickApp", "TaskTickCore"],
            path: "Tests/AppTests"
        ),
        .testTarget(
            name: "CLITests",
            dependencies: ["tasktick", "TaskTickCore"],
            path: "Tests/CLITests"
        )
    ]
)
