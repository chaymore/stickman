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

    @Test func equalScheduleIsAlwaysActive() {
        let schedule = NightLockSchedule(startHour: 0, startMinute: 0, endHour: 0, endMinute: 0)
        #expect(schedule.isActive(at: Self.date(hour: 0, minute: 0), calendar: Self.calendar))
        #expect(schedule.isActive(at: Self.date(hour: 12, minute: 0), calendar: Self.calendar))
        #expect(schedule.isActive(at: Self.date(hour: 23, minute: 59), calendar: Self.calendar))
        #expect(schedule.displayText == "Always on")
    }

    @Test func domainMatchingRejectsLookalikes() {
        #expect(NightLockFiles.blockedDomain(for: "https://m.youtube.com/watch?v=1", domains: NightLockConfig.defaultDomains) == "youtube.com")
        #expect(NightLockFiles.blockedDomain(for: "https://old.reddit.com", domains: NightLockConfig.defaultDomains) == "reddit.com")
        #expect(NightLockFiles.blockedDomain(for: "https://www.netflix.com/browse", domains: NightLockConfig.defaultDomains) == "netflix.com")
        #expect(NightLockFiles.blockedDomain(for: "https://m.facebook.com", domains: NightLockConfig.defaultDomains) == nil)
        #expect(NightLockFiles.blockedDomain(for: "https://www.messenger.com", domains: NightLockConfig.defaultDomains) == "messenger.com")
        #expect(NightLockFiles.blockedDomain(for: "https://www.linkedin.com/feed", domains: NightLockConfig.defaultDomains) == "linkedin.com")
        #expect(NightLockFiles.blockedDomain(for: "https://x.com/home", domains: NightLockConfig.defaultDomains) == "x.com")
        #expect(NightLockFiles.blockedDomain(for: "https://twitter.com/home", domains: NightLockConfig.defaultDomains) == "twitter.com")
        #expect(NightLockFiles.blockedDomain(for: "https://notreddit.com", domains: NightLockConfig.defaultDomains) == nil)
    }

    @Test func recoveryHashIsStableAndKeySensitive() {
        let hash = RecoveryKeyVerifier.hash(key: "ABC123", salt: "salt")
        #expect(RecoveryKeyVerifier.verify(key: "abc123", salt: "salt", expectedHash: hash))
        #expect(!RecoveryKeyVerifier.verify(key: "abc124", salt: "salt", expectedHash: hash))
    }

    @Test func protectedAllowanceResetRequestRoundTrips() throws {
        let request = ProtectedAllowanceResetRequest(recoveryKey: "secret", domain: "instagram.com")
        let data = try NightLockFiles.encoder.encode(request)
        let decoded = try NightLockFiles.decoder.decode(ProtectedAllowanceResetRequest.self, from: data)
        #expect(decoded.id == request.id)
        #expect(decoded.operation == .resetAllowance)
        #expect(decoded.recoveryKey == "secret")
        #expect(decoded.domain == "instagram.com")
    }

    @Test func protectedDailyBypassRequestRoundTrips() throws {
        let request = ProtectedDailyBypassRequest(recoveryKey: "secret", domain: "instagram.com")
        let data = try NightLockFiles.encoder.encode(request)
        let decoded = try NightLockFiles.decoder.decode(ProtectedDailyBypassRequest.self, from: data)
        #expect(decoded.id == request.id)
        #expect(decoded.operation == .bypassForDay)
        #expect(decoded.recoveryKey == "secret")
        #expect(decoded.domain == "instagram.com")
    }

    @Test func allowanceAliasesShareTheirCanonicalBudgets() {
        #expect(NightLockFiles.allowanceKey(for: "facebook.com") == nil)
        #expect(NightLockFiles.allowanceKey(for: "m.facebook.com") == nil)
        #expect(NightLockFiles.allowanceKey(for: "www.fb.com") == nil)
        #expect(NightLockFiles.allowanceKey(for: "messenger.com") == nil)
        #expect(NightLockFiles.allowanceKey(for: "instagram.com") == "instagram.com")
        #expect(NightLockFiles.allowanceKey(for: "m.instagram.com") == "instagram.com")
        #expect(NightLockFiles.allowanceKey(for: "x.com") == "x.com")
        #expect(NightLockFiles.allowanceKey(for: "mobile.twitter.com") == "x.com")
        #expect(NightLockFiles.allowanceKey(for: "t.co") == "x.com")
        #expect(NightLockFiles.allowanceKey(for: "www.linkedin.com") == "linkedin.com")
        #expect(NightLockFiles.allowanceKey(for: "youtube.com") == "youtube.com")
        #expect(NightLockFiles.allowanceKey(for: "m.youtube.com") == "youtube.com")
        #expect(NightLockFiles.allowanceKey(for: "youtu.be") == "youtube.com")
    }

    @Test func allowancesTrackIndependentContinuousWindows() {
        let now = Self.date(hour: 12, minute: 0)
        let limits = NightLockConfig.defaultDailyAllowanceMinutes
        let ledger = DailyAllowanceLedger(
            dayKey: "2026-08-24",
            entries: [
                "instagram.com": DailyAllowanceEntry(startedAt: now.addingTimeInterval(-125)),
            ]
        )
        #expect(ledger.remainingSeconds(for: "instagram.com", limits: limits, at: now) == 1_675)
        #expect(ledger.remainingSeconds(for: "x.com", limits: limits, at: now) == 600)
        #expect(ledger.hasActiveWindow(for: "instagram.com", limits: limits, at: now))
        #expect(NightLockConfig.defaultSiteAccessPolicies["instagram.com"]?.allowanceMinutes == 30)
    }

    @Test func xUsesBusinessHoursThenEveningAllowance() {
        let policy = NightLockConfig.defaultSiteAccessPolicies["x.com"]!
        #expect(policy.accessMode(at: Self.date(year: 2026, month: 9, day: 5, hour: 7, minute: 59), calendar: Self.calendar) == .blocked)
        #expect(policy.accessMode(at: Self.date(year: 2026, month: 9, day: 5, hour: 8, minute: 0), calendar: Self.calendar) == .unrestricted)
        #expect(policy.accessMode(at: Self.date(year: 2026, month: 9, day: 5, hour: 16, minute: 59), calendar: Self.calendar) == .unrestricted)
        #expect(policy.accessMode(at: Self.date(year: 2026, month: 9, day: 5, hour: 17, minute: 0), calendar: Self.calendar) == .allowance)
        #expect(policy.accessMode(at: Self.date(year: 2026, month: 9, day: 5, hour: 21, minute: 59), calendar: Self.calendar) == .allowance)
        #expect(policy.accessMode(at: Self.date(year: 2026, month: 9, day: 5, hour: 22, minute: 0), calendar: Self.calendar) == .blocked)
        #expect(policy.accessMode(at: Self.date(year: 2026, month: 9, day: 6, hour: 0, minute: 0), calendar: Self.calendar) == .blocked)
    }

    @Test func youtubeAndLinkedInLockFromTenPMUntilEightAM() {
        for domain in ["youtube.com", "linkedin.com"] {
            let policy = NightLockConfig.defaultSiteAccessPolicies[domain]!
            #expect(policy.accessMode(at: Self.date(year: 2026, month: 9, day: 5, hour: 7, minute: 59), calendar: Self.calendar) == .blocked)
            #expect(policy.accessMode(at: Self.date(year: 2026, month: 9, day: 5, hour: 8, minute: 0), calendar: Self.calendar) == .unrestricted)
            #expect(policy.accessMode(at: Self.date(year: 2026, month: 9, day: 5, hour: 21, minute: 59), calendar: Self.calendar) == .unrestricted)
            #expect(policy.accessMode(at: Self.date(year: 2026, month: 9, day: 5, hour: 22, minute: 0), calendar: Self.calendar) == .blocked)
        }
        #expect(NightLockFiles.allowanceKey(for: "m.youtube.com") == "youtube.com")
        #expect(NightLockFiles.allowanceKey(for: "youtu.be") == "youtube.com")
        #expect(NightLockFiles.allowanceKey(for: "www.linkedin.com") == "linkedin.com")
        #expect(NightLockFiles.allowanceKey(for: "notyoutube.com") == nil)
        let managed = NightLockConfig(recoverySalt: "s", recoveryHash: "h").managedDomains
        #expect(managed == ["instagram.com", "x.com", "youtube.com", "linkedin.com"])
    }

    @Test func allowanceExpiresTenMinutesAfterFirstVisitWithoutHeartbeats() {
        let now = Self.date(hour: 12, minute: 0)
        let limits = ["x.com": 10]
        let ledger = DailyAllowanceLedger(
            dayKey: "2026-08-27",
            entries: [
                "x.com": DailyAllowanceEntry(
                    startedAt: now,
                    lastHeartbeat: now
                ),
            ]
        )
        let halfway = now.addingTimeInterval(300)
        let expiration = now.addingTimeInterval(600)
        #expect(ledger.remainingSeconds(for: "x.com", limits: limits, at: halfway) == 300)
        #expect(ledger.hasActiveWindow(for: "x.com", limits: limits, at: halfway))
        #expect(ledger.remainingSeconds(for: "x.com", limits: limits, at: expiration) == 0)
        #expect(!ledger.hasActiveWindow(for: "x.com", limits: limits, at: expiration))
    }

    @Test func dailyBypassKeepsSiteOpenAfterTimerWouldExpire() {
        let now = Self.date(hour: 12, minute: 0)
        let limits = ["x.com": 10]
        let ledger = DailyAllowanceLedger(
            dayKey: "2026-08-31",
            entries: [
                "x.com": DailyAllowanceEntry(
                    startedAt: now.addingTimeInterval(-3_600),
                    bypassedForDay: true
                ),
            ]
        )
        #expect(ledger.isBypassedForDay("x.com"))
        #expect(ledger.remainingSeconds(for: "x.com", limits: limits, at: now) == 600)
        #expect(ledger.hasActiveWindow(for: "x.com", limits: limits, at: now))
    }

    @Test func legacyTrackedTimeStillReducesAllowance() {
        let now = Self.date(hour: 12, minute: 0)
        let limits = ["instagram.com": 10]
        let ledger = DailyAllowanceLedger(
            dayKey: "2026-08-27",
            entries: ["instagram.com": DailyAllowanceEntry(usedSeconds: 125)]
        )
        #expect(ledger.remainingSeconds(for: "instagram.com", limits: limits, at: now) == 475)
    }

    private static func date(hour: Int, minute: Int) -> Date {
        date(year: 2026, month: 7, day: 17, hour: hour, minute: minute)
    }

    private static func date(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }
}
