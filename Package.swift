// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Stickman",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "Stickman", targets: ["Stickman"]),
        .executable(name: "StickmanBlockerDaemon", targets: ["StickmanBlockerDaemon"]),
        .executable(name: "StickmanBlockerInstaller", targets: ["StickmanBlockerInstaller"]),
        .executable(name: "stickman-blocker-recover", targets: ["StickmanBlockerRecover"]),
        .executable(name: "stickman-computer-use", targets: ["StickmanComputerUseMCP"]),
    ],
    targets: [
        // Shared policy, file formats, and paths for Stickman Blocker.
        .target(
            name: "NightLockCore",
            path: "Blocker/Sources/NightLockCore"),
        .executableTarget(
            name: "Stickman",
            dependencies: ["NightLockCore"],
            path: "Sources"),
        // Runs as root and enforces the block through /etc/hosts.
        .executableTarget(
            name: "StickmanBlockerDaemon",
            dependencies: ["NightLockCore"],
            path: "Blocker/Sources/StickmanBlockerDaemon"),
        .executableTarget(
            name: "StickmanBlockerInstaller",
            dependencies: ["NightLockCore"],
            path: "Blocker/Sources/StickmanBlockerInstaller"),
        .executableTarget(
            name: "StickmanBlockerRecover",
            dependencies: ["NightLockCore"],
            path: "Blocker/Sources/StickmanBlockerRecover"),
        // MCP server Claude Code launches; forwards computer-use tool calls to the running app.
        .executableTarget(
            name: "StickmanComputerUseMCP",
            path: "ComputerUse/Sources/StickmanComputerUseMCP"),
        .testTarget(
            name: "StickmanTests",
            dependencies: ["Stickman"],
            path: "Tests/StickmanTests"),
        .testTarget(
            name: "NightLockCoreTests",
            dependencies: ["NightLockCore"],
            path: "Blocker/Tests/NightLockCoreTests"),
    ],
    swiftLanguageVersions: [.v5]
)
