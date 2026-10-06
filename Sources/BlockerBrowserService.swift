import AppKit
import Foundation
import Network
import NightLockCore
import os

/// Redirects blocked Safari and Chrome tabs to the "Blocked by Stickman" page and reports
/// allowance use to the root daemon, which stays the authority through /etc/hosts.
final class BrowserBlockerService {
    private let logger = Logger(subsystem: "com.chaymore.Stickman", category: "StickmanBlocker")
    private var timer: Timer?
    private var server: BlockerPageServer?
    private var lastRedirectedURL: [BrowserTabKey: String] = [:]
    private var pendingAllowanceURL: [BrowserTabKey: String] = [:]
    private var engagedAllowance: [BrowserTabKey: String] = [:]

    func start() {
        let server = BlockerPageServer()
        server.start()
        self.server = server

        requestBrowserPermissions()
        inspectBrowsers()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.inspectBrowsers()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        server?.stop()
        server = nil
    }

    private func requestBrowserPermissions() {
        let adapters = NSWorkspace.shared.runningApplications.compactMap { application -> BrowserAdapter? in
            guard let identifier = application.bundleIdentifier else { return nil }
            return BrowserAdapter.adapter(for: identifier)
        }
        for adapter in adapters {
            _ = try? adapter.activeTab()
        }
    }

    private func inspectBrowsers() {
        guard let config = try? NightLockFiles.loadConfig(),
              config.enabled,
              config.schedule.isActive(at: Date())
        else { return }

        let limits = config.allowanceLimits
        let ledger = try? NightLockFiles.loadAllowanceLedger()
        let now = Date()
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        let adapters = NSWorkspace.shared.runningApplications.compactMap { application -> BrowserAdapter? in
            guard let identifier = application.bundleIdentifier else { return nil }
            return BrowserAdapter.adapter(for: identifier)
        }

        for adapter in adapters {
            do {
                guard let tab = try adapter.activeTab(), !tab.url.isEmpty else { continue }
                let tabKey = BrowserTabKey(browser: adapter.bundleIdentifier, tab: tab.identifier)
                let url = tab.url
                let blockedPage = blockedPageContext(from: url, domains: config.blockedDomains)
                guard let domain = blockedPage?.domain
                    ?? NightLockFiles.blockedDomain(for: url, domains: config.blockedDomains)
                else {
                    lastRedirectedURL[tabKey] = nil
                    pendingAllowanceURL[tabKey] = nil
                    engagedAllowance[tabKey] = nil
                    continue
                }

                if let allowance = NightLockFiles.allowanceKey(for: domain),
                   config.managedDomains.contains(allowance) {
                    let minuteLimit = limits[allowance] ?? 0
                    let bypassed = ledger?.isBypassedForDay(allowance) == true
                    let accessMode: SiteAccessMode = bypassed
                        ? .unrestricted
                        : config.accessMode(for: allowance, at: now)

                    if accessMode == .unrestricted {
                        pendingAllowanceURL[tabKey] = nil
                        if blockedPage != nil,
                           adapter.bundleIdentifier == frontmostBundleIdentifier,
                           engagedAllowance[tabKey] != allowance {
                            try adapter.setActiveTabURL(blockedPage?.returnURL ?? "https://\(allowance)")
                        }
                        engagedAllowance[tabKey] = allowance
                        continue
                    }

                    if accessMode == .blocked {
                        pendingAllowanceURL[tabKey] = nil
                        engagedAllowance[tabKey] = nil
                        if blockedPage == nil {
                            redirectBlocked(
                                adapter: adapter,
                                tabKey: tabKey,
                                url: url,
                                domain: domain,
                                remainingSeconds: nil,
                                allowanceMinutes: nil
                            )
                        }
                        continue
                    }

                    guard adapter.bundleIdentifier == frontmostBundleIdentifier else { continue }

                    let remaining = ledger?.remainingSeconds(for: allowance, limits: limits, at: now)
                        ?? (minuteLimit * 60)
                    guard remaining > 0 else {
                        if blockedPage != nil { continue }
                        pendingAllowanceURL[tabKey] = nil
                        engagedAllowance[tabKey] = nil
                        redirectBlocked(
                            adapter: adapter,
                            tabKey: tabKey,
                            url: url,
                            domain: domain,
                            remainingSeconds: 0,
                            allowanceMinutes: minuteLimit
                        )
                        continue
                    }

                    if ledger?.hasActiveWindow(for: allowance, limits: limits, at: now) == true {
                        if engagedAllowance[tabKey] == allowance { continue }
                        let pendingURL = pendingAllowanceURL.removeValue(forKey: tabKey)
                            ?? blockedPage?.returnURL
                        if let pendingURL {
                            try adapter.setActiveTabURL(pendingURL)
                        }
                        engagedAllowance[tabKey] = allowance
                    } else {
                        submitAllowanceHeartbeat(domain: allowance)
                        if engagedAllowance[tabKey] != allowance {
                            pendingAllowanceURL[tabKey] = blockedPage?.returnURL ?? url
                        }
                    }
                    continue
                }

                if blockedPage != nil { continue }
                engagedAllowance[tabKey] = nil
                redirectBlocked(
                    adapter: adapter,
                    tabKey: tabKey,
                    url: url,
                    domain: domain,
                    remainingSeconds: nil,
                    allowanceMinutes: nil
                )
            } catch {
                logger.error("Browser inspection failed for \(adapter.bundleIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func blockedPageContext(from url: String, domains: [String]) -> BlockedPageContext? {
        guard let components = URLComponents(string: url),
              components.host == "127.0.0.1",
              components.port == 17420,
              components.path == "/blocked",
              let site = components.queryItems?.first(where: { $0.name == "site" })?.value,
              let domain = NightLockFiles.blockedDomain(for: "https://\(site)", domains: domains)
        else { return nil }

        let requestedReturnURL = components.queryItems?.first(where: { $0.name == "return" })?.value
        let returnURL = requestedReturnURL.flatMap { candidate in
            NightLockFiles.blockedDomain(for: candidate, domains: [domain]) == domain ? candidate : nil
        } ?? "https://\(domain)"
        return BlockedPageContext(domain: domain, returnURL: returnURL)
    }

    private func submitAllowanceHeartbeat(domain: String) {
        let request = AllowanceActivityRequest(domain: domain)
        guard let data = try? NightLockFiles.encoder.encode(request) else { return }
        let path = NightLockPaths.allowanceRequests + "/\(request.id.uuidString).json"
        _ = FileManager.default.createFile(
            atPath: path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
    }

    private func redirectBlocked(
        adapter: BrowserAdapter,
        tabKey: BrowserTabKey,
        url: String,
        domain: String,
        remainingSeconds: Int?,
        allowanceMinutes: Int?
    ) {
        guard lastRedirectedURL[tabKey] != url else { return }
        let target = server?.blockedPageURL(
            domain: domain,
            endTime: "Always on",
            remainingSeconds: remainingSeconds,
            allowanceMinutes: allowanceMinutes,
            returnURL: url
        ) ?? "http://127.0.0.1:17420/blocked"
        do {
            try adapter.setActiveTabURL(target)
            lastRedirectedURL[tabKey] = url
        } catch {
            // The daemon's hosts enforcement remains authoritative.
        }
    }
}

private struct BrowserTabKey: Hashable {
    let browser: String
    let tab: String
}

private struct BrowserTabSnapshot {
    let identifier: String
    let url: String
}

private struct BlockedPageContext {
    let domain: String
    let returnURL: String
}

private enum BrowserAdapter {
    case safari
    case chrome

    var bundleIdentifier: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .chrome: return "com.google.Chrome"
        }
    }

    static func adapter(for bundleIdentifier: String) -> BrowserAdapter? {
        switch bundleIdentifier {
        case "com.apple.Safari": return .safari
        case "com.google.Chrome": return .chrome
        default: return nil
        }
    }

    func activeTab() throws -> BrowserTabSnapshot? {
        let value: String?
        switch self {
        case .safari:
            value = try run("""
            tell application "Safari"
                if (count of windows) > 0 then
                    set activeWindow to front window
                    set activeTab to current tab of activeWindow
                    return (URL of activeTab) & linefeed & ((id of activeWindow) as text) & ":" & ((index of activeTab) as text)
                end if
            end tell
            """)
        case .chrome:
            value = try run("""
            tell application "Google Chrome"
                if (count of windows) > 0 then
                    set activeWindow to front window
                    set activeTab to active tab of activeWindow
                    return (URL of activeTab) & linefeed & ((id of activeWindow) as text) & ":" & ((id of activeTab) as text)
                end if
            end tell
            """)
        }
        guard let value else { return nil }
        let parts = value.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw NSError(
                domain: "StickmanBlocker.AppleScript",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Browser tab identity was missing from the Automation response."]
            )
        }
        return BrowserTabSnapshot(identifier: String(parts[1]), url: String(parts[0]))
    }

    func setActiveTabURL(_ url: String) throws {
        let escaped = url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        switch self {
        case .safari:
            _ = try run(#"tell application "Safari" to set URL of current tab of front window to "\#(escaped)""#)
        case .chrome:
            _ = try run(#"tell application "Google Chrome" to set URL of active tab of front window to "\#(escaped)""#)
        }
    }

    private func run(_ source: String) throws -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            throw NSError(domain: "StickmanBlocker.AppleScript", code: 1, userInfo: [NSLocalizedDescriptionKey: error.description])
        }
        return result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class BlockerPageServer {
    private let port: NWEndpoint.Port = 17420
    private let queue = DispatchQueue(label: "Stickman.BlockerPage")
    private var listener: NWListener?

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp, on: port)
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
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

    func blockedPageURL(
        domain: String,
        endTime: String,
        remainingSeconds: Int?,
        allowanceMinutes: Int?,
        returnURL: String
    ) -> String {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port.rawValue)
        components.path = "/blocked"
        components.queryItems = [
            URLQueryItem(name: "site", value: domain),
            URLQueryItem(name: "schedule", value: endTime),
            URLQueryItem(name: "remaining", value: remainingSeconds.map(String.init)),
            URLQueryItem(name: "limit", value: allowanceMinutes.map(String.init)),
            URLQueryItem(name: "return", value: returnURL),
        ]
        return components.url?.absoluteString ?? "http://127.0.0.1:\(port.rawValue)/blocked"
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let values = self?.queryValues(request: request) ?? [:]
            let body = self?.html(
                site: values["site"] ?? "This site",
                schedule: values["schedule"] ?? "your protected hours",
                allowanceExhausted: values["remaining"] == "0",
                allowanceMinutes: values["limit"].flatMap(Int.init)
            ) ?? ""
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func queryValues(request: String) -> [String: String] {
        guard let line = request.components(separatedBy: "\r\n").first,
              let path = line.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://127.0.0.1\(path)")
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }

    private func html(
        site: String,
        schedule: String,
        allowanceExhausted: Bool,
        allowanceMinutes: Int?
    ) -> String {
        let detail = allowanceExhausted
            ? "Today's \(allowanceMinutes ?? 10)-minute allowance is used up. It resets at midnight."
            : "You drew this line on purpose. Stickman's holding it."
        let footnote = schedule == "Always on"
            ? "Stickman Blocker · always on for this site"
            : "Stickman Blocker · protected hours \(schedule)"
        return StickmanBlockPage.html(site: site, detail: detail, footnote: footnote)
    }
}
