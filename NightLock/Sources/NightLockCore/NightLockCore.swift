import CryptoKit
import Foundation

public struct NightLockConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var startHour: Int
    public var startMinute: Int
    public var endHour: Int
    public var endMinute: Int
    public var blockedDomains: [String]
    public var blockedHosts: [String]
    public var recoverySalt: String
    public var recoveryHash: String

    public init(
        enabled: Bool = true,
        startHour: Int = 22,
        startMinute: Int = 0,
        endHour: Int = 5,
        endMinute: Int = 0,
        blockedDomains: [String] = NightLockConfig.defaultDomains,
        blockedHosts: [String] = NightLockConfig.defaultHosts,
        recoverySalt: String,
        recoveryHash: String
    ) {
        self.enabled = enabled
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.blockedDomains = blockedDomains
        self.blockedHosts = blockedHosts
        self.recoverySalt = recoverySalt
        self.recoveryHash = recoveryHash
    }

    public static let defaultDomains = [
        "facebook.com",
        "fb.com",
        "messenger.com",
        "instagram.com",
        "linkedin.com",
        "netflix.com",
        "youtube.com",
        "reddit.com",
        "x.com",
        "twitter.com",
    ]

    public static let defaultHosts = [
        "facebook.com", "www.facebook.com", "m.facebook.com", "mbasic.facebook.com",
        "mobile.facebook.com", "graph.facebook.com", "fb.com", "www.fb.com",
        "messenger.com", "www.messenger.com",
        "instagram.com", "www.instagram.com", "m.instagram.com", "i.instagram.com",
        "linkedin.com", "www.linkedin.com", "m.linkedin.com", "mobile.linkedin.com",
        "netflix.com", "www.netflix.com", "signup.netflix.com", "help.netflix.com",
        "api-global.netflix.com", "app-api.netflix.com", "nflxvideo.net", "www.nflxvideo.net",
        "nflxso.net", "nflximg.net", "nflxext.com",
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
        "studio.youtube.com", "youtu.be", "youtube-nocookie.com", "www.youtube-nocookie.com",
        "reddit.com", "www.reddit.com", "old.reddit.com", "new.reddit.com", "redd.it",
        "x.com", "www.x.com", "mobile.x.com", "twitter.com", "www.twitter.com",
        "mobile.twitter.com", "t.co",
    ]

    public var schedule: NightLockSchedule {
        NightLockSchedule(
            startHour: startHour,
            startMinute: startMinute,
            endHour: endHour,
            endMinute: endMinute
        )
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
        "\(Self.timeText(hour: startHour, minute: startMinute)) to \(Self.timeText(hour: endHour, minute: endMinute))"
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

public struct NightLockStatus: Codable, Sendable {
    public let active: Bool
    public let enabled: Bool
    public let schedule: String
    public let lastRequestMessage: String?
    public let updatedAt: Date

    public init(active: Bool, enabled: Bool, schedule: String, lastRequestMessage: String?, updatedAt: Date = Date()) {
        self.active = active
        self.enabled = enabled
        self.schedule = schedule
        self.lastRequestMessage = lastRequestMessage
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
    public static let recoveryPartOne = "/var/db/NightLock/.recovery-part-1"
    public static let recoveryPartTwo = supportDirectory + "/.recovery/.recovery-part-2"
    public static let hostsFile = "/etc/hosts"
    public static let daemonExecutable = "/Library/PrivilegedHelperTools/com.chaymore.NightLock.daemon"
    public static let daemonPlist = "/Library/LaunchDaemons/com.chaymore.NightLock.daemon.plist"
    public static let agentPlist = "/Library/LaunchAgents/com.chaymore.NightLock.agent.plist"
    public static let installedApp = "/Applications/NightLock.app"
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
