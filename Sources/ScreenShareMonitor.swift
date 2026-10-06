import AppKit

extension Notification.Name {
    static let stickmanScreenShareDidChange = Notification.Name("StickmanScreenShareDidChange")
}

/// Turns the raw "something is capturing the screen" signal into a steady sharing state.
/// One-off screenshots last a fraction of a second, so capture must persist before it
/// counts, and a share must stay off for a moment before Stickman comes back.
struct ScreenShareDebouncer {
    var startDelay: TimeInterval = 0.6
    var stopDelay: TimeInterval = 2.0
    private(set) var isSharing = false
    private var changedSince: TimeInterval?
    private var ignoreUntil: TimeInterval = 0

    /// Ignore capture that Stickman itself starts, such as screen context for a question.
    mutating func ignoreCapture(until time: TimeInterval) {
        ignoreUntil = max(ignoreUntil, time)
    }

    /// Returns true when the steady state flips.
    mutating func update(rawCapturing: Bool, now: TimeInterval) -> Bool {
        let capturing = rawCapturing && now >= ignoreUntil
        guard capturing != isSharing else {
            changedSince = nil
            return false
        }
        let since = changedSince ?? now
        changedSince = since
        guard now - since >= (capturing ? startDelay : stopDelay) else { return false }
        isSharing = capturing
        changedSince = nil
        return true
    }
}

/// Detects when the screen is being shared or recorded: Zoom, Meet, Teams, QuickTime, OBS,
/// or macOS Screen Sharing. macOS has no public API for this, so it reads the window
/// server's capture count through the private `CGSIsScreenWatcherPresent`, the signal
/// behind the purple recording indicator. If the symbol ever disappears, detection turns off.
final class ScreenShareMonitor {
    static let shared = ScreenShareMonitor()

    private typealias WatcherProbe = @convention(c) () -> DarwinBoolean

    private static let probe: WatcherProbe? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        for name in ["CGSIsScreenWatcherPresent", "SLSIsScreenWatcherPresent"] {
            if let symbol = dlsym(defaultHandle, name) {
                return unsafeBitCast(symbol, to: WatcherProbe.self)
            }
        }
        return nil
    }()

    static var isSupported: Bool { probe != nil }

    var isSharing: Bool { debouncer.isSharing }

    private var debouncer = ScreenShareDebouncer()
    private var timer: Timer?

    private init() {}

    func start() {
        guard Self.isSupported, timer == nil else { return }
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func ignoreOwnCapture(for seconds: TimeInterval = 2.5) {
        debouncer.ignoreCapture(until: ProcessInfo.processInfo.systemUptime + seconds)
    }

    private func poll() {
        guard let probe = Self.probe else { return }
        let changed = debouncer.update(rawCapturing: probe().boolValue, now: ProcessInfo.processInfo.systemUptime)
        if changed {
            NotificationCenter.default.post(name: .stickmanScreenShareDidChange, object: self)
        }
    }
}
