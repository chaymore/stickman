import AppKit
import Foundation
import Network

struct WebsiteBlockerSettings: Codable {
    var enabled: Bool
    var startHour: Int
    var startMinute: Int
    var endHour: Int
    var endMinute: Int
    var blockedDomains: [String]
    var snoozeUntil: Date?
    var focusSessionUntil: Date?
    var focusBlockedDomains: [String]?

    static let defaults = WebsiteBlockerSettings(
        enabled: true,
        startHour: 23,
        startMinute: 0,
        endHour: 6,
        endMinute: 0,
        blockedDomains: ["youtube.com", "x.com", "reddit.com", "facebook.com"],
        snoozeUntil: nil,
        focusSessionUntil: nil,
        focusBlockedDomains: ["youtube.com", "x.com", "reddit.com", "facebook.com", "instagram.com", "netflix.com"]
    )
}

struct WebsiteBlockerSchedule {
    let startHour: Int
    let startMinute: Int
    let endHour: Int
    let endMinute: Int

    func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let currentMinutes = ((components.hour ?? 0) * 60) + (components.minute ?? 0)
        let startMinutes = (startHour * 60) + startMinute
        let endMinutes = (endHour * 60) + endMinute

        if startMinutes == endMinutes {
            return true
        }

        if startMinutes < endMinutes {
            return currentMinutes >= startMinutes && currentMinutes < endMinutes
        }

        return currentMinutes >= startMinutes || currentMinutes < endMinutes
    }
}

struct WebsiteBlockerDomainMatcher {
    static func blockedDomain(for urlString: String, blockedDomains: [String]) -> String? {
        guard let host = URL(string: urlString)?.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) else {
            return nil
        }

        return blockedDomains
            .map(normalizedDomain)
            .first { domain in
                host == domain || host.hasSuffix(".\(domain)")
            }
    }

    static func normalizedDomain(_ value: String) -> String {
        var text = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
        text = text.components(separatedBy: "/").first ?? text
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

final class WebsiteBlockerService {
    static let shared = WebsiteBlockerService()

    private let settingsURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var settings: WebsiteBlockerSettings
    private var timer: Timer?
    private var pageServer: BlockPageServer?
    private var lastRedirectedURLByBrowser: [String: String] = [:]

    private init() {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Stickman", isDirectory: true)
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Stickman", isDirectory: true)
        settingsURL = supportDirectory.appendingPathComponent("website-blocker.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        settings = WebsiteBlockerSettings.defaults
        loadSettings()
    }

    func start() {
        pageServer = BlockPageServer()
        pageServer?.start()
        checkNow()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkNow()
        }

        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pageServer?.stop()
        pageServer = nil
    }

    func enable() -> String {
        settings.enabled = true
        saveSettings()
        checkNow()
        return "Bedtime blocker is on. Stickman will guard \(domainList) from 11:00 PM to 6:00 AM."
    }

    func disable() -> String {
        settings.enabled = false
        settings.snoozeUntil = nil
        saveSettings()
        return "Stickman's flexible bedtime blocker is off. NightLock's protected schedule is separate and unchanged."
    }

    func settingsSnapshot() -> WebsiteBlockerSettings {
        pruneExpiredSnoozeIfNeeded()
        return settings
    }

    func setBlockerEnabled(_ enabled: Bool) {
        settings.enabled = enabled
        if !enabled {
            settings.snoozeUntil = nil
        }
        saveSettings()
        if enabled {
            checkNow()
        }
    }

    @discardableResult
    func addBlockedDomain(_ domainText: String) -> String? {
        let domain = WebsiteBlockerDomainMatcher.normalizedDomain(domainText)
        guard !domain.isEmpty else { return nil }

        if !settings.blockedDomains.contains(domain) {
            settings.blockedDomains.append(domain)
            settings.blockedDomains.sort()
            saveSettings()
            checkNow()
        }

        return domain
    }

    func removeBlockedDomain(_ domain: String) {
        let normalized = WebsiteBlockerDomainMatcher.normalizedDomain(domain)
        settings.blockedDomains.removeAll { $0 == normalized }
        saveSettings()
    }

    func showBlockedSites() -> String {
        "\(statusSummary)\nBlocked sites: \(domainList)."
    }

    func snoozeForChallenge(reason: String, minutes: Int = 15) -> String {
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReason.isEmpty else {
            return "Tell me why you need the unblock first, then I can give you a 15-minute Stickman Challenge snooze."
        }

        let expiry = Date().addingTimeInterval(TimeInterval(minutes * 60))
        settings.snoozeUntil = expiry
        saveSettings()

        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "Stickman Challenge accepted. I snoozed the blocker until \(formatter.string(from: expiry)) for: \(trimmedReason)"
    }

    func blockUntilMorning(_ domainText: String) -> String {
        guard let domain = addBlockedDomain(domainText) else {
            return "I could not tell which site to block."
        }

        settings.enabled = true
        settings.snoozeUntil = nil
        saveSettings()
        checkNow()
        return "\(domain) is blocked until morning when the bedtime window is active."
    }

    func startFocusSession(minutes: Int) -> String {
        let safeMinutes = max(5, min(240, minutes))
        settings.focusSessionUntil = Date().addingTimeInterval(TimeInterval(safeMinutes * 60))
        saveSettings()
        checkNow()
        return "Focus guard is on for \(safeMinutes) minutes. I will keep the scroll traps closed while you work."
    }

    func endFocusSession() -> String {
        settings.focusSessionUntil = nil
        saveSettings()
        return "Focus session ended. Nice work."
    }

    var focusStatus: String {
        pruneExpiredFocusIfNeeded()
        guard let end = settings.focusSessionUntil, end > Date() else {
            return "Focus guard: no active session."
        }
        let minutes = max(1, Int(ceil(end.timeIntervalSinceNow / 60)))
        return "Focus guard: \(minutes) minute\(minutes == 1 ? "" : "s") remaining."
    }

    func diagnosticsSummary() -> String {
        pruneExpiredSnoozeIfNeeded()

        let schedule = WebsiteBlockerSchedule(
            startHour: settings.startHour,
            startMinute: settings.startMinute,
            endHour: settings.endHour,
            endMinute: settings.endMinute
        )
        let now = Date()
        let runningAdapters = NSWorkspace.shared.runningApplications.compactMap { app -> BrowserAdapter? in
            guard let bundleIdentifier = app.bundleIdentifier else { return nil }
            return BrowserAdapter.adapter(for: bundleIdentifier)
        }

        var lines = [
            statusSummary,
            "Schedule active now: \(schedule.isActive(at: now) ? "yes" : "no").",
            "Block page server: \(pageServer?.isListening == true ? "listening" : "not listening").",
            "Supported browsers running: \(runningAdapters.map(\.displayName).joined(separator: ", ").nilIfEmpty ?? "none")."
        ]

        for adapter in runningAdapters {
            do {
                let url = try adapter.activeTabURL() ?? "(no active tab URL)"
                let match = WebsiteBlockerDomainMatcher.blockedDomain(
                    for: url,
                    blockedDomains: settings.blockedDomains
                )
                lines.append("\(adapter.displayName): \(url)")
                lines.append("\(adapter.displayName) match: \(match ?? "none").")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                lines.append("\(adapter.displayName) error: \(message)")
            }
        }

        return lines.joined(separator: "\n")
    }

    var statusSummary: String {
        pruneExpiredSnoozeIfNeeded()
        pruneExpiredFocusIfNeeded()

        if settings.focusSessionUntil.map({ $0 > Date() }) == true {
            return "\(focusStatus) \(nightLockStatusFragment)"
        }

        if !settings.enabled {
            return "Bedtime blocker: off."
        }

        if let snoozeUntil = settings.snoozeUntil, snoozeUntil > Date() {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return "Bedtime blocker: snoozed until \(formatter.string(from: snoozeUntil))."
        }

        let schedule = WebsiteBlockerSchedule(
            startHour: settings.startHour,
            startMinute: settings.startMinute,
            endHour: settings.endHour,
            endMinute: settings.endMinute
        )
        return schedule.isActive(at: Date())
            ? "Bedtime blocker: active until 6:00 AM for \(domainList)."
            : "Bedtime blocker: on, scheduled for 11:00 PM to 6:00 AM."
    }

    private var nightLockStatusFragment: String {
        NightLockBridge.shared.shortStatus
    }

    private var domainList: String {
        settings.blockedDomains.joined(separator: ", ")
    }

    private func checkNow() {
        pruneExpiredSnoozeIfNeeded()
        pruneExpiredFocusIfNeeded()

        let schedule = WebsiteBlockerSchedule(
            startHour: settings.startHour,
            startMinute: settings.startMinute,
            endHour: settings.endHour,
            endMinute: settings.endMinute
        )
        let bedtimeActive = settings.enabled
            && settings.snoozeUntil.map({ $0 > Date() }) != true
            && schedule.isActive(at: Date())
        let focusActive = settings.focusSessionUntil.map({ $0 > Date() }) == true
        guard bedtimeActive || focusActive else { return }

        let runningAdapters = NSWorkspace.shared.runningApplications.compactMap { app -> BrowserAdapter? in
            guard let bundleIdentifier = app.bundleIdentifier else { return nil }
            return BrowserAdapter.adapter(for: bundleIdentifier)
        }

        for adapter in runningAdapters {
            inspect(adapter, focusActive: focusActive)
        }
    }

    private func inspect(_ adapter: BrowserAdapter, focusActive: Bool) {
        let domains = focusActive
            ? Array(Set(settings.blockedDomains + (settings.focusBlockedDomains ?? []))).sorted()
            : settings.blockedDomains
        do {
            guard let currentURL = try adapter.activeTabURL(),
                  let blockedDomain = WebsiteBlockerDomainMatcher.blockedDomain(
                    for: currentURL,
                    blockedDomains: domains
                  )
            else {
                lastRedirectedURLByBrowser[adapter.bundleIdentifier] = nil
                return
            }

            let blockedPage = pageServer?.blockedPageURL(for: blockedDomain) ?? "http://127.0.0.1:17373/blocked?site=\(blockedDomain)"
            guard currentURL != blockedPage,
                  lastRedirectedURLByBrowser[adapter.bundleIdentifier] != currentURL
            else {
                return
            }

            try adapter.setActiveTabURL(blockedPage)
            lastRedirectedURLByBrowser[adapter.bundleIdentifier] = currentURL
        } catch {
            // Keep the background loop quiet; chat commands surface permission details when the user asks.
        }
    }

    private func loadSettings() {
        do {
            let data = try Data(contentsOf: settingsURL)
            settings = try decoder.decode(WebsiteBlockerSettings.self, from: data)
        } catch {
            settings = .defaults
            saveSettings()
        }
    }

    private func saveSettings() {
        do {
            try FileManager.default.createDirectory(
                at: settingsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(settings)
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            // Settings persistence failure should not crash Stickman.
        }
    }

    private func pruneExpiredSnoozeIfNeeded() {
        if let snoozeUntil = settings.snoozeUntil, snoozeUntil <= Date() {
            settings.snoozeUntil = nil
            saveSettings()
        }
    }

    private func pruneExpiredFocusIfNeeded() {
        if let end = settings.focusSessionUntil, end <= Date() {
            settings.focusSessionUntil = nil
            saveSettings()
        }
    }
}

private enum BrowserAdapter {
    case safari
    case chrome

    var bundleIdentifier: String {
        switch self {
        case .safari:
            return "com.apple.Safari"
        case .chrome:
            return "com.google.Chrome"
        }
    }

    var displayName: String {
        switch self {
        case .safari:
            return "Safari"
        case .chrome:
            return "Chrome"
        }
    }

    static func adapter(for bundleIdentifier: String) -> BrowserAdapter? {
        switch bundleIdentifier {
        case "com.apple.Safari":
            return .safari
        case "com.google.Chrome":
            return .chrome
        default:
            return nil
        }
    }

    func activeTabURL() throws -> String? {
        switch self {
        case .safari:
            return try runAppleScript(#"tell application "Safari" to if (count of windows) > 0 then get URL of current tab of front window"#)
        case .chrome:
            return try runAppleScript(#"tell application "Google Chrome" to if (count of windows) > 0 then get URL of active tab of front window"#)
        }
    }

    func setActiveTabURL(_ url: String) throws {
        let escapedURL = appleScriptString(url)
        switch self {
        case .safari:
            _ = try runAppleScript(#"tell application "Safari" to set URL of current tab of front window to "\#(escapedURL)""#)
        case .chrome:
            _ = try runAppleScript(#"tell application "Google Chrome" to set URL of active tab of front window to "\#(escapedURL)""#)
        }
    }

    private func runAppleScript(_ script: String) throws -> String? {
        guard let appleScript = NSAppleScript(source: script) else {
            throw BrowserAdapterError.appleEventsUnavailable("Stickman could not prepare the browser automation script.")
        }

        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? errorInfo.description
            throw BrowserAdapterError.appleEventsUnavailable(message)
        }

        let output = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == true ? nil : output
    }

    private func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private enum BrowserAdapterError: LocalizedError {
    case appleEventsUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .appleEventsUnavailable(let message):
            return "Stickman needs macOS Automation permission to control Safari or Chrome for bedtime blocking. \(message)"
        }
    }
}

private final class BlockPageServer {
    private let port: NWEndpoint.Port = 17373
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "Stickman.BlockPageServer")

    var isListening: Bool {
        listener != nil
    }

    func start() {
        guard listener == nil else { return }

        do {
            let listener = try NWListener(using: .tcp, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            listener = nil
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func blockedPageURL(for domain: String) -> String {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port.rawValue)
        components.path = "/blocked"
        components.queryItems = [URLQueryItem(name: "site", value: domain)]
        return components.url?.absoluteString ?? "http://127.0.0.1:\(port.rawValue)/blocked"
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let domain = self?.domain(from: request) ?? "that site"
            let body = self?.html(for: domain) ?? ""
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Cache-Control: no-store\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func domain(from request: String) -> String {
        guard let firstLine = request.components(separatedBy: "\r\n").first,
              let path = firstLine.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://127.0.0.1\(path)"),
              let site = components.queryItems?.first(where: { $0.name == "site" })?.value
        else {
            return "that site"
        }

        return site
    }

    private func html(for domain: String) -> String {
        let escapedDomain = escapeHTML(domain)
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Stickman says bedtime</title>
          <style>
            :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif; }
            body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #101114; color: #f8f8f8; }
            main { width: min(680px, calc(100vw - 40px)); text-align: center; }
            .stickman { width: 132px; height: 132px; margin: 0 auto 28px; border-radius: 52% 52% 46% 46%; background: #f7f7f2; position: relative; box-shadow: 0 24px 70px rgba(0,0,0,.45); }
            .stickman:before, .stickman:after { content: ""; position: absolute; top: 48px; width: 18px; height: 18px; border-radius: 50%; background: #101114; }
            .stickman:before { left: 38px; }
            .stickman:after { right: 38px; }
            .mouth { position: absolute; left: 48px; top: 78px; width: 36px; height: 16px; border-bottom: 5px solid #101114; border-radius: 0 0 40px 40px; }
            h1 { font-size: clamp(38px, 7vw, 76px); line-height: .92; margin: 0 0 22px; letter-spacing: 0; }
            p { font-size: clamp(18px, 2.3vw, 24px); line-height: 1.45; color: rgba(248,248,248,.78); margin: 0 auto 16px; max-width: 560px; }
            strong { color: white; }
            .note { margin-top: 28px; font-size: 16px; color: rgba(248,248,248,.56); }
          </style>
        </head>
        <body>
          <main>
            <div class="stickman"><div class="mouth"></div></div>
            <h1>Stickman has intercepted the scroll portal.</h1>
            <p><strong>\(escapedDomain)</strong> has been tucked into bed until 6AM.</p>
            <p>Ask Stickman for a brief unlock if this is genuinely mission-critical. He accepts good reasons and suspiciously specific tutorial emergencies.</p>
            <p class="note">Tiny bedtime wall. Big tomorrow-you energy.</p>
          </main>
        </body>
        </html>
        """
    }

    private func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
