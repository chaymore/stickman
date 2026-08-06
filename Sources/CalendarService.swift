import EventKit
import Foundation

struct StickmanCalendarEvent: Equatable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let calendarTitle: String
    let isAllDay: Bool
}

@MainActor
final class CalendarService {
    static let shared = CalendarService()

    private let eventStore = EKEventStore()
    private let calendar = Calendar.autoupdatingCurrent

    private init() {}

    var isAuthorized: Bool {
        PermissionCenterService.shared.status(for: .calendar) == .granted
    }

    func events(from startDate: Date, to endDate: Date) -> [StickmanCalendarEvent] {
        guard isAuthorized else { return [] }
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        return eventStore.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map {
                StickmanCalendarEvent(
                    id: $0.calendarItemIdentifier,
                    title: $0.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? $0.title : "Untitled event",
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    location: $0.location,
                    calendarTitle: $0.calendar.title,
                    isAllDay: $0.isAllDay
                )
            }
    }

    func todaySummary(now: Date = Date()) -> String {
        guard isAuthorized else {
            return "Calendar access is not connected yet. Open Settings → Permissions and grant Calendar access."
        }
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now.addingTimeInterval(86_400)
        return summary(events: events(from: start, to: end), heading: "Today")
    }

    func upcomingSummary(hours: Int = 24, now: Date = Date()) -> String {
        guard isAuthorized else {
            return "Calendar access is not connected yet. Open Settings → Permissions and grant Calendar access."
        }
        let end = calendar.date(byAdding: .hour, value: max(1, min(hours, 168)), to: now)
            ?? now.addingTimeInterval(Double(hours) * 3_600)
        return summary(events: events(from: now, to: end), heading: "Next \(hours) hours")
    }

    private func summary(events: [StickmanCalendarEvent], heading: String) -> String {
        guard !events.isEmpty else { return "\(heading): your calendar is clear." }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let rows = events.prefix(12).map { event in
            let time = event.isAllDay ? "All day" : formatter.string(from: event.startDate)
            let location = event.location?.isEmpty == false ? " · \(event.location!)" : ""
            return "• \(time) — \(event.title)\(location)"
        }
        let remainder = events.count > 12 ? "\n…and \(events.count - 12) more." : ""
        return "\(heading):\n\(rows.joined(separator: "\n"))\(remainder)"
    }
}
