import Foundation
import Testing
@testable import NightLockCore

struct NightLockCoreTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test func bedtimeScheduleCrossesMidnight() {
        let schedule = NightLockSchedule(startHour: 22, startMinute: 0, endHour: 5, endMinute: 0)
        #expect(!schedule.isActive(at: Self.date(hour: 21, minute: 59), calendar: Self.calendar))
        #expect(schedule.isActive(at: Self.date(hour: 22, minute: 0), calendar: Self.calendar))
        #expect(schedule.isActive(at: Self.date(hour: 2, minute: 30), calendar: Self.calendar))
        #expect(schedule.isActive(at: Self.date(hour: 4, minute: 59), calendar: Self.calendar))
        #expect(!schedule.isActive(at: Self.date(hour: 5, minute: 0), calendar: Self.calendar))
    }

    @Test func domainMatchingRejectsLookalikes() {
        #expect(NightLockFiles.blockedDomain(for: "https://m.youtube.com/watch?v=1", domains: NightLockConfig.defaultDomains) == "youtube.com")
        #expect(NightLockFiles.blockedDomain(for: "https://old.reddit.com", domains: NightLockConfig.defaultDomains) == "reddit.com")
        #expect(NightLockFiles.blockedDomain(for: "https://www.netflix.com/browse", domains: NightLockConfig.defaultDomains) == "netflix.com")
        #expect(NightLockFiles.blockedDomain(for: "https://m.facebook.com", domains: NightLockConfig.defaultDomains) == "facebook.com")
        #expect(NightLockFiles.blockedDomain(for: "https://notreddit.com", domains: NightLockConfig.defaultDomains) == nil)
    }

    @Test func recoveryHashIsStableAndKeySensitive() {
        let hash = RecoveryKeyVerifier.hash(key: "ABC123", salt: "salt")
        #expect(RecoveryKeyVerifier.verify(key: "abc123", salt: "salt", expectedHash: hash))
        #expect(!RecoveryKeyVerifier.verify(key: "abc124", salt: "salt", expectedHash: hash))
    }

    private static func date(hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 17,
            hour: hour,
            minute: minute
        ))!
    }
}
