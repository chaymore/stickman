import Foundation

final class NightLockBridge {
    static let shared = NightLockBridge()

    private struct Status: Decodable {
        let active: Bool
        let enabled: Bool
        let schedule: String
    }

    private let statusURL = URL(fileURLWithPath: "/Library/Application Support/NightLock/status.json")
    private let appURL = URL(fileURLWithPath: "/Applications/NightLock.app")

    private init() {}

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: appURL.path)
    }

    var shortStatus: String {
        guard isInstalled else { return "NightLock is not installed." }
        guard let status = loadStatus() else { return "NightLock is installed; status is unavailable." }
        if status.active { return "NightLock is actively enforcing \(status.schedule)." }
        if status.enabled { return "NightLock is armed for \(status.schedule)." }
        return "NightLock is installed but disabled."
    }

    var detailedStatus: String {
        "NightLock: \(shortStatus) Stickman uses its own temporary focus guard during daytime sessions and leaves NightLock's protected configuration alone."
    }

    private func loadStatus() -> Status? {
        guard let data = try? Data(contentsOf: statusURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Status.self, from: data)
    }
}
