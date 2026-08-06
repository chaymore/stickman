// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Stickman",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .executable(name: "Stickman", targets: ["Stickman"]),
    ],
    targets: [
        .executableTarget(
            name: "Stickman",
            path: "Sources"),
        .testTarget(
            name: "StickmanTests",
            dependencies: ["Stickman"],
            path: "Tests/StickmanTests"),
    ],
    swiftLanguageVersions: [.v5]
)
