import CryptoKit
import Foundation

public struct DailyMinuteWindow: Codable, Equatable, Sendable {
    public let startMinute: Int
    public let endMinute: Int

    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let current = ((components.hour ?? 0) * 60) + (components.minute ?? 0)
        if startMinute == endMinute { return true }
        if startMinute < endMinute { return current >= startMinute && current < endMinute }
        return current >= startMinute || current < endMinute
    }
}

public enum SiteAccessMode: String, Codable, Equatable, Sendable {
    case blocked
    case allowance
    case unrestricted
}

public struct SiteAccessPolicy: Codable, Equatable, Sendable {
    public let allowanceMinutes: Int?
    public let allowanceWindow: DailyMinuteWindow?
    public let unrestrictedWindow: DailyMinuteWindow?
    public let unrestrictedWeekdays: [Int]

    public init(
        allowanceMinutes: Int?,
        allowanceWindow: DailyMinuteWindow? = nil,
        unrestrictedWindow: DailyMinuteWindow? = nil,
        unrestrictedWeekdays: [Int] = []
    ) {
        self.allowanceMinutes = allowanceMinutes
        self.allowanceWindow = allowanceWindow
        self.unrestrictedWindow = unrestrictedWindow
        self.unrestrictedWeekdays = unrestrictedWeekdays
    }

    public func accessMode(at date: Date, calendar: Calendar = .current) -> SiteAccessMode {
        let weekday = calendar.component(.weekday, from: date)
        if unrestrictedWeekdays.contains(weekday) { return .unrestricted }
        if unrestrictedWindow?.contains(date, calendar: calendar) == true { return .unrestricted }
        guard (allowanceMinutes ?? 0) > 0 else { return .blocked }
        if let allowanceWindow, !allowanceWindow.contains(date, calendar: calendar) { return .blocked }
        return .allowance
    }
}

public struct NightLockConfig: Codable, Equatable, Sendable {
    public var policyVersion: Int?
    public var enabled: Bool
    public var startHour: Int
    public var startMinute: Int
    public var endHour: Int
    public var endMinute: Int
    public var blockedDomains: [String]
    public var blockedHosts: [String]
    public var dailyAllowanceMinutes: [String: Int]?
    public var siteAccessPolicies: [String: SiteAccessPolicy]?
    public var recoverySalt: String
    public var recoveryHash: String

    public init(
        policyVersion: Int = 16,
        enabled: Bool = true,
        startHour: Int = 0,
        startMinute: Int = 0,
        endHour: Int = 0,
        endMinute: Int = 0,
        blockedDomains: [String] = NightLockConfig.defaultDomains,
        blockedHosts: [String] = NightLockConfig.defaultHosts,
        dailyAllowanceMinutes: [String: Int] = NightLockConfig.defaultDailyAllowanceMinutes,
        siteAccessPolicies: [String: SiteAccessPolicy] = NightLockConfig.defaultSiteAccessPolicies,
        recoverySalt: String,
        recoveryHash: String
    ) {
        self.policyVersion = policyVersion
        self.enabled = enabled
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.blockedDomains = blockedDomains
        self.blockedHosts = blockedHosts
        self.dailyAllowanceMinutes = dailyAllowanceMinutes
        self.siteAccessPolicies = siteAccessPolicies
        self.recoverySalt = recoverySalt
        self.recoveryHash = recoveryHash
    }

    public static let defaultDomains = [
        "messenger.com",
        "instagram.com",
        "netflix.com",
        "reddit.com",
        "x.com",
        "twitter.com",
        "youtube.com",
        "youtu.be",
        "youtube-nocookie.com",
        "linkedin.com",
        "lnkd.in",
    ]

    public static let defaultHosts = [
        "messenger.com", "www.messenger.com",
        "instagram.com", "www.instagram.com", "m.instagram.com", "i.instagram.com",
        "netflix.com", "www.netflix.com", "signup.netflix.com", "help.netflix.com",
        "api-global.netflix.com", "app-api.netflix.com", "nflxvideo.net", "www.nflxvideo.net",
        "nflxso.net", "nflximg.net", "nflxext.com",
        "reddit.com", "www.reddit.com", "old.reddit.com", "new.reddit.com", "redd.it",
        "x.com", "www.x.com", "mobile.x.com", "twitter.com", "www.twitter.com",
        "mobile.twitter.com", "t.co",
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be",
        "youtube-nocookie.com", "www.youtube-nocookie.com",
        "linkedin.com", "www.linkedin.com", "m.linkedin.com", "lnkd.in",
    ]

    public static let defaultDailyAllowanceMinutes = [
        "instagram.com": 30,
        "x.com": 10,
    ]

    public static let defaultSiteAccessPolicies = [
        "instagram.com": SiteAccessPolicy(allowanceMinutes: 30),
        "x.com": SiteAccessPolicy(
            allowanceMinutes: 10,
            allowanceWindow: DailyMinuteWindow(startMinute: 17 * 60, endMinute: nightLockMinute),
            unrestrictedWindow: DailyMinuteWindow(startMinute: morningUnlockMinute, endMinute: 17 * 60)
        ),
        // Open all day, locked from 10 PM until 8 AM.
        "youtube.com": SiteAccessPolicy(
            allowanceMinutes: nil,
            unrestrictedWindow: DailyMinuteWindow(startMinute: morningUnlockMinute, endMinute: nightLockMinute)
        ),
        "linkedin.com": SiteAccessPolicy(
            allowanceMinutes: nil,
            unrestrictedWindow: DailyMinuteWindow(startMinute: morningUnlockMinute, endMinute: nightLockMinute)
        ),
    ]

    public static let nightLockMinute = 22 * 60
    public static let morningUnlockMinute = 8 * 60

    /// Every domain whose access follows a time policy or allowance, rather than a permanent block.
    public var managedDomains: Set<String> {
        Set(siteAccessPolicies?.keys.map { $0 } ?? []).union(allowanceLimits.keys)
    }

    public var allowanceLimits: [String: Int] {
        guard let siteAccessPolicies else { return dailyAllowanceMinutes ?? [:] }
        return Dictionary(uniqueKeysWithValues: siteAccessPolicies.compactMap { domain, policy in
            guard let minutes = policy.allowanceMinutes, minutes > 0 else { return nil }
            return (domain, minutes)
        })
    }

    public func accessMode(
        for domain: String,
        at date: Date,
        calendar: Calendar = .current
    ) -> SiteAccessMode {
        let key = NightLockFiles.allowanceKey(for: domain) ?? NightLockFiles.normalizedDomain(domain)
        if let policy = siteAccessPolicies?[key] {
            return policy.accessMode(at: date, calendar: calendar)
        }
        return (dailyAllowanceMinutes?[key] ?? 0) > 0 ? .allowance : .blocked
    }

    public var schedule: NightLockSchedule {
        NightLockSchedule(
            startHour: startHour,
            startMinute: startMinute,
            endHour: endHour,
            endMinute: endMinute
        )
    }
}

public struct AllowanceActivityRequest: Codable, Sendable {
    public let id: UUID
    public let domain: String
    public let createdAt: Date

    public init(domain: String, createdAt: Date = Date()) {
        id = UUID()
        self.domain = domain
        self.createdAt = createdAt
    }
}

public struct DailyAllowanceEntry: Codable, Equatable, Sendable {
    public var usedSeconds: Double
    public var startedAt: Date?
    public var lastHeartbeat: Date?
    public var bypassedForDay: Bool?

    public init(
        usedSeconds: Double = 0,
        startedAt: Date? = nil,
        lastHeartbeat: Date? = nil,
        bypassedForDay: Bool = false
    ) {
        self.usedSeconds = usedSeconds
        self.startedAt = startedAt
        self.lastHeartbeat = lastHeartbeat
        self.bypassedForDay = bypassedForDay
    }
}

public struct DailyAllowanceLedger: Codable, Equatable, Sendable {
    public var dayKey: String
    public var entries: [String: DailyAllowanceEntry]

    public init(dayKey: String, entries: [String: DailyAllowanceEntry] = [:]) {
        self.dayKey = dayKey
        self.entries = entries
    }

    public func remainingSeconds(for domain: String, limits: [String: Int], at date: Date = Date()) -> Int {
        let limit = Double((limits[domain] ?? 0) * 60)
        let entry = entries[domain]
        if entry?.bypassedForDay == true { return Int(limit) }
        let used: Double
        if let startedAt = entry?.startedAt {
            used = max(0, date.timeIntervalSince(startedAt))
        } else {
            used = entry?.usedSeconds ?? 0
        }
        return max(0, Int(ceil(limit - used)))
    }

    public func hasActiveWindow(for domain: String, limits: [String: Int], at date: Date = Date()) -> Bool {
        guard let entry = entries[domain] else { return false }
        return entry.bypassedForDay == true
            || (entry.startedAt != nil && remainingSeconds(for: domain, limits: limits, at: date) > 0)
    }

    public func isBypassedForDay(_ domain: String) -> Bool {
        entries[domain]?.bypassedForDay == true
    }
}

public struct NightLockSchedule: Equatable, Sendable {
    public let startHour: Int
    public let startMinute: Int
    public let endHour: Int
    public let endMinute: Int

    public init(startHour: Int, startMinute: Int, endHour: Int, endMinute: Int) {
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
    }

    public func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let current = ((components.hour ?? 0) * 60) + (components.minute ?? 0)
        let start = (startHour * 60) + startMinute
        let end = (endHour * 60) + endMinute

        if start == end { return true }
        if start < end { return current >= start && current < end }
        return current >= start || current < end
    }

    public var displayText: String {
        if startHour == endHour && startMinute == endMinute {
            return "Always on"
        }
        return "\(Self.timeText(hour: startHour, minute: startMinute)) to \(Self.timeText(hour: endHour, minute: endMinute))"
    }

    private static func timeText(hour: Int, minute: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let date = Calendar.current.date(from: components) ?? Date()
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}

public struct ProtectedUpdateRequest: Codable, Sendable {
    public let id: UUID
    public let recoveryKey: String
    public let enabled: Bool
    public let startHour: Int
    public let startMinute: Int
    public let endHour: Int
    public let endMinute: Int
    public let createdAt: Date

    public init(
        recoveryKey: String,
        enabled: Bool,
        startHour: Int,
        startMinute: Int,
        endHour: Int,
        endMinute: Int
    ) {
        id = UUID()
        self.recoveryKey = recoveryKey
        self.enabled = enabled
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        createdAt = Date()
    }
}

public enum ProtectedAllowanceResetOperation: String, Codable, Sendable {
    case resetAllowance
}

public struct ProtectedAllowanceResetRequest: Codable, Sendable {
    public let id: UUID
    public let operation: ProtectedAllowanceResetOperation
    public let recoveryKey: String
    public let domain: String
    public let createdAt: Date

    public init(recoveryKey: String, domain: String) {
        id = UUID()
        operation = .resetAllowance
        self.recoveryKey = recoveryKey
        self.domain = domain
        createdAt = Date()
    }
}

public enum ProtectedDailyBypassOperation: String, Codable, Sendable {
    case bypassForDay
}

public struct ProtectedDailyBypassRequest: Codable, Sendable {
    public let id: UUID
    public let operation: ProtectedDailyBypassOperation
    public let recoveryKey: String
    public let domain: String
    public let createdAt: Date

    public init(recoveryKey: String, domain: String) {
        id = UUID()
        operation = .bypassForDay
        self.recoveryKey = recoveryKey
        self.domain = domain
        createdAt = Date()
    }
}

public struct NightLockStatus: Codable, Sendable {
    public let active: Bool
    public let enabled: Bool
    public let schedule: String
    public let lastRequestMessage: String?
    public let allowanceRemainingSeconds: [String: Int]?
    public let dailyBypassDomains: [String]?
    public let siteAccessModes: [String: SiteAccessMode]?
    public let updatedAt: Date

    public init(
        active: Bool,
        enabled: Bool,
        schedule: String,
        lastRequestMessage: String?,
        allowanceRemainingSeconds: [String: Int]? = nil,
        dailyBypassDomains: [String]? = nil,
        siteAccessModes: [String: SiteAccessMode]? = nil,
        updatedAt: Date = Date()
    ) {
        self.active = active
        self.enabled = enabled
        self.schedule = schedule
        self.lastRequestMessage = lastRequestMessage
        self.allowanceRemainingSeconds = allowanceRemainingSeconds
        self.dailyBypassDomains = dailyBypassDomains
        self.siteAccessModes = siteAccessModes
        self.updatedAt = updatedAt
    }
}

public enum RecoveryKeyVerifier {
    public static func hash(key: String, salt: String) -> String {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data((salt + ":" + normalized).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(key: String, salt: String, expectedHash: String) -> Bool {
        hash(key: key, salt: salt) == expectedHash.lowercased()
    }
}

public enum NightLockPaths {
    public static let supportDirectory = "/Library/Application Support/NightLock"
    public static let config = supportDirectory + "/config.json"
    public static let status = supportDirectory + "/status.json"
    public static let requests = supportDirectory + "/Requests"
    public static let allowanceRequests = supportDirectory + "/AllowanceRequests"
    public static let allowanceLedger = supportDirectory + "/allowances.json"
    public static let recoveryPartOne = "/var/db/NightLock/.recovery-part-1"
    public static let recoveryPartTwo = supportDirectory + "/.recovery/.recovery-part-2"
    public static let hostsFile = "/etc/hosts"
    public static let daemonExecutable = "/Library/PrivilegedHelperTools/com.chaymore.NightLock.daemon"
    public static let daemonPlist = "/Library/LaunchDaemons/com.chaymore.NightLock.daemon.plist"
    public static let agentPlist = "/Library/LaunchAgents/com.chaymore.NightLock.agent.plist"
    /// Stickman Blocker ships inside Stickman.app. Internal names and paths keep the
    /// NightLock prefix so existing installs keep their recovery key and configuration.
    public static let installedApp = "/Applications/Stickman.app"
    public static let appLauncher = installedApp + "/Contents/MacOS/Stickman"
    public static let bundledDaemon = installedApp + "/Contents/MacOS/StickmanBlockerDaemon"
    public static let bundledInstaller = installedApp + "/Contents/MacOS/StickmanBlockerInstaller"
    public static let bundledRecoveryTool = installedApp + "/Contents/MacOS/stickman-blocker-recover"
    /// Earlier standalone blocker apps, removed by the installer.
    public static let legacyInstalledApps = ["/Applications/Night Routine.app", "/Applications/NightLock.app"]
    public static let agentLabel = "com.chaymore.NightLock.agent"
    public static let daemonLabel = "com.chaymore.NightLock.daemon"
    /// Set in the login agent's environment so Stickman knows launchd keeps it running.
    public static let agentEnvironmentKey = "STICKMAN_LAUNCHED_BY_AGENT"
}

public enum NightLockFiles {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func loadConfig() throws -> NightLockConfig {
        try decoder.decode(NightLockConfig.self, from: Data(contentsOf: URL(fileURLWithPath: NightLockPaths.config)))
    }

    public static func loadStatus() throws -> NightLockStatus {
        try decoder.decode(NightLockStatus.self, from: Data(contentsOf: URL(fileURLWithPath: NightLockPaths.status)))
    }

    public static func loadAllowanceLedger() throws -> DailyAllowanceLedger {
        try decoder.decode(
            DailyAllowanceLedger.self,
            from: Data(contentsOf: URL(fileURLWithPath: NightLockPaths.allowanceLedger))
        )
    }

    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    public static func allowanceKey(for domain: String) -> String? {
        let normalized = normalizedDomain(domain)
        if normalized == "instagram.com" || normalized.hasSuffix(".instagram.com") {
            return "instagram.com"
        }
        if normalized == "x.com" || normalized.hasSuffix(".x.com")
            || normalized == "twitter.com" || normalized.hasSuffix(".twitter.com")
            || normalized == "t.co" || normalized.hasSuffix(".t.co") {
            return "x.com"
        }
        if normalized == "youtube.com" || normalized.hasSuffix(".youtube.com")
            || normalized == "youtu.be" || normalized.hasSuffix(".youtu.be")
            || normalized == "youtube-nocookie.com" || normalized.hasSuffix(".youtube-nocookie.com") {
            return "youtube.com"
        }
        if normalized == "linkedin.com" || normalized.hasSuffix(".linkedin.com")
            || normalized == "lnkd.in" || normalized.hasSuffix(".lnkd.in") {
            return "linkedin.com"
        }
        return nil
    }

    public static func host(_ host: String, belongsToAllowance allowance: String) -> Bool {
        allowanceKey(for: host) == allowance
    }

    public static func normalizedDomain(_ value: String) -> String {
        var text = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
        text = text.components(separatedBy: "/").first ?? text
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    public static func blockedDomain(for urlString: String, domains: [String]) -> String? {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return nil }
        return domains.map(normalizedDomain).first { host == $0 || host.hasSuffix(".\($0)") }
    }
}
