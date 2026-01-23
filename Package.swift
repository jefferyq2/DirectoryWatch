// swift-tools-version: 5.9
// MIT License
// Copyright (c) 2026 Marcin Krzyzanowski

import PackageDescription

let package = Package(
    name: "DirectoryWatch",
    platforms: [
        .macOS("15.0"),
        .iOS("18.0"),
        .tvOS("18.0"),
        .watchOS("11.0"),
        .visionOS("2.0"),
    ],
    products: [
        .library(name: "DirectoryWatch", targets: ["DirectoryWatch"]),
    ],
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/KQueue.git", from: "1.1.0")
    ],
    targets: [
        .target(name: "DirectoryWatch", dependencies: ["KQueue"]),
        .testTarget(name: "DirectoryWatchTests", dependencies: ["DirectoryWatch"]),
    ]
)
