import Foundation
import Testing
@testable import Stickman

struct WebsiteBlockerTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test func nightScheduleIsActiveAcrossMidnight() {
        let schedule = WebsiteBlockerSchedule(startHour: 23, startMinute: 0, endHour: 6, endMinute: 0)

        #expect(!schedule.isActive(at: Self.date(hour: 22, minute: 59), calendar: Self.calendar))
        #expect(schedule.isActive(at: Self.date(hour: 23, minute: 0), calendar: Self.calendar))
        #expect(schedule.isActive(at: Self.date(hour: 0, minute: 30), calendar: Self.calendar))
        #expect(schedule.isActive(at: Self.date(hour: 5, minute: 59), calendar: Self.calendar))
        #expect(!schedule.isActive(at: Self.date(hour: 6, minute: 0), calendar: Self.calendar))
    }

    @Test func domainMatcherBlocksExactAndSubdomainsOnly() {
        let domains = ["youtube.com", "x.com", "reddit.com", "facebook.com"]

        #expect(WebsiteBlockerDomainMatcher.blockedDomain(for: "https://reddit.com/r/swift", blockedDomains: domains) == "reddit.com")
        #expect(WebsiteBlockerDomainMatcher.blockedDomain(for: "https://old.reddit.com/r/swift", blockedDomains: domains) == "reddit.com")
        #expect(WebsiteBlockerDomainMatcher.blockedDomain(for: "https://m.youtube.com/watch?v=1", blockedDomains: domains) == "youtube.com")
        #expect(WebsiteBlockerDomainMatcher.blockedDomain(for: "https://notreddit.com", blockedDomains: domains) == nil)
        #expect(WebsiteBlockerDomainMatcher.blockedDomain(for: "https://youtube.com.example.com", blockedDomains: domains) == nil)
    }

    @Test func domainNormalizationAcceptsCommonUserInput() {
        #expect(WebsiteBlockerDomainMatcher.normalizedDomain("https://www.Reddit.com/r/all") == "reddit.com")
        #expect(WebsiteBlockerDomainMatcher.normalizedDomain(" x.com. ") == "x.com")
    }

    @Test func existingBlockerSettingsRemainDecodableAfterFocusUpgrade() throws {
        let data = Data(#"{"enabled":true,"startHour":23,"startMinute":0,"endHour":6,"endMinute":0,"blockedDomains":["youtube.com"],"snoozeUntil":null}"#.utf8)
        let settings = try JSONDecoder().decode(WebsiteBlockerSettings.self, from: data)

        #expect(settings.enabled)
        #expect(settings.focusSessionUntil == nil)
        #expect(settings.focusBlockedDomains == nil)
    }

    private static func date(hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 5,
            day: 11,
            hour: hour,
            minute: minute
        ))!
    }
}
