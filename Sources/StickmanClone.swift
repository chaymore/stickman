import AppKit
import QuartzCore

extension Notification.Name {
    /// Posted when a local Claude Code background session starts. userInfo: "key", "name".
    static let stickmanClaudeCloneRequested = Notification.Name("StickmanClaudeCloneRequested")
}

@MainActor
enum StickmanCloneRequest {
    static func post(sessionKey: String, name: String) {
        NotificationCenter.default.post(
            name: .stickmanClaudeCloneRequested,
            object: nil,
            userInfo: ["key": sessionKey, "name": name]
        )
    }
}

/// One colored copy of Stickman per running Claude Code background session. Each clone
/// splits off Stickman, runs and leaps to the top-right corner, levitates there while the
/// session works, and vanishes when it finishes.
@MainActor
final class StickmanCloneDirector {
    private var clones: [StickmanClone] = []
    private var colorIndex = 0
    private var observer: NSObjectProtocol?
    private var refreshTimer: Timer?
    private var isHidden = false

    /// Claude orange first, then colors that stay readable on light and dark desktops.
    private static let palette: [NSColor] = [
        NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1),
        NSColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 1),
        NSColor(srgbRed: 0.55, green: 0.36, blue: 0.96, alpha: 1),
        NSColor(srgbRed: 0.06, green: 0.65, blue: 0.47, alpha: 1),
        NSColor(srgbRed: 0.93, green: 0.29, blue: 0.6, alpha: 1)
    ]

    /// A session that never shows up in `claude agents` gets cleared after this long.
    private static let unmatchedTimeout: TimeInterval = 15 * 60

    init() {
        observer = NotificationCenter.default.addObserver(forName: .stickmanClaudeSessionsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncWithSessions() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        refreshTimer?.invalidate()
    }

    /// Starts a clone. With an origin it splits off Stickman there; without one it pops in at its spot.
    func spawn(sessionKey: String, name: String, from origin: CGPoint?) {
        guard !clones.contains(where: { $0.sessionKey == sessionKey }) else { return }
        let color = Self.palette[colorIndex % Self.palette.count]
        colorIndex += 1
        let slot = clones.count
        let clone = StickmanClone(
            sessionKey: sessionKey,
            name: name,
            tint: color,
            perch: Self.perchPoint(slot: slot, near: origin)
        )
        clone.onGone = { [weak self, weak clone] in
            guard let self, let clone else { return }
            self.clones.removeAll { $0 === clone }
            if self.clones.isEmpty {
                self.refreshTimer?.invalidate()
                self.refreshTimer = nil
            }
        }
        clones.append(clone)
        clone.start(from: origin, hidden: isHidden)
        startRefreshing()
    }

    /// Claude Code's own polling stops when it loses track of a session, so the clones
    /// keep asking while any of them is up.
    private func startRefreshing() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.clones.isEmpty else { return }
                Task { await ClaudeCodeService.shared.refreshSessions() }
            }
        }
        timer.tolerance = 4
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func session(for clone: StickmanClone, in sessions: [ClaudeCodeSession]) -> ClaudeCodeSession? {
        if let byID = sessions.first(where: { $0.id == clone.sessionKey || $0.sessionID == clone.sessionKey }) { return byID }
        // Fall back to the name, but only for a session started around when the clone was.
        let launched = clone.startedAt.addingTimeInterval(-120)
        return sessions.first { $0.name == clone.name && ($0.startedAt ?? .distantPast) >= launched }
    }

    func setHidden(_ hidden: Bool) {
        isHidden = hidden
        clones.forEach { $0.setHidden(hidden) }
    }

    private func syncWithSessions() {
        let sessions = ClaudeCodeService.shared.sessions
        let now = Date()
        for clone in clones where !clone.isVanishing {
            guard let session = session(for: clone, in: sessions) else {
                if now.timeIntervalSince(clone.startedAt) > Self.unmatchedTimeout { clone.vanish() }
                continue
            }
            clone.matched = true
            if session.needsAttention {
                clone.setNeedsAttention(true)
            } else if session.isFinished || !session.isWorking {
                clone.vanish()
            } else {
                clone.setNeedsAttention(false)
            }
        }
        // A matched session that dropped off the list is gone too.
        for clone in clones where clone.matched && !clone.isVanishing {
            if session(for: clone, in: sessions) == nil { clone.vanish() }
        }
    }

    /// Feet position for a clone's hover spot: the top-right of the screen Stickman is on,
    /// shifting left for each clone already up there.
    private static func perchPoint(slot: Int, near origin: CGPoint?) -> CGPoint {
        let screens = NSScreen.screens
        let screen = origin.flatMap { point in screens.first { $0.frame.minX <= point.x && point.x < $0.frame.maxX } }
            ?? NSScreen.main ?? screens.first
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let figureHeight = StickmanMetrics.characterSize - StickmanMetrics.footInset
        let spacing: CGFloat = 74
        let x = frame.maxX - 56 - CGFloat(slot) * spacing
        let y = frame.maxY - figureHeight - 8 - CGFloat(slot % 2) * 14
        return CGPoint(x: max(frame.minX + 56, x), y: y)
    }
}

@MainActor
private final class StickmanClone {
    let sessionKey: String
    let name: String
    let startedAt = Date()
    var matched = false
    var onGone: (() -> Void)?
    private(set) var isVanishing = false

    private enum Phase {
        case split
        case run
        case crouch
        case leap
        case levitate
        case vanish
    }

    private let view: StickmanView
    private let window: StickmanCloneWindow
    private let perch: CGPoint
    private let gravity: CGFloat = 2300
    private var timer: Timer?
    private var phase: Phase = .levitate
    private var phaseStartedAt: TimeInterval = 0
    private var phaseDuration: TimeInterval = 0
    private var from = CGPoint.zero
    private var to = CGPoint.zero
    private var launch = CGVector.zero
    private var position = CGPoint.zero
    private var lastTickAt: TimeInterval = 0
    private var needsAttention = false
    private var nextWaveAt: TimeInterval = 0
    private var isHidden = false

    init(sessionKey: String, name: String, tint: NSColor, perch: CGPoint) {
        self.sessionKey = sessionKey
        self.name = name
        self.perch = perch
        let size = NSSize(width: StickmanMetrics.characterSize, height: StickmanMetrics.characterSize)
        view = StickmanView(frame: NSRect(origin: .zero, size: size))
        view.tint = tint
        window = StickmanCloneWindow(contentRect: NSRect(origin: .zero, size: size))
        window.contentView = view
    }

    func start(from origin: CGPoint?, hidden: Bool) {
        let now = CACurrentMediaTime()
        isHidden = hidden
        if let origin {
            // Split off sideways, toward the corner he is headed for.
            let direction: CGFloat = perch.x >= origin.x ? 1 : -1
            position = origin
            view.setFacing(direction)
            view.vibrate(for: 0.4)
            view.showBurst()
            begin(.split, at: now, duration: 0.4, from: origin, to: CGPoint(x: origin.x + direction * 46, y: origin.y))
            window.alphaValue = 0
        } else {
            position = perch
            view.showBurst()
            view.setFacing(-1)
            begin(.levitate, at: now, duration: .infinity, from: perch, to: perch)
            window.alphaValue = 0
        }
        place()
        if !hidden { window.orderFrontRegardless() }
        lastTickAt = now
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func setHidden(_ hidden: Bool) {
        isHidden = hidden
        if hidden {
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    func setNeedsAttention(_ value: Bool) {
        needsAttention = value
    }

    func vanish() {
        guard !isVanishing else { return }
        isVanishing = true
        view.showBurst()
        view.vibrate(for: 0.25)
        begin(.vanish, at: CACurrentMediaTime(), duration: 0.5, from: position, to: position)
    }

    private func begin(_ phase: Phase, at now: TimeInterval, duration: TimeInterval, from: CGPoint, to: CGPoint) {
        self.phase = phase
        phaseStartedAt = now
        phaseDuration = duration
        self.from = from
        self.to = to
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(1.0 / 20.0, max(1.0 / 240.0, now - lastTickAt))
        lastTickAt = now
        let elapsed = now - phaseStartedAt
        let progress = CGFloat(min(1, elapsed / max(0.001, phaseDuration)))
        var motion: StickmanMotion = .levitating
        var lift: CGFloat = 300

        switch phase {
        case .split:
            position = SMath.mix(from, to, SMath.easeOutCubic(progress))
            window.alphaValue = min(1, progress * 2)
            motion = .grounded(velocityX: 0)
            lift = 0
        case .run:
            position = SMath.mix(from, to, progress)
            motion = .grounded(velocityX: (to.x - from.x) >= 0 ? 480 : -480)
            lift = 0
        case .crouch:
            motion = .crouching(progress: progress)
            lift = 0
        case .leap:
            let t = CGFloat(min(elapsed, phaseDuration))
            position = CGPoint(x: from.x + launch.dx * t, y: from.y + launch.dy * t - 0.5 * gravity * t * t)
            motion = .airborne(velocity: CGVector(dx: launch.dx, dy: launch.dy - gravity * t), planned: true)
        case .levitate:
            position = perch
            window.alphaValue = min(1, window.alphaValue + CGFloat(dt) * 3)
            if needsAttention, now >= nextWaveAt {
                nextWaveAt = now + 3
                view.playFidget(.wave)
            }
        case .vanish:
            window.alphaValue = 1 - progress
        }

        place()
        view.updateMotion(motion, heightAboveGround: lift)
        view.tick(dt: dt)
        guard progress >= 1 else { return }

        switch phase {
        case .split:
            // Run part of the way, then leap the rest.
            let dx = perch.x - position.x
            let run = max(0, min(240, abs(dx) - 260))
            let end = CGPoint(x: position.x + (dx >= 0 ? run : -run), y: position.y)
            begin(.run, at: now, duration: max(0.05, Double(run / 480)), from: position, to: end)
        case .run:
            begin(.crouch, at: now, duration: 0.12, from: position, to: position)
        case .crouch:
            let jump = StickmanJump.solve(from: position, to: perch, gravity: gravity)
            launch = jump.velocity
            view.setFacing(launch.dx)
            begin(.leap, at: now, duration: jump.duration, from: position, to: perch)
        case .leap:
            view.setFacing(-1)
            begin(.levitate, at: now, duration: .infinity, from: perch, to: perch)
        case .levitate:
            break
        case .vanish:
            timer?.invalidate()
            timer = nil
            window.orderOut(nil)
            window.close()
            onGone?()
        }
    }

    private func place() {
        let origin = NSPoint(
            x: (position.x - StickmanMetrics.characterSize / 2).rounded(),
            y: (position.y - StickmanMetrics.footInset).rounded()
        )
        if window.frame.origin != origin { window.setFrameOrigin(origin) }
    }
}

private final class StickmanCloneWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
