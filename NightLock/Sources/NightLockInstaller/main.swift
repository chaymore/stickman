import Darwin
import Foundation
import NightLockCore
import Security

enum InstallerError: LocalizedError {
    case mustRunAsRoot
    case appNotInstalled
    case randomGenerationFailed

    var errorDescription: String? {
        switch self {
        case .mustRunAsRoot: return "NightLockInstaller must run as root."
        case .appNotInstalled: return "Install NightLock.app in /Applications before running the installer."
        case .randomGenerationFailed: return "Could not generate secure recovery material."
        }
    }
}

final class NightLockInstaller {
    private let fileManager = FileManager.default

    func install() throws {
        guard geteuid() == 0 else { throw InstallerError.mustRunAsRoot }
        guard fileManager.fileExists(atPath: NightLockPaths.installedApp) else { throw InstallerError.appNotInstalled }

        try createDirectories()
        try installConfigurationIfNeeded()
        try installDaemonExecutable()
        try installLaunchPlists()
        restartServices()
        print("NightLock installation complete.")
    }

    private func createDirectories() throws {
        try createDirectory(NightLockPaths.supportDirectory, mode: 0o755)
        try createDirectory(NightLockPaths.requests, mode: 0o733)
        try createDirectory((NightLockPaths.recoveryPartOne as NSString).deletingLastPathComponent, mode: 0o700)
        try createDirectory((NightLockPaths.recoveryPartTwo as NSString).deletingLastPathComponent, mode: 0o700)
        try createDirectory((NightLockPaths.daemonExecutable as NSString).deletingLastPathComponent, mode: 0o755)
    }

    private func createDirectory(_ path: String, mode: mode_t) throws {
        try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
        chmod(path, mode)
    }

    private func installConfigurationIfNeeded() throws {
        if fileManager.fileExists(atPath: NightLockPaths.config) {
            var config = try NightLockFiles.loadConfig()
            config.blockedDomains = merged(config.blockedDomains, NightLockConfig.defaultDomains)
            config.blockedHosts = merged(config.blockedHosts, NightLockConfig.defaultHosts)
            try write(NightLockFiles.encoder.encode(config), to: NightLockPaths.config, mode: 0o644)
            return
        }

        let recoveryKey = try randomHex(byteCount: 32)
        let salt = try randomHex(byteCount: 16)
        let midpoint = recoveryKey.index(recoveryKey.startIndex, offsetBy: recoveryKey.count / 2)
        let partOne = String(recoveryKey[..<midpoint])
        let partTwo = String(recoveryKey[midpoint...])
        let config = NightLockConfig(
            recoverySalt: salt,
            recoveryHash: RecoveryKeyVerifier.hash(key: recoveryKey, salt: salt)
        )

        try write(Data((partOne + "\n").utf8), to: NightLockPaths.recoveryPartOne, mode: 0o600)
        try write(Data((partTwo + "\n").utf8), to: NightLockPaths.recoveryPartTwo, mode: 0o600)
        try write(NightLockFiles.encoder.encode(config), to: NightLockPaths.config, mode: 0o644)
    }

    private func merged(_ existing: [String], _ required: [String]) -> [String] {
        var result = existing
        for value in required where !result.contains(value) {
            result.append(value)
        }
        return result
    }

    private func installDaemonExecutable() throws {
        let source = NightLockPaths.installedApp + "/Contents/MacOS/NightLockDaemon"
        if fileManager.fileExists(atPath: NightLockPaths.daemonExecutable) {
            try fileManager.removeItem(atPath: NightLockPaths.daemonExecutable)
        }
        try fileManager.copyItem(atPath: source, toPath: NightLockPaths.daemonExecutable)
        chmod(NightLockPaths.daemonExecutable, 0o755)
        chown(NightLockPaths.daemonExecutable, 0, 0)
    }

    private func installLaunchPlists() throws {
        let daemon: [String: Any] = [
            "Label": "com.chaymore.NightLock.daemon",
            "ProgramArguments": [NightLockPaths.daemonExecutable],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "ThrottleInterval": 5,
            "StandardOutPath": "/var/log/nightlock.log",
            "StandardErrorPath": "/var/log/nightlock.log",
        ]
        let agent: [String: Any] = [
            "Label": "com.chaymore.NightLock.agent",
            "ProgramArguments": [NightLockPaths.installedApp + "/Contents/MacOS/NightLock"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "LimitLoadToSessionType": "Aqua",
            "ThrottleInterval": 5,
        ]

        try writePlist(daemon, to: NightLockPaths.daemonPlist)
        try writePlist(agent, to: NightLockPaths.agentPlist)
    }

    private func writePlist(_ value: [String: Any], to path: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        try write(data, to: path, mode: 0o644)
    }

    private func write(_ data: Data, to path: String, mode: mode_t) throws {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        chmod(path, mode)
        chown(path, 0, 0)
    }

    private func randomHex(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            throw InstallerError.randomGenerationFailed
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func restartServices() {
        runLaunchctl(["bootout", "system/com.chaymore.NightLock.daemon"])
        runLaunchctl(["bootstrap", "system", NightLockPaths.daemonPlist])
        runLaunchctl(["kickstart", "-k", "system/com.chaymore.NightLock.daemon"])

        let uid = consoleUserID()
        if uid > 0 {
            let domain = "gui/\(uid)"
            runLaunchctl(["bootout", "\(domain)/com.chaymore.NightLock.agent"])
            runLaunchctl(["bootstrap", domain, NightLockPaths.agentPlist])
            runLaunchctl(["kickstart", "-k", "\(domain)/com.chaymore.NightLock.agent"])
        }
    }

    private func consoleUserID() -> uid_t {
        let attributes = try? fileManager.attributesOfItem(atPath: "/dev/console")
        return (attributes?[.ownerAccountID] as? NSNumber)?.uint32Value ?? 0
    }

    private func runLaunchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

do {
    try NightLockInstaller().install()
} catch {
    fputs("NightLock install failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
