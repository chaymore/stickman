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
        case .mustRunAsRoot: return "StickmanBlockerInstaller must run as root."
        case .appNotInstalled: return "Install Stickman.app in /Applications before running the installer."
        case .randomGenerationFailed: return "Could not generate secure recovery material."
        }
    }
}

final class NightLockInstaller {
    private let fileManager = FileManager.default

    func install() throws {
        guard geteuid() == 0 else { throw InstallerError.mustRunAsRoot }
        guard fileManager.fileExists(atPath: NightLockPaths.installedApp) else { throw InstallerError.appNotInstalled }

        removeLegacyServices()
        try createDirectories()
        try installConfigurationIfNeeded()
        try installDaemonExecutable()
        try installLaunchPlists()
        restartServices()
        removeLegacyApps()
        print("Stickman Blocker installation complete.")
    }

    private func removeLegacyServices() {
        let legacyIdentifier = "com.calebhaymore.NightLock"
        runLaunchctl(["bootout", "system/\(legacyIdentifier).daemon"])

        let uid = consoleUserID()
        if uid > 0 {
            runLaunchctl(["bootout", "gui/\(uid)/\(legacyIdentifier).agent"])
        }

        let obsoletePaths = [
            "/Library/LaunchDaemons/\(legacyIdentifier).daemon.plist",
            "/Library/LaunchAgents/\(legacyIdentifier).agent.plist",
            "/Library/PrivilegedHelperTools/\(legacyIdentifier).daemon",
        ]
        for path in obsoletePaths where fileManager.fileExists(atPath: path) {
            try? fileManager.removeItem(atPath: path)
        }
    }

    /// The blocker used to ship as NightLock.app, then Night Routine.app. It now lives in
    /// Stickman.app, and the login agent launches Stickman instead.
    private func removeLegacyApps() {
        for path in NightLockPaths.legacyInstalledApps where fileManager.fileExists(atPath: path) {
            try? fileManager.removeItem(atPath: path)
        }
    }

    private func createDirectories() throws {
        try createDirectory(NightLockPaths.supportDirectory, mode: 0o755)
        try createDirectory(NightLockPaths.requests, mode: 0o733)
        try createDirectory(NightLockPaths.allowanceRequests, mode: 0o733)
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
            if (config.policyVersion ?? 1) < 2 {
                config.enabled = true
                config.startHour = 0
                config.startMinute = 0
                config.endHour = 0
                config.endMinute = 0
                config.policyVersion = 2
            }
            if (config.policyVersion ?? 2) < 3 {
                config.dailyAllowanceMinutes = NightLockConfig.defaultDailyAllowanceMinutes
                config.policyVersion = 3
            }
            if (config.policyVersion ?? 3) < 4 {
                var allowances = config.dailyAllowanceMinutes ?? [:]
                allowances["youtube.com"] = 10
                config.dailyAllowanceMinutes = allowances
                config.policyVersion = 4
            }
            if (config.policyVersion ?? 4) < 5 {
                var allowances = config.dailyAllowanceMinutes ?? [:]
                allowances["linkedin.com"] = 10
                allowances["x.com"] = 10
                allowances["youtube.com"] = 10
                config.dailyAllowanceMinutes = allowances
                config.policyVersion = 5
            }
            if (config.policyVersion ?? 5) < 6 {
                var allowances = config.dailyAllowanceMinutes ?? [:]
                allowances["instagram.com"] = 10
                config.dailyAllowanceMinutes = allowances
                config.policyVersion = 6
            }
            if (config.policyVersion ?? 6) < 7 {
                config.blockedDomains.removeAll { NightLockFiles.normalizedDomain($0) == "linkedin.com" }
                config.blockedHosts.removeAll { host in
                    let normalized = NightLockFiles.normalizedDomain(host)
                    return normalized == "linkedin.com" || normalized.hasSuffix(".linkedin.com")
                }
                config.dailyAllowanceMinutes?.removeValue(forKey: "linkedin.com")
                config.policyVersion = 7
            }
            if (config.policyVersion ?? 7) < 8 {
                config.blockedDomains.removeAll { domain in
                    let normalized = NightLockFiles.normalizedDomain(domain)
                    return normalized == "x.com" || normalized == "twitter.com"
                }
                config.blockedHosts.removeAll { host in
                    let normalized = NightLockFiles.normalizedDomain(host)
                    return normalized == "x.com" || normalized.hasSuffix(".x.com")
                        || normalized == "twitter.com" || normalized.hasSuffix(".twitter.com")
                        || normalized == "t.co" || normalized.hasSuffix(".t.co")
                }
                config.dailyAllowanceMinutes?.removeValue(forKey: "x.com")
                config.policyVersion = 8
            }
            if (config.policyVersion ?? 8) < 9 {
                var allowances = config.dailyAllowanceMinutes ?? [:]
                allowances["instagram.com"] = 10
                allowances["x.com"] = 10
                allowances["youtube.com"] = 10
                config.dailyAllowanceMinutes = allowances
                config.siteAccessPolicies = NightLockConfig.defaultSiteAccessPolicies
                config.policyVersion = 9
            }
            if (config.policyVersion ?? 9) < 10 {
                var allowances = config.dailyAllowanceMinutes ?? [:]
                allowances["youtube.com"] = 45
                config.dailyAllowanceMinutes = allowances

                var policies = config.siteAccessPolicies ?? NightLockConfig.defaultSiteAccessPolicies
                policies["youtube.com"] = NightLockConfig.defaultSiteAccessPolicies["youtube.com"]
                config.siteAccessPolicies = policies
                config.policyVersion = 10
            }
            if (config.policyVersion ?? 10) < 11 {
                var allowances = config.dailyAllowanceMinutes ?? [:]
                allowances["facebook.com"] = 30
                config.dailyAllowanceMinutes = allowances

                var policies = config.siteAccessPolicies ?? NightLockConfig.defaultSiteAccessPolicies
                policies["facebook.com"] = NightLockConfig.defaultSiteAccessPolicies["facebook.com"]
                config.siteAccessPolicies = policies
                config.policyVersion = 11
            }
            if (config.policyVersion ?? 11) < 12 {
                var policies = config.siteAccessPolicies ?? NightLockConfig.defaultSiteAccessPolicies
                policies["youtube.com"] = NightLockConfig.defaultSiteAccessPolicies["youtube.com"]
                config.siteAccessPolicies = policies
                config.policyVersion = 12
            }
            if (config.policyVersion ?? 12) < 13 {
                config.blockedDomains.removeAll { domain in
                    let normalized = NightLockFiles.normalizedDomain(domain)
                    return normalized == "facebook.com" || normalized == "fb.com"
                }
                config.blockedHosts.removeAll { host in
                    let normalized = NightLockFiles.normalizedDomain(host)
                    return normalized == "facebook.com" || normalized.hasSuffix(".facebook.com")
                        || normalized == "fb.com" || normalized.hasSuffix(".fb.com")
                }
                config.dailyAllowanceMinutes?.removeValue(forKey: "facebook.com")
                config.siteAccessPolicies?.removeValue(forKey: "facebook.com")
                config.policyVersion = 13
            }
            if (config.policyVersion ?? 13) < 14 {
                var allowances = config.dailyAllowanceMinutes ?? [:]
                allowances["instagram.com"] = 30
                config.dailyAllowanceMinutes = allowances

                var policies = config.siteAccessPolicies ?? NightLockConfig.defaultSiteAccessPolicies
                policies["instagram.com"] = NightLockConfig.defaultSiteAccessPolicies["instagram.com"]
                config.siteAccessPolicies = policies
                config.policyVersion = 14
            }
            if (config.policyVersion ?? 14) < 15 {
                config.blockedDomains.removeAll { domain in
                    NightLockFiles.normalizedDomain(domain) == "youtube.com"
                }
                config.blockedHosts.removeAll { host in
                    let normalized = NightLockFiles.normalizedDomain(host)
                    return normalized == "youtube.com" || normalized.hasSuffix(".youtube.com")
                        || normalized == "youtu.be" || normalized.hasSuffix(".youtu.be")
                        || normalized == "youtube-nocookie.com" || normalized.hasSuffix(".youtube-nocookie.com")
                }
                config.dailyAllowanceMinutes?.removeValue(forKey: "youtube.com")
                config.siteAccessPolicies?.removeValue(forKey: "youtube.com")
                config.policyVersion = 15
            }
            if (config.policyVersion ?? 15) < 16 {
                // Night lock: X, YouTube and LinkedIn close at 10 PM and reopen at 8 AM.
                // Re-merge in case an older migration above stripped these hosts.
                config.blockedDomains = merged(config.blockedDomains, NightLockConfig.defaultDomains)
                config.blockedHosts = merged(config.blockedHosts, NightLockConfig.defaultHosts)
                var policies = config.siteAccessPolicies ?? NightLockConfig.defaultSiteAccessPolicies
                for domain in ["x.com", "youtube.com", "linkedin.com"] {
                    policies[domain] = NightLockConfig.defaultSiteAccessPolicies[domain]
                }
                config.siteAccessPolicies = policies
                config.policyVersion = 16
            }
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
        let source = NightLockPaths.bundledDaemon
        if fileManager.fileExists(atPath: NightLockPaths.daemonExecutable) {
            try fileManager.removeItem(atPath: NightLockPaths.daemonExecutable)
        }
        try fileManager.copyItem(atPath: source, toPath: NightLockPaths.daemonExecutable)
        chmod(NightLockPaths.daemonExecutable, 0o755)
        chown(NightLockPaths.daemonExecutable, 0, 0)
    }

    private func installLaunchPlists() throws {
        let daemon: [String: Any] = [
            "Label": NightLockPaths.daemonLabel,
            "ProgramArguments": [NightLockPaths.daemonExecutable],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "ThrottleInterval": 5,
            "StandardOutPath": "/var/log/nightlock.log",
            "StandardErrorPath": "/var/log/nightlock.log",
        ]
        let agent: [String: Any] = [
            "Label": NightLockPaths.agentLabel,
            "ProgramArguments": [NightLockPaths.appLauncher],
            "EnvironmentVariables": [NightLockPaths.agentEnvironmentKey: "1"],
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
    fputs("Stickman Blocker install failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
