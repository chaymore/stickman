import Foundation

extension Notification.Name {
    static let stickmanProactiveStudySettingDidChange = Notification.Name("StickmanProactiveStudySettingDidChange")
}

@MainActor
final class ProactiveStudyService {
    static let shared = ProactiveStudyService()

    private let enabledKey = "StickmanProactiveStudyPrepEnabled"
    private let handledKey = "StickmanHandledStudyEvents"
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            NotificationCenter.default.post(name: .stickmanProactiveStudySettingDidChange, object: self)
            if newValue { checkNow() }
        }
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { _ in
            Task { @MainActor in ProactiveStudyService.shared.checkNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        for name in [Notification.Name.stickmanPermissionsDidChange, .stickmanConnectorsDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in ProactiveStudyService.shared.checkNow() }
            })
        }
        checkNow()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    func checkNow(now: Date = Date()) {
        guard isEnabled, CalendarService.shared.isAuthorized else { return }
        let horizon = now.addingTimeInterval(20 * 60)
        let relevant = CalendarService.shared.events(from: now, to: horizon).filter(Self.isStudyEvent)
        guard !relevant.isEmpty else { return }

        var handled = UserDefaults.standard.dictionary(forKey: handledKey) as? [String: Double] ?? [:]
        handled = handled.filter { now.timeIntervalSince1970 - $0.value < 7 * 86_400 }

        for event in relevant {
            let eventKey = "\(event.id).\(Int(event.startDate.timeIntervalSince1970))"
            guard handled[eventKey] == nil else { continue }

            if ConnectorRegistryService.shared.status(for: .canvas) == .connected {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                _ = BackgroundAgentCoordinator.shared.spawn(
                    prompt: "Prepare the scheduled study block “\(event.title)” at \(formatter.string(from: event.startDate)). Use my Canvas assignments to identify the most relevant work, give me a short starting checklist, and open the most useful direct assignment page in a Chrome tab.",
                    opensBrowserLinks: true
                )
            } else if event.title.lowercased().contains("learning suite"),
                      let url = URL(string: "https://learningsuite.byu.edu/") {
                _ = try? BrowserControlService.shared.openChromeTab(url, activate: false)
            }
            handled[eventKey] = now.timeIntervalSince1970
        }
        UserDefaults.standard.set(handled, forKey: handledKey)
    }

    nonisolated static func isStudyEvent(_ event: StickmanCalendarEvent) -> Bool {
        let text = event.title.lowercased()
        let terms = ["homework", "study", "canvas", "learning suite", "religion", "reading", "assignment"]
        return terms.contains { text.contains($0) }
    }
}
