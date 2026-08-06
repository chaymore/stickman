import AppKit
import Foundation

struct StickmanBrowserTab: Equatable {
    let windowIndex: Int
    let tabIndex: Int
    let title: String
    let url: String
}

enum BrowserControlError: LocalizedError {
    case chromeUnavailable
    case automationFailed(String)
    case tabNotFound(String)

    var errorDescription: String? {
        switch self {
        case .chromeUnavailable:
            return "Google Chrome is not installed."
        case .automationFailed(let message):
            return "Chrome control failed. macOS may need Automation permission for Stickman. \(message)"
        case .tabNotFound(let query):
            return "I could not find a Chrome tab matching \(query)."
        }
    }
}

final class BrowserControlService {
    static let shared = BrowserControlService()

    private init() {}

    var isChromeAvailable: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil
    }

    @discardableResult
    func openChromeTab(_ url: URL, activate: Bool = true) throws -> StickmanBrowserTab {
        guard isChromeAvailable else { throw BrowserControlError.chromeUnavailable }
        let escapedURL = Self.escapeForAppleScript(url.absoluteString)
        let activation = activate ? "activate" : ""
        let script = """
        tell application "Google Chrome"
            \(activation)
            if (count of windows) is 0 then make new window
            tell front window
                make new tab at end of tabs with properties {URL:"\(escapedURL)"}
                set active tab index to (count of tabs)
            end tell
        end tell
        """
        _ = try runAppleScript(script)
        return try tabs().first(where: { $0.url == url.absoluteString })
            ?? StickmanBrowserTab(windowIndex: 1, tabIndex: 1, title: url.host ?? url.absoluteString, url: url.absoluteString)
    }

    func searchGoogle(for query: String) throws -> StickmanBrowserTab {
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return try openChromeTab(components.url!)
    }

    func tabs() throws -> [StickmanBrowserTab] {
        guard isChromeAvailable else { throw BrowserControlError.chromeUnavailable }
        let script = """
        tell application "Google Chrome"
            set output to ""
            repeat with windowIndex from 1 to (count of windows)
                set currentWindow to window windowIndex
                repeat with tabIndex from 1 to (count of tabs of currentWindow)
                    set currentTab to tab tabIndex of currentWindow
                    set output to output & windowIndex & "|||" & tabIndex & "|||" & (title of currentTab) & "|||" & (URL of currentTab) & linefeed
                end repeat
            end repeat
            return output
        end tell
        """
        let output = try runAppleScript(script)
        return output.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "|||")
            guard fields.count >= 4,
                  let windowIndex = Int(fields[0]),
                  let tabIndex = Int(fields[1])
            else { return nil }
            return StickmanBrowserTab(
                windowIndex: windowIndex,
                tabIndex: tabIndex,
                title: fields[2],
                url: fields.dropFirst(3).joined(separator: "|||")
            )
        }
    }

    @discardableResult
    func activateTab(matching query: String) throws -> StickmanBrowserTab {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let tab = try tabs().first(where: {
            $0.title.lowercased().contains(normalizedQuery) || $0.url.lowercased().contains(normalizedQuery)
        }) else {
            throw BrowserControlError.tabNotFound(query)
        }

        let script = """
        tell application "Google Chrome"
            activate
            set index of window \(tab.windowIndex) to 1
            set active tab index of front window to \(tab.tabIndex)
        end tell
        """
        _ = try runAppleScript(script)
        return tab
    }

    func summary(limit: Int = 12) -> String {
        do {
            let currentTabs = try tabs()
            guard !currentTabs.isEmpty else { return "Chrome has no open tabs." }
            let rows = currentTabs.prefix(limit).map { "• \($0.title) — \($0.url)" }
            let remainder = currentTabs.count > limit ? "\n…and \(currentTabs.count - limit) more." : ""
            return "Chrome tabs (\(currentTabs.count)):\n\(rows.joined(separator: "\n"))\(remainder)"
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    static func resolvedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = URL(string: trimmed), direct.scheme != nil { return direct }
        if trimmed.contains("."), !trimmed.contains(" ") {
            return URL(string: "https://\(trimmed)")
        }
        return nil
    }

    static func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func runAppleScript(_ source: String) throws -> String {
        var errorInfo: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? errorInfo.description
            throw BrowserControlError.automationFailed(message)
        }
        UserDefaults.standard.set(true, forKey: "StickmanChromeAutomationAuthorized")
        return result?.stringValue ?? ""
    }
}
