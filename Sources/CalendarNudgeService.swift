import Foundation
import UserNotifications

@MainActor
final class CalendarNudgeService {
    static let shared = CalendarNudgeService()

    private var refreshTimer: Timer?
    private var permissionObserver: NSObjectProtocol?
    private let identifierPrefix = "stickman.calendar."

    private init() {}

    func start() {
        guard refreshTimer == nil else { return }
        permissionObserver = NotificationCenter.default.addObserver(
            forName: .stickmanPermissionsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        Task { await refresh() }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let permissionObserver { NotificationCenter.default.removeObserver(permissionObserver) }
        permissionObserver = nil
    }

    func refresh(now: Date = Date()) async {
        guard PermissionCenterService.shared.status(for: .calendar) == .granted,
              PermissionCenterService.shared.status(for: .notifications) == .granted
        else { return }

        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let oldIdentifiers = pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: oldIdentifiers)

        let end = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 3, to: now)
            ?? now.addingTimeInterval(3 * 86_400)
        let events = CalendarService.shared.events(from: now, to: end)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .medium

        for event in events where !event.isAllDay {
            let fireDate = event.startDate.addingTimeInterval(-10 * 60)
            guard fireDate > now.addingTimeInterval(20) else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Coming up: \(event.title)"
            let location = event.location?.isEmpty == false ? " · \(event.location!)" : ""
            content.body = "\(formatter.string(from: event.startDate))\(location)"
            content.sound = .default
            content.userInfo = ["calendarEventID": event.id]

            let components = Calendar.autoupdatingCurrent.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let stableID = "\(identifierPrefix)\(event.id).\(Int(event.startDate.timeIntervalSince1970))"
            try? await center.add(UNNotificationRequest(identifier: stableID, content: content, trigger: trigger))
        }
    }
}
