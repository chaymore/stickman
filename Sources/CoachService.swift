import AppKit
import UserNotifications

extension Notification.Name {
    /// userInfo: "text" (String), "proactive" (Bool).
    static let stickmanCoachDidSpeak = Notification.Name("StickmanCoachDidSpeak")
}

/// Stickman's proactive coach: the harness around a headless Claude Code turn.
///
/// On a timer, after the user settles into a new app, or on request, it builds a snapshot
/// (goals, guidelines, memory, front app, calendar, Claude sessions, focus state), asks Claude
/// for a JSON decision, runs only what `CoachPolicy` approves, and logs everything to
/// `~/Library/Application Support/Stickman/coach`.
@MainActor
final class CoachService {
    static let shared = CoachService()

    private enum Keys {
        static let autonomy = "StickmanCoachAutonomy"
        static let interval = "StickmanCoachIntervalMinutes"
        static let model = "StickmanCoachModel"
        static let startHour = "StickmanCoachStartHour"
        static let endHour = "StickmanCoachEndHour"
        static let askedForGoalsDay = "StickmanCoachAskedForGoalsDay"
    }

    let store = CoachStore(root: CoachStore.defaultRoot)
    private(set) var lastCheckInAt: Date?
    private(set) var lastSpokeAt: Date?
    private(set) var lastError: String?
    private(set) var isCheckingIn = false
    private var timer: Timer?
    private var settleTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var appHistory: [(name: String, at: Date)] = []

    private init() {}

    // MARK: Settings

    var autonomy: CoachAutonomy {
        get { CoachAutonomy(rawValue: UserDefaults.standard.string(forKey: Keys.autonomy) ?? "") ?? .act }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.autonomy)
            if newValue == .off { stopTimers() } else { start() }
        }
    }

    var intervalMinutes: Int {
        let value = UserDefaults.standard.integer(forKey: Keys.interval)
        return value == 0 ? 20 : max(5, min(120, value))
    }

    /// Any Claude Code model alias. Sonnet is quick and cheap enough for a check-in every 20 minutes.
    var model: String { UserDefaults.standard.string(forKey: Keys.model) ?? "sonnet" }

    private var activeHours: ClosedRange<Int> {
        let start = UserDefaults.standard.object(forKey: Keys.startHour) as? Int ?? 7
        let end = UserDefaults.standard.object(forKey: Keys.endHour) as? Int ?? 22
        return min(start, end)...max(start, end)
    }

    // MARK: Lifecycle

    func start() {
        store.prepare()
        guard autonomy != .off, timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(intervalMinutes * 60), repeats: true) { _ in
            Task { @MainActor in await CoachService.shared.checkIn(reason: "regular check-in") }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in CoachService.shared.noteAppSwitch(app) }
        })
        // Give the rest of the app a moment to start, then say good morning if needed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            Task { @MainActor in CoachService.shared.askForGoalsIfNeeded() }
        }
    }

    func stop() { stopTimers() }

    private func stopTimers() {
        timer?.invalidate()
        timer = nil
        settleTimer?.invalidate()
        settleTimer = nil
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
    }

    // MARK: Triggers

    /// After the user has stayed in a newly activated app for 3 minutes, check in early,
    /// unless a check-in happened recently. Catches drifting without polling the screen.
    private func noteAppSwitch(_ app: NSRunningApplication?) {
        guard let name = app?.localizedName, app?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        if appHistory.last?.name != name { appHistory.append((name: name, at: Date())) }
        appHistory = Array(appHistory.suffix(20))
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 3 * 60, repeats: false) { _ in
            Task { @MainActor in
                let coach = CoachService.shared
                guard coach.appHistory.last?.name == name,
                      Date().timeIntervalSince(coach.lastCheckInAt ?? .distantPast) > 8 * 60
                else { return }
                await coach.checkIn(reason: "the user switched to \(name) about 3 minutes ago")
            }
        }
    }

    /// Local, free, and once a day: no model call needed to ask for goals.
    private func askForGoalsIfNeeded() {
        let now = Date()
        let today = CoachStore.day(now)
        guard autonomy != .off, activeHours.contains(Calendar.current.component(.hour, from: now)),
              store.goals(on: now).isEmpty,
              UserDefaults.standard.string(forKey: Keys.askedForGoalsDay) != today,
              !ScreenShareMonitor.shared.isSharing
        else { return }
        UserDefaults.standard.set(today, forKey: Keys.askedForGoalsDay)
        speak("Morning! What are one to three goals for today? Tell me with /goals, like: /goals finish the essay intro; run 3 miles", proactive: true)
        store.log("asked for today's goals", at: now)
    }

    // MARK: Check-ins

    /// Runs one check-in. Returns what Stickman said, or nil if he stayed quiet or skipped.
    @discardableResult
    func checkIn(reason: String, userAsked: Bool = false) async -> String? {
        let now = Date()
        if !userAsked {
            askForGoalsIfNeeded()
            guard autonomy != .off,
                  activeHours.contains(Calendar.current.component(.hour, from: now)),
                  !ScreenShareMonitor.shared.isSharing,
                  Self.secondsSinceLastInput() < 10 * 60
            else { return nil }
        }
        guard !isCheckingIn else { return userAsked ? "I'm already thinking about it. Give me a few seconds." : nil }
        isCheckingIn = true
        defer { isCheckingIn = false }
        lastCheckInAt = now

        let snapshot = await makeSnapshot(reason: reason, userAsked: userAsked, now: now)
        let output: String
        do {
            output = try await ClaudeCodeService.shared.runStructured(
                prompt: CoachPrompt.build(snapshot),
                schema: CoachDecision.schema,
                model: model,
                workingDirectory: store.root.path
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastError = message
            store.log("check-in failed (\(reason)): \(message)", at: now)
            return userAsked ? "I couldn't reach Claude for that: \(message)" : nil
        }
        guard let decision = CoachDecision.parse(cliOutput: output) else {
            lastError = "Claude's answer wasn't a valid decision."
            store.log("check-in failed (\(reason)): unreadable decision", at: now)
            return userAsked ? "I got a jumbled answer from Claude. Try /next again." : nil
        }
        lastError = nil
        return apply(decision, reason: reason, userAsked: userAsked, now: now)
    }

    private func apply(_ decision: CoachDecision, reason: String, userAsked: Bool, now: Date) -> String? {
        let (approved, rejected) = CoachPolicy.approve(decision.actions, autonomy: autonomy)
        var done: [String] = []
        for action in approved {
            if let result = run(action) { done.append(result) }
        }
        store.remember(decision.remember, on: now)

        var text = CoachPolicy.clipped(decision.message)
        let step = CoachPolicy.clipped(decision.nextStep)
        if !step.isEmpty, !text.contains(step) {
            text += (text.isEmpty ? "" : "\n\n") + "Next step: \(step)"
        }
        // Actions are never silent: if Stickman changed something, he says so.
        let speaks = !text.isEmpty && (CoachPolicy.shouldSpeak(userAsked: userAsked, lastSpokeAt: lastSpokeAt, now: now) || !done.isEmpty)
        if speaks { speak(text, proactive: !userAsked) }

        var line = "check-in (\(reason)): "
        line += speaks ? "said \"\(text.replacingOccurrences(of: "\n\n", with: " "))\"" : (text.isEmpty ? "stayed quiet" : "held back \"\(text)\"")
        if !done.isEmpty { line += "; did " + done.joined(separator: "; ") }
        if !rejected.isEmpty { line += "; " + rejected.joined(separator: "; ") }
        if !decision.remember.isEmpty { line += "; remembered " + decision.remember.joined(separator: " | ") }
        store.log(line, at: now)
        return speaks ? text : nil
    }

    private func run(_ action: CoachApprovedAction) -> String? {
        switch action {
        case .focus(let minutes, let domains):
            _ = WebsiteBlockerService.shared.startFocusSession(minutes: minutes, extraDomains: domains)
            return action.logDescription
        case .openURL(let url):
            return NSWorkspace.shared.open(url) ? action.logDescription : nil
        case .openApp(let name):
            guard let url = Self.applicationURL(named: name) else { return nil }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return action.logDescription
        }
    }

    private func makeSnapshot(reason: String, userAsked: Bool, now: Date) async -> CoachSnapshot {
        let context = DesktopContextProvider.shared.currentContext()
        let claude = ClaudeCodeService.shared
        if claude.cliURL != nil { await claude.refreshSessions() }
        let sessions = claude.sessions.prefix(8).map { "- \($0.name) in \($0.projectName): \($0.statusTitle)" }
        let calendar = CalendarService.shared.isAuthorized ? CalendarService.shared.upcomingSummary(hours: 6, now: now) : nil
        var minutesInFront: Int?
        if let last = appHistory.last, last.name == context.appName {
            minutesInFront = Int(now.timeIntervalSince(last.at) / 60)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let recent = appHistory.reversed().prefix(8).map { "\($0.name) (\(formatter.string(from: $0.at)))" }

        return CoachSnapshot(
            now: now,
            reason: reason,
            userAsked: userAsked,
            autonomy: autonomy,
            guidelines: store.read(store.guidelinesURL),
            goals: store.goals(on: now),
            memory: store.read(store.memoryURL),
            frontApp: context.appName,
            windowTitle: context.windowTitle,
            minutesInFrontApp: minutesInFront,
            recentApps: recent,
            calendar: calendar,
            claudeSessions: Array(sessions),
            focusStatus: WebsiteBlockerService.shared.focusStatus,
            recentLog: store.recentLog(on: now)
        )
    }

    // MARK: Speaking

    private func speak(_ text: String, proactive: Bool) {
        lastSpokeAt = Date()
        NotificationCenter.default.post(name: .stickmanCoachDidSpeak, object: self, userInfo: ["text": text, "proactive": proactive])
        guard proactive, PermissionCenterService.shared.status(for: .notifications) == .granted else { return }
        let content = UNMutableNotificationContent()
        content.title = "Stickman"
        content.body = text
        let request = UNNotificationRequest(identifier: "stickman.coach.\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Chat commands

    func handle(_ command: CoachCommand) async -> String {
        let now = Date()
        switch command {
        case .showGoals:
            let goals = store.goals(on: now)
            return goals.isEmpty ? "No goals for today yet. Set them with /goals, like: /goals finish the essay intro; run 3 miles" : "Today's goals:\n\n\(goals)"
        case .setGoals(let text):
            store.setGoals(text, on: now)
            store.log("user set goals: \(CoachStore.goalLines(text).joined(separator: " | "))", at: now)
            let reply = await checkIn(reason: "the user just set today's goals", userAsked: true)
            return "Got it. Today's goals:\n\n\(store.goals(on: now))" + (reply.map { "\n\n\($0)" } ?? "")
        case .addGoal(let text):
            CoachStore.goalLines(text).forEach { store.appendGoalNote("- [ ] \($0)", on: now) }
            store.log("user added goal: \(text)", at: now)
            return "Added. Today's goals:\n\n\(store.goals(on: now))"
        case .done(let text):
            store.appendGoalNote("- Done \(Self.timeString(now)): \(text)", on: now)
            store.log("user finished: \(text)", at: now)
            return await checkIn(reason: "the user just finished: \(text)", userAsked: true) ?? "Nice. Logged it."
        case .nextStep:
            return await checkIn(reason: "the user asked for their next small step", userAsked: true) ?? "I couldn't come up with a step. Try again in a moment."
        case .checkInNow:
            return await checkIn(reason: "the user asked for a check-in", userAsked: true) ?? "All good. Nothing to add right now."
        case .setAutonomy(let level):
            autonomy = level
            store.log("user set coach to \(level.title)", at: now)
            switch level {
            case .off: return "Coach is off. Goals and /next still work when you ask."
            case .suggest: return "Coach will check in every \(intervalMinutes) minutes and suggest, but won't change anything."
            case .act: return "Coach is on. Every \(intervalMinutes) minutes I'll check your goals, nudge you, and start focus blocks when you drift."
            }
        case .status:
            var lines = ["Coach: \(autonomy.title), checking in every \(intervalMinutes) min with \(model)."]
            lines.append("Last check-in: " + (lastCheckInAt.map(Self.timeString) ?? "not yet"))
            if let lastError { lines.append("Last problem: \(lastError)") }
            lines.append(WebsiteBlockerService.shared.focusStatus)
            lines.append("Commands: /goals, /goals add, /done, /next, /coach on|suggest|off|now|guidelines|memory|log")
            return lines.joined(separator: "\n")
        case .openGuidelines:
            NSWorkspace.shared.open(store.guidelinesURL)
            return "Opened your guidelines. I read them on every check-in."
        case .openMemory:
            NSWorkspace.shared.open(store.memoryURL)
            return "Opened what I've learned about you. Edit or delete anything."
        case .openLog:
            store.log("user opened the log", at: now)
            NSWorkspace.shared.open(store.logURL(for: now))
            return "Opened today's coach log."
        }
    }

    // MARK: Helpers

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Seconds since the last keyboard or mouse input anywhere. Used to skip check-ins while away.
    private static func secondsSinceLastInput() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    private static func applicationURL(named name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "\(home)/Applications"]
        for folder in folders {
            let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).app")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let wanted = name.lowercased()
        for folder in folders {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            if let match = items.first(where: { $0.lowercased() == "\(wanted).app" }) {
                return URL(fileURLWithPath: folder).appendingPathComponent(match)
            }
        }
        return nil
    }
}
