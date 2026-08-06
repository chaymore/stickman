// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "NightLock",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "NightLockCore", targets: ["NightLockCore"]),
        .executable(name: "NightLock", targets: ["NightLockApp"]),
        .executable(name: "NightLockDaemon", targets: ["NightLockDaemon"]),
        .executable(name: "NightLockInstaller", targets: ["NightLockInstaller"]),
        .executable(name: "nightlock-recover", targets: ["NightLockRecover"]),
    ],
    targets: [
        .target(name: "NightLockCore"),
        .executableTarget(name: "NightLockApp", dependencies: ["NightLockCore"]),
        .executableTarget(name: "NightLockDaemon", dependencies: ["NightLockCore"]),
        .executableTarget(name: "NightLockInstaller", dependencies: ["NightLockCore"]),
        .executableTarget(name: "NightLockRecover", dependencies: ["NightLockCore"]),
        .testTarget(name: "NightLockCoreTests", dependencies: ["NightLockCore"]),
    ]
)
