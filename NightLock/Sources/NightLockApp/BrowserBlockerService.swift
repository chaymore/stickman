import AppKit
import Foundation
import Network
import NightLockCore

final class BrowserBlockerService {
    private var timer: Timer?
    private var server: NightLockPageServer?
    private var lastRedirectedURL: [String: String] = [:]

    func start() {
        let server = NightLockPageServer()
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
            _ = try? adapter.activeTabURL()
        }
    }

    private func inspectBrowsers() {
        guard let config = try? NightLockFiles.loadConfig(),
              config.enabled,
              config.schedule.isActive(at: Date())
        else { return }

        let adapters = NSWorkspace.shared.runningApplications.compactMap { application -> BrowserAdapter? in
            guard let identifier = application.bundleIdentifier else { return nil }
            return BrowserAdapter.adapter(for: identifier)
        }

        for adapter in adapters {
            do {
                guard let url = try adapter.activeTabURL(),
                      let domain = NightLockFiles.blockedDomain(for: url, domains: config.blockedDomains)
                else {
                    lastRedirectedURL[adapter.bundleIdentifier] = nil
                    continue
                }

                guard lastRedirectedURL[adapter.bundleIdentifier] != url else { continue }
                let target = server?.blockedPageURL(domain: domain, endTime: config.schedule.displayText) ?? "http://127.0.0.1:17420/blocked"
                try adapter.setActiveTabURL(target)
                lastRedirectedURL[adapter.bundleIdentifier] = url
            } catch {
                // Automation permission failures are visible in System Settings and do not weaken daemon enforcement.
            }
        }
    }
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

    func activeTabURL() throws -> String? {
        switch self {
        case .safari:
            return try run(#"tell application "Safari" to if (count of windows) > 0 then get URL of current tab of front window"#)
        case .chrome:
            return try run(#"tell application "Google Chrome" to if (count of windows) > 0 then get URL of active tab of front window"#)
        }
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
            throw NSError(domain: "NightLock.AppleScript", code: 1, userInfo: [NSLocalizedDescriptionKey: error.description])
        }
        return result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class NightLockPageServer {
    private let port: NWEndpoint.Port = 17420
    private let queue = DispatchQueue(label: "NightLock.BlockPage")
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

    func blockedPageURL(domain: String, endTime: String) -> String {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port.rawValue)
        components.path = "/blocked"
        components.queryItems = [
            URLQueryItem(name: "site", value: domain),
            URLQueryItem(name: "schedule", value: endTime),
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
                schedule: values["schedule"] ?? "your protected hours"
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

    private func html(site: String, schedule: String) -> String {
        let escaped = site
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let escapedSchedule = schedule
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>NightLock</title><style>
        :root{color-scheme:dark;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display",sans-serif}body{margin:0;min-height:100vh;display:grid;place-items:center;background:#111318;color:#f6f7f9}main{width:min(680px,calc(100vw - 48px));text-align:center}.mark{width:104px;height:104px;margin:0 auto 30px;border:3px solid #7ee0b8;border-radius:24px;display:grid;place-items:center;font-size:52px}h1{font-size:clamp(42px,7vw,76px);line-height:.98;letter-spacing:0;margin:0 0 24px}p{font-size:21px;line-height:1.5;color:#b9bec8;margin:0 auto 12px;max-width:580px}strong{color:#fff}.small{font-size:15px;color:#777e89;margin-top:30px}
        </style></head><body><main><div class="mark">⌁</div><h1>NightLock is on.</h1><p><strong>\(escaped)</strong> is unavailable during your protected hours.</p><p>You set this boundary earlier. Tonight-you does not get to renegotiate it.</p><p class="small">Current schedule: \(escapedSchedule).</p></main></body></html>
        """
    }
}
