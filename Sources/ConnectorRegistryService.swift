import AppKit
import Foundation
import Security

enum StickmanConnectorKind: String, CaseIterable, Identifiable {
    case macCalendar
    case googleCalendar
    case gmail
    case googleDrive
    case notion
    case slack
    case canvas
    case learningSuite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macCalendar: return "Mac Calendar"
        case .googleCalendar: return "Google Calendar"
        case .gmail: return "Gmail"
        case .googleDrive: return "Google Drive"
        case .notion: return "Notion"
        case .slack: return "Slack"
        case .canvas: return "Canvas"
        case .learningSuite: return "BYU Learning Suite"
        }
    }

    var detail: String {
        switch self {
        case .macCalendar: return "Native EventKit access; includes calendars synced into Calendar.app."
        case .googleCalendar: return "Works immediately when your Google calendar is synced into Calendar.app."
        case .gmail: return "OpenAI connector seam; Google desktop OAuth registration is still required."
        case .googleDrive: return "OpenAI connector seam with read-only Drive scope planned."
        case .notion: return "Official Notion MCP uses interactive OAuth; personal token fallback is stored in Keychain."
        case .slack: return "Slack OAuth app or user token required; writes will always ask first."
        case .canvas: return "Your school's Canvas URL and an access token; read-only coursework first."
        case .learningSuite: return "Optional BYU browser shortcut; no supported public API is available."
        }
    }

    var credentialService: String? {
        switch self {
        case .notion: return "Stickman Notion Access Token"
        case .slack: return "Stickman Slack Access Token"
        case .canvas: return "Stickman Canvas Access Token"
        default: return nil
        }
    }
}

enum StickmanConnectorStatus: Equatable {
    case connected
    case tokenSaved
    case ready
    case setupRequired
    case browserOnly

    var title: String {
        switch self {
        case .connected: return "Connected"
        case .tokenSaved: return "Token saved"
        case .ready: return "Ready"
        case .setupRequired: return "Setup needed"
        case .browserOnly: return "Browser only"
        }
    }
}

struct StickmanConnectorSnapshot: Equatable {
    let kind: StickmanConnectorKind
    let status: StickmanConnectorStatus
}

extension Notification.Name {
    static let stickmanConnectorsDidChange = Notification.Name("StickmanConnectorsDidChange")
}

final class StickmanCredentialStore {
    static let shared = StickmanCredentialStore()

    private init() {}

    func hasCredential(service: String) -> Bool {
        read(service: service) != nil
    }

    func save(_ value: String, service: String) -> Bool {
        let data = Data(value.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: NSUserName(),
            kSecAttrService as String: service
        ]
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    func read(service: String) -> String? {
        if let value = readExact(service: service) { return value }

        // One-way compatibility for people upgrading from the original Milo build.
        if service.hasPrefix("Stickman ") {
            let legacyService = service.replacingOccurrences(of: "Stickman ", with: "Milo ", options: .anchored)
            if let legacyValue = readExact(service: legacyService) {
                _ = save(legacyValue, service: service)
                return legacyValue
            }
        }
        return nil
    }

    private func readExact(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: NSUserName(),
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func remove(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: NSUserName(),
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class ConnectorRegistryService {
    static let shared = ConnectorRegistryService()

    private init() {}

    var snapshots: [StickmanConnectorSnapshot] {
        StickmanConnectorKind.allCases.map { StickmanConnectorSnapshot(kind: $0, status: status(for: $0)) }
    }

    func status(for kind: StickmanConnectorKind) -> StickmanConnectorStatus {
        switch kind {
        case .macCalendar, .googleCalendar:
            return PermissionCenterService.shared.status(for: .calendar) == .granted ? .connected : .ready
        case .learningSuite:
            return .browserOnly
        case .gmail, .googleDrive:
            return .setupRequired
        case .canvas:
            guard let service = kind.credentialService else { return .setupRequired }
            return StickmanCredentialStore.shared.hasCredential(service: service) && CanvasService.shared.baseURL != nil
                ? .connected
                : .setupRequired
        case .notion, .slack:
            guard let service = kind.credentialService else { return .setupRequired }
            return StickmanCredentialStore.shared.hasCredential(service: service) ? .tokenSaved : .setupRequired
        }
    }

    func configure(_ kind: StickmanConnectorKind, presenting window: NSWindow?) {
        StickmanTaskAnimationController.play(.connectService)
        switch kind {
        case .macCalendar, .googleCalendar:
            PermissionCenterService.shared.request(.calendar)
        case .learningSuite:
            if let url = URL(string: "https://learningsuite.byu.edu/") {
                _ = try? BrowserControlService.shared.openChromeTab(url)
            }
        case .gmail, .googleDrive:
            showSetupMessage(
                title: "Google OAuth setup",
                message: "Stickman’s connector boundary is ready, but Google requires a registered Desktop OAuth client before the consent flow can issue tokens. Calendar access works now through Calendar.app.",
                setupURL: URL(string: "https://console.cloud.google.com/apis/credentials"),
                window: window
            )
        case .notion:
            promptForCredential(
                kind,
                message: "Paste a Notion personal access token. Keep its page access narrow; Stickman stores it only in macOS Keychain.",
                setupURL: URL(string: "https://www.notion.so/profile/integrations"),
                window: window
            )
        case .slack:
            promptForCredential(
                kind,
                message: "Paste a Slack OAuth token from a Stickman Slack app. Start with read-only scopes; sending messages will require a separate confirmation.",
                setupURL: URL(string: "https://api.slack.com/apps"),
                window: window
            )
        case .canvas:
            promptForCanvasCredential(window: window)
        }
    }

    func disconnect(_ kind: StickmanConnectorKind) {
        guard let service = kind.credentialService else { return }
        StickmanCredentialStore.shared.remove(service: service)
        notifyChange()
    }

    func localContext(for prompt: String) async -> String? {
        let lower = prompt.lowercased()
        var sections: [String] = []
        if lower.contains("calendar") || lower.contains("class") || lower.contains("meeting")
            || lower.contains("schedule") || lower.contains("homework") {
            if CalendarService.shared.isAuthorized {
                sections.append(CalendarService.shared.upcomingSummary(hours: 72))
            }
        }
        if lower.contains("canvas") || lower.contains("assignment") || lower.contains("homework") {
            if status(for: .canvas) == .connected {
                sections.append(await CanvasService.shared.upcomingSummary())
            }
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    private func promptForCredential(
        _ kind: StickmanConnectorKind,
        message: String,
        setupURL: URL?,
        window: NSWindow?
    ) {
        guard let service = kind.credentialService else { return }
        let alert = NSAlert()
        alert.messageText = "Connect \(kind.title)"
        alert.informativeText = message
        alert.addButton(withTitle: "Save token")
        alert.addButton(withTitle: "Open setup page")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        field.placeholderString = "Token is stored in macOS Keychain"
        alert.accessoryView = field

        present(alert, window: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty { _ = StickmanCredentialStore.shared.save(token, service: service) }
                self?.notifyChange()
            } else if response == .alertSecondButtonReturn, let setupURL {
                NSWorkspace.shared.open(setupURL)
            }
        }
    }

    private func promptForCanvasCredential(window: NSWindow?) {
        guard let service = StickmanConnectorKind.canvas.credentialService else { return }
        let alert = NSAlert()
        alert.messageText = "Connect Canvas"
        alert.informativeText = "Enter the HTTPS address your school uses for Canvas and a personal access token from Canvas Account → Settings. Stickman starts with read-only upcoming coursework."
        alert.addButton(withTitle: "Save connection")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 62)

        let urlField = NSTextField(string: CanvasService.shared.baseURL?.absoluteString ?? "")
        urlField.placeholderString = "https://canvas.yourschool.edu"
        let tokenField = NSSecureTextField(string: "")
        tokenField.placeholderString = "Canvas access token (stored in Keychain)"
        stack.addArrangedSubview(urlField)
        stack.addArrangedSubview(tokenField)
        alert.accessoryView = stack

        present(alert, window: window) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let baseURL = CanvasService.normalizedBaseURL(from: urlField.stringValue)
            else { return }
            let token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return }
            UserDefaults.standard.set(baseURL.absoluteString, forKey: CanvasService.baseURLDefaultsKey)
            _ = StickmanCredentialStore.shared.save(token, service: service)
            self?.notifyChange()
        }
    }

    private func showSetupMessage(title: String, message: String, setupURL: URL?, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Open setup page")
        alert.addButton(withTitle: "Not now")
        present(alert, window: window) { response in
            if response == .alertFirstButtonReturn, let setupURL {
                NSWorkspace.shared.open(setupURL)
            }
        }
    }

    private func present(_ alert: NSAlert, window: NSWindow?, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .stickmanConnectorsDidChange, object: self)
    }
}
