import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import EventKit
import UserNotifications

enum StickmanPermissionStatus: String, Equatable {
    case granted
    case limited
    case notRequested
    case denied
    case unavailable

    var title: String {
        switch self {
        case .granted: return "Granted"
        case .limited: return "Limited"
        case .notRequested: return "Not requested"
        case .denied: return "Denied"
        case .unavailable: return "Unavailable"
        }
    }
}

enum StickmanPermissionKind: String, CaseIterable, Identifiable {
    case calendar
    case reminders
    case notifications
    case microphone
    case screenRecording
    case accessibility
    case chromeAutomation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .notifications: return "Notifications"
        case .microphone: return "Microphone"
        case .screenRecording: return "Screen context"
        case .accessibility: return "Window control"
        case .chromeAutomation: return "Chrome control"
        }
    }

    var detail: String {
        switch self {
        case .calendar: return "Read classes, meetings, and focus blocks from Calendar.app."
        case .reminders: return "Create the reminders you explicitly ask Stickman to add."
        case .notifications: return "Show timely class and meeting nudges."
        case .microphone: return "Hear you only while voice mode is active."
        case .screenRecording: return "Capture a screenshot only when you ask for screen help."
        case .accessibility: return "Move the current window when you request it."
        case .chromeAutomation: return "Open, list, and switch tabs only on explicit requests."
        }
    }
}

struct StickmanPermissionSnapshot: Equatable {
    let kind: StickmanPermissionKind
    let status: StickmanPermissionStatus
}

extension Notification.Name {
    static let stickmanPermissionsDidChange = Notification.Name("StickmanPermissionsDidChange")
}

@MainActor
final class PermissionCenterService {
    static let shared = PermissionCenterService()

    private let eventStore = EKEventStore()
    private var notificationStatus: StickmanPermissionStatus = .notRequested

    private init() {
        Task { await refreshNotificationStatus() }
    }

    var snapshots: [StickmanPermissionSnapshot] {
        StickmanPermissionKind.allCases.map { StickmanPermissionSnapshot(kind: $0, status: status(for: $0)) }
    }

    func status(for kind: StickmanPermissionKind) -> StickmanPermissionStatus {
        switch kind {
        case .calendar:
            return Self.eventKitStatus(for: .event)
        case .reminders:
            return Self.eventKitStatus(for: .reminder)
        case .notifications:
            return notificationStatus
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notRequested
            case .denied, .restricted: return .denied
            @unknown default: return .unavailable
            }
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notRequested
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notRequested
        case .chromeAutomation:
            if UserDefaults.standard.bool(forKey: "StickmanChromeAutomationAuthorized") { return .granted }
            return BrowserControlService.shared.isChromeAvailable ? .notRequested : .unavailable
        }
    }

    func request(_ kind: StickmanPermissionKind) {
        StickmanTaskAnimationController.play(.requestPermission)
        switch kind {
        case .calendar:
            requestEventAccess(.event)
        case .reminders:
            requestEventAccess(.reminder)
        case .notifications:
            Task {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
                await refreshNotificationStatus()
            }
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.notifyChange() }
            }
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
            notifyChange()
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            notifyChange()
        case .chromeAutomation:
            do {
                _ = try BrowserControlService.shared.tabs()
                UserDefaults.standard.set(true, forKey: "StickmanChromeAutomationAuthorized")
            } catch {
                openSystemSettings(for: kind)
            }
            notifyChange()
        }
    }

    func openSystemSettings(for kind: StickmanPermissionKind) {
        let anchor: String
        switch kind {
        case .calendar: anchor = "Privacy_Calendars"
        case .reminders: anchor = "Privacy_Reminders"
        case .notifications: anchor = "Notifications"
        case .microphone: anchor = "Privacy_Microphone"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .chromeAutomation: anchor = "Privacy_Automation"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    func refresh() {
        Task { await refreshNotificationStatus() }
        notifyChange()
    }

    private func requestEventAccess(_ entityType: EKEntityType) {
        if #available(macOS 14.0, *) {
            let completion: (Bool, Error?) -> Void = { [weak self] _, _ in
                Task { @MainActor in self?.notifyChange() }
            }
            if entityType == .event {
                eventStore.requestFullAccessToEvents(completion: completion)
            } else {
                eventStore.requestFullAccessToReminders(completion: completion)
            }
        } else {
            eventStore.requestAccess(to: entityType) { [weak self] _, _ in
                Task { @MainActor in self?.notifyChange() }
            }
        }
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: notificationStatus = .granted
        case .denied: notificationStatus = .denied
        case .notDetermined: notificationStatus = .notRequested
        @unknown default: notificationStatus = .unavailable
        }
        notifyChange()
    }

    private static func eventKitStatus(for entityType: EKEntityType) -> StickmanPermissionStatus {
        let status = EKEventStore.authorizationStatus(for: entityType)
        if #available(macOS 14.0, *) {
            switch status {
            case .fullAccess: return .granted
            case .writeOnly: return .limited
            case .notDetermined: return .notRequested
            case .denied, .restricted: return .denied
            @unknown default: return .unavailable
            }
        }
        switch status {
        case .authorized: return .granted
        case .fullAccess: return .granted
        case .writeOnly: return .limited
        case .notDetermined: return .notRequested
        case .denied, .restricted: return .denied
        @unknown default: return .unavailable
        }
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .stickmanPermissionsDidChange, object: self)
    }
}
