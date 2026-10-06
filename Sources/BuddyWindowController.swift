import AppKit
import CoreGraphics
import QuartzCore

/// Owns Stickman's transparent character window, runs his physics every frame, and
/// presents the chat and settings panel beside him.
final class StickmanWindowController: NSWindowController, CombatDirectorDelegate {
    private let characterSize = NSSize(width: StickmanMetrics.characterSize, height: StickmanMetrics.characterSize)
    private let stickmanView: StickmanView
    private let panel = StickmanCompanionPanelController()
    private let locomotion: StickmanLocomotion
    private lazy var combatDirector = CombatDirector(delegate: self)

    private var tickTimer: Timer?
    private var lastTickAt: TimeInterval = 0
    private var lastWorldScanAt: TimeInterval = 0
    private var windows: [StickmanWindowSnapshot] = []
    private var anchor: (id: CGWindowID, frame: NSRect)?
    private var dragOffset = CGVector.zero
    private var hasBeenPlaced = false
    private var positionBeforeHide: CGPoint?
    private var isShown = false
    private(set) var isHiddenForScreenShare = false
    private var settingsReturnsToChat = false

    private var stillSince: TimeInterval = 0
    private var nextIdleBehaviorAt: TimeInterval = 0
    private var nextGlanceAt: TimeInterval = 0

    private var observers: [NSObjectProtocol] = []
    private var windowAffinityTimer: Timer?
    private var trackedWindowIdentity: String?
    private var trackedWindowSince: TimeInterval = 0
    private var missingWindowSince: TimeInterval?
    private var seatedWindowIdentity: String?
    private var pendingPerch: PerchTarget?
    private let perchDelay: TimeInterval = {
        guard let rawValue = ProcessInfo.processInfo.environment["STICKMAN_PERCH_DELAY"],
              let value = TimeInterval(rawValue),
              value >= 1
        else { return 60 }
        return value
    }()
    private let affinityDebugEnabled = ProcessInfo.processInfo.environment["STICKMAN_DEBUG_WINDOW_AFFINITY"] == "1"

    init() {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        locomotion = StickmanLocomotion(position: CGPoint(x: visibleFrame.midX, y: visibleFrame.minY))
        stickmanView = StickmanView(frame: NSRect(origin: .zero, size: characterSize))
        let window = StickmanCharacterWindow(contentRect: NSRect(origin: .zero, size: characterSize))
        window.contentView = stickmanView
        super.init(window: window)
        shouldCascadeWindows = false
        wireCharacter()
        wirePanel()
        installObservers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        tickTimer?.invalidate()
        windowAffinityTimer?.invalidate()
        combatDirector.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: Wiring

    private func wireCharacter() {
        stickmanView.onToggleChat = { [weak self] in self?.toggleChat() }
        stickmanView.onCursorStrike = { [weak self] point in self?.combatDirector.registerDirectStrike(at: point) }
        stickmanView.onDragBegan = { [weak self] point in self?.beginDrag(at: point) }
        stickmanView.onDragMoved = { [weak self] point in self?.continueDrag(to: point) }
        stickmanView.onDragEnded = { [weak self] _ in self?.endDrag() }
        stickmanView.onPoke = { [weak self] in self?.poke() }
    }

    private func wirePanel() {
        let chat = panel.chatView
        chat.onOpenSettings = { [weak self] in
            self?.settingsReturnsToChat = true
            self?.presentPanel(.settings)
        }
        chat.onClose = { [weak self] in self?.closePanel() }
        chat.onActivityChanged = { [weak self] activity in self?.stickmanView.setActivity(activity) }
        chat.onSuccessMoment = { [weak self] in
            self?.stickmanView.showSuccessMoment()
            self?.locomotion.hop(height: 18, now: CACurrentMediaTime())
        }
        chat.onErrorMoment = { [weak self] in self?.stickmanView.showErrorMoment() }
        chat.onScreenGuidance = { markers in ScreenEffectsOverlayController.shared.showGuidance(markers) }
        panel.settingsView.onClose = { [weak self] in
            guard let self else { return }
            if self.settingsReturnsToChat {
                self.presentPanel(.chat)
            } else {
                self.closePanel()
            }
        }
        panel.onEscape = { [weak self] in self?.closePanel() }
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .stickmanModeDidChange, object: nil, queue: .main) { [weak self] notification in
            self?.handleModeChange(notification)
        })
        observers.append(center.addObserver(forName: .stickmanTaskAnimationRequested, object: nil, queue: .main) { [weak self] notification in
            guard let raw = notification.userInfo?["animation"] as? String,
                  let animation = StickmanTaskAnimation(rawValue: raw)
            else { return }
            self?.stickmanView.performTaskAnimation(animation)
            self?.markInteraction()
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.lastWorldScanAt = 0
        })
        observers.append(center.addObserver(forName: .stickmanClaudeSessionDidFinish, object: nil, queue: .main) { [weak self] notification in
            guard let self, let session = notification.userInfo?["session"] as? ClaudeCodeSession else { return }
            self.reactToClaudeUpdate(session, needsAttention: notification.userInfo?["needsAttention"] as? Bool ?? false)
        })
    }

    // MARK: Showing and hiding

    func showStickman() {
        guard let window else { return }
        isShown = true
        guard !isHiddenForScreenShare else { return }
        if !hasBeenPlaced {
            // First appearance: drop in from near the top of the main screen.
            let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            locomotion.place(at: CGPoint(x: frame.midX, y: frame.maxY - characterSize.height - 20))
            hasBeenPlaced = true
        } else if let positionBeforeHide {
            locomotion.place(at: positionBeforeHide)
            self.positionBeforeHide = nil
        }
        scanWorld(now: CACurrentMediaTime())
        applyPosition()

        showWindow(self)
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        window.orderFrontRegardless()
        startTicking()
        combatDirector.start()
        startWindowAffinityTracking()
        markInteraction()
    }

    func hideStickman() {
        guard let window else { return }
        isShown = false
        StickmanModeController.shared.setMode(.peaceful, reason: "hidden")
        closePanel(animated: false)
        positionBeforeHide = locomotion.position
        stopTicking()
        combatDirector.stop()
        stopWindowAffinityTracking()
        window.ignoresMouseEvents = true
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    }

    /// Fades Stickman and his panel out while the screen is shared, and back in afterward.
    func setHiddenForScreenShare(_ hidden: Bool) {
        guard hidden != isHiddenForScreenShare else { return }
        isHiddenForScreenShare = hidden
        guard isShown, let window else { return }

        if hidden {
            StickmanModeController.shared.setMode(.peaceful, reason: "screen share")
            closePanel(animated: false)
            ScreenEffectsOverlayController.shared.clearGuidance()
            stopTicking()
            combatDirector.stop()
            stopWindowAffinityTracking()
            window.ignoresMouseEvents = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                window.animator().alphaValue = 0
            }
        } else {
            scanWorld(now: CACurrentMediaTime())
            applyPosition()
            window.ignoresMouseEvents = false
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                window.animator().alphaValue = 1
            }
            startTicking()
            combatDirector.start()
            startWindowAffinityTracking()
            markInteraction()
        }
    }

    // MARK: Panel

    func toggleChat() {
        if panel.content == .chat {
            closePanel()
        } else {
            presentPanel(.chat)
        }
    }

    func setChatVisible(_ isVisible: Bool) {
        isVisible ? presentPanel(.chat) : closePanel()
    }

    func quickAssist() {
        StickmanModeController.shared.setMode(.peaceful, reason: "quick assist")
        presentPanel(.chat)
        panel.chatView.prepareScreenContext()
        panel.chatView.focusInput()
    }

    func openMenu() {
        StickmanModeController.shared.setMode(.peaceful, reason: "menu shortcut")
        presentPanel(.chat)
    }

    func startVoiceMode() {
        StickmanModeController.shared.setMode(.peaceful, reason: "voice shortcut")
        presentPanel(.chat)
        panel.chatView.startVoiceMode()
    }

    func showAgentStatus() {
        StickmanModeController.shared.setMode(.peaceful, reason: "agent status")
        presentPanel(.chat)
        panel.chatView.showAgentStatus()
    }

    func openSettings() {
        StickmanModeController.shared.setMode(.peaceful, reason: "settings menu")
        settingsReturnsToChat = false
        presentPanel(.settings)
        panel.settingsView.showGeneral()
    }

    func showClaudeSessions() {
        StickmanModeController.shared.setMode(.peaceful, reason: "Claude sessions")
        presentPanel(.chat)
        panel.chatView.showClaudeSessions()
    }

    func openClaudeCodeSettings() {
        StickmanModeController.shared.setMode(.peaceful, reason: "Claude settings")
        settingsReturnsToChat = false
        presentPanel(.settings)
        panel.settingsView.showClaudeCode()
    }

    /// A finished session gets a happy hop; one waiting on the user gets a wave.
    private func reactToClaudeUpdate(_ session: ClaudeCodeSession, needsAttention: Bool) {
        guard isShown, !isHiddenForScreenShare, StickmanModeController.shared.mode == .peaceful else { return }
        markInteraction()
        if needsAttention {
            stickmanView.setFacing(NSEvent.mouseLocation.x - locomotion.position.x)
            stickmanView.playFidget(.wave)
        } else if session.state == "failed" {
            stickmanView.showErrorMoment()
        } else {
            stickmanView.showSuccessMoment()
            locomotion.hop(height: 26, now: CACurrentMediaTime())
        }
    }

    func openPermissions() {
        StickmanModeController.shared.setMode(.peaceful, reason: "permissions menu")
        settingsReturnsToChat = false
        presentPanel(.settings)
        panel.settingsView.showPermissions()
    }

    func openConnections() {
        StickmanModeController.shared.setMode(.peaceful, reason: "connections menu")
        settingsReturnsToChat = false
        presentPanel(.settings)
        panel.settingsView.showConnections()
    }

    func toggleCombatMode() {
        StickmanModeController.shared.toggle(reason: "Option-F")
    }

    private func presentPanel(_ content: StickmanCompanionPanelController.Content) {
        guard let window else { return }
        locomotion.stop()
        clearPerch()
        stickmanView.setRest(.awake)
        panel.present(content, beside: window.frame)
        stickmanView.setFacing(panel.isOnRight ? 1 : -1)
        stickmanView.setChatVisible(content == .chat)
        stickmanView.setActivity(content == .settings ? .working : .quiet)
        markInteraction()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.panel.makeKey()
            switch content {
            case .chat: self.panel.chatView.focusInput()
            case .settings: self.panel.settingsView.focusFirstControl()
            }
        }
    }

    private func closePanel(animated: Bool = true) {
        guard panel.isVisible else { return }
        panel.hide()
        stickmanView.setChatVisible(false)
        stickmanView.setActivity(.quiet)
        markInteraction()
    }

    // MARK: Frame loop

    private func startTicking() {
        guard tickTimer == nil else { return }
        lastTickAt = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(1.0 / 20.0, max(1.0 / 240.0, now - lastTickAt))
        lastTickAt = now

        if now - lastWorldScanAt > 0.25 { scanWorld(now: now) }
        followAnchorWindow()

        for event in locomotion.step(dt: CGFloat(dt), now: now) {
            handle(event, now: now)
        }
        applyPosition()
        updateFacing(now: now)
        stickmanView.updateMotion(currentMotion(now: now), heightAboveGround: heightAboveGround())
        stickmanView.tick(dt: dt)

        if panel.isVisible, let window { panel.follow(window.frame) }
        runIdleBehaviors(now: now)
    }

    private func scanWorld(now: TimeInterval) {
        lastWorldScanAt = now
        windows = Self.onScreenWindows()
        let screens = NSScreen.screens.map(\.visibleFrame)
        let surfaces = StickmanSurfaceMap.build(windows: windows, screens: screens, headroom: locomotion.tuning.bodyHeight + 8)
        locomotion.updateWorld(surfaces: surfaces, screens: screens)
        if case .window(let id) = locomotion.groundedKind, let frame = windows.first(where: { $0.id == id })?.frame {
            anchor = (id, frame)
        }
    }

    /// Rides along with the window he stands on, every frame, so dragging it carries him.
    private func followAnchorWindow() {
        guard case .window(let id) = locomotion.groundedKind else {
            anchor = nil
            return
        }
        guard let frame = Self.frame(ofWindow: id) else {
            lastWorldScanAt = 0
            return
        }
        if let anchor, anchor.id == id, anchor.frame != frame {
            locomotion.carry(window: id, by: CGVector(dx: frame.minX - anchor.frame.minX, dy: frame.maxY - anchor.frame.maxY))
        }
        anchor = (id, frame)
    }

    private func handle(_ event: StickmanLocomotion.Event, now: TimeInterval) {
        switch event {
        case .landed(let impact):
            lastWorldScanAt = 0
            if impact > 160 { stickmanView.playLanding(impact: impact) }
            if impact > 1500, StickmanModeController.shared.mode == .peaceful {
                let feet = locomotion.position
                ScreenEffectsOverlayController.shared.showImpact(at: feet, strength: min(1.2, impact / 2600))
            }
            if !locomotion.isBusy { stillSince = now }
        case .arrived:
            stillSince = now
            nextIdleBehaviorAt = max(nextIdleBehaviorAt, now + Double.random(in: 6 ... 14))
            completePerchIfNeeded()
        case .launched, .startedFalling:
            break
        }
    }

    private func applyPosition() {
        guard let window else { return }
        let position = locomotion.position
        let origin = NSPoint(
            x: (position.x - characterSize.width / 2).rounded(),
            y: (position.y - StickmanMetrics.footInset).rounded()
        )
        if window.frame.origin != origin { window.setFrameOrigin(origin) }
    }

    private func currentMotion(now: TimeInterval) -> StickmanMotion {
        switch locomotion.state {
        case .grounded:
            return .grounded(velocityX: locomotion.velocity.dx)
        case .crouching(_, _, _, let started, let until):
            return .crouching(progress: CGFloat((now - started) / max(0.01, until - started)))
        case .airborne(let target):
            return .airborne(velocity: locomotion.velocity, planned: target != nil)
        case .held:
            return .held(velocity: locomotion.velocity)
        }
    }

    private func heightAboveGround() -> CGFloat {
        guard !locomotion.isGrounded else { return 0 }
        let below = StickmanSurfaceMap.support(at: locomotion.position, in: locomotion.surfaces)
        return locomotion.position.y - (below?.y ?? locomotion.position.y)
    }

    private func updateFacing(now: TimeInterval) {
        switch locomotion.state {
        case .grounded:
            if abs(locomotion.velocity.dx) > 5 {
                stickmanView.setFacing(locomotion.velocity.dx)
            } else if panel.isVisible {
                stickmanView.setFacing(panel.isOnRight ? 1 : -1)
            } else {
                glanceAtCursorIfNear(now: now)
            }
        case .crouching(_, let launch, _, _, _):
            if abs(launch.dx) > 20 { stickmanView.setFacing(launch.dx) }
        case .airborne:
            if abs(locomotion.velocity.dx) > 60 { stickmanView.setFacing(locomotion.velocity.dx) }
        case .held:
            break
        }
    }

    private func glanceAtCursorIfNear(now: TimeInterval) {
        guard now >= nextGlanceAt,
              stickmanView.currentRest == .awake,
              stickmanView.isAvailableForIdleBehavior,
              StickmanModeController.shared.mode == .peaceful
        else { return }
        let cursor = NSEvent.mouseLocation
        let center = CGPoint(x: locomotion.position.x, y: locomotion.position.y + 50)
        let dx = cursor.x - center.x
        guard abs(dx) > 40, hypot(dx, cursor.y - center.y) < 360 else { return }
        if (dx > 0 ? 1 : -1) != stickmanView.facingDirection {
            stickmanView.setFacing(dx)
            nextGlanceAt = now + Double.random(in: 2.5 ... 5)
        }
    }

    // MARK: Idle life

    private func markInteraction() {
        let now = CACurrentMediaTime()
        stillSince = now
        nextIdleBehaviorAt = now + Double.random(in: 14 ... 30)
        if stickmanView.currentRest != .awake, seatedWindowIdentity == nil {
            stickmanView.setRest(.awake)
        }
    }

    private func runIdleBehaviors(now: TimeInterval) {
        guard StickmanModeController.shared.mode == .peaceful,
              !panel.isVisible,
              locomotion.isGrounded,
              !locomotion.isBusy,
              pendingPerch == nil
        else {
            if locomotion.isBusy { stillSince = now }
            return
        }

        // Settle down when nothing has happened for a while.
        let stillFor = now - stillSince
        let rest = stickmanView.currentRest
        if stillFor > 420, rest != .sleeping {
            stickmanView.setRest(.sleeping)
        } else if stillFor > 150, rest == .awake {
            stickmanView.setRest(.sitting)
        }

        guard stickmanView.currentRest == .awake,
              seatedWindowIdentity == nil,
              stickmanView.isAvailableForIdleBehavior,
              now >= nextIdleBehaviorAt
        else { return }

        nextIdleBehaviorAt = now + Double.random(in: 22 ... 50)
        let wanders = StickmanSettingsPanelView.allowsWandering
        let roll = Int.random(in: 0 ..< 100)
        if wanders, roll < 42, strollAlongLedge() { return }
        if wanders, roll < 58, hopToNearbyLedge() { return }
        if roll < 92 { playFidget() }
    }

    @discardableResult
    private func strollAlongLedge() -> Bool {
        guard let kind = locomotion.groundedKind,
              let ledge = locomotion.surfaces.first(where: { $0.kind == kind && $0.contains(x: locomotion.position.x, margin: 4) })
        else { return false }
        let inset = locomotion.tuning.edgeInset + 10
        let low = max(ledge.minX + inset, locomotion.position.x - 320)
        let high = min(ledge.maxX - inset, locomotion.position.x + 320)
        guard high - low > 120 else { return false }
        var target = CGFloat.random(in: low ... high)
        if abs(target - locomotion.position.x) < 60 {
            target = target < locomotion.position.x ? max(low, target - 80) : min(high, target + 80)
        }
        locomotion.go(to: .init(kind: kind, x: target))
        return true
    }

    @discardableResult
    private func hopToNearbyLedge() -> Bool {
        let here = locomotion.position
        let candidates = locomotion.surfaces.filter { surface in
            guard surface.kind != locomotion.groundedKind, surface.maxX - surface.minX > 140 else { return false }
            let dx = surface.distance(toX: here.x)
            let dy = surface.y - here.y
            return dx < 360 && dy < 420 && dy > -600
        }
        guard let target = candidates.randomElement() else { return false }
        let x = target.clampedX(here.x + CGFloat.random(in: -140 ... 140), inset: locomotion.tuning.edgeInset + 10)
        locomotion.go(to: .init(kind: target.kind, x: x))
        return true
    }

    private func playFidget() {
        let cursor = NSEvent.mouseLocation
        let cursorNearby = hypot(cursor.x - locomotion.position.x, cursor.y - locomotion.position.y - 50) < 420
        var options: [StickmanFidget] = [.lookAround, .stretch, .tapFoot]
        if cursorNearby { options.append(.wave) }
        let fidget = options.randomElement() ?? .stretch
        if fidget == .wave { stickmanView.setFacing(cursor.x - locomotion.position.x) }
        stickmanView.playFidget(fidget)
    }

    // MARK: Pointer

    private func beginDrag(at point: CGPoint) {
        guard StickmanModeController.shared.mode == .peaceful else { return }
        clearPerch()
        stickmanView.setRest(.awake)
        dragOffset = CGVector(dx: locomotion.position.x - point.x, dy: locomotion.position.y - point.y)
        locomotion.beginHold(now: CACurrentMediaTime())
        markInteraction()
    }

    private func continueDrag(to point: CGPoint) {
        locomotion.hold(at: CGPoint(x: point.x + dragOffset.dx, y: point.y + dragOffset.dy), now: CACurrentMediaTime())
        applyPosition()
    }

    private func endDrag() {
        scanWorld(now: CACurrentMediaTime())
        locomotion.release(now: CACurrentMediaTime())
        markInteraction()
    }

    private func poke() {
        guard StickmanModeController.shared.mode == .peaceful, locomotion.isGrounded else { return }
        let wasResting = stickmanView.currentRest != .awake
        clearPerch()
        stickmanView.setRest(.awake)
        stickmanView.setFacing(NSEvent.mouseLocation.x - locomotion.position.x)
        locomotion.hop(height: wasResting ? 34 : 22, now: CACurrentMediaTime())
        markInteraction()
    }

    /// Right-click destination. Stickman walks there, leaping onto or off windows as needed.
    func walkStickman(to screenPoint: NSPoint) {
        guard StickmanModeController.shared.mode == .peaceful, !panel.isVisible else { return }
        if case .held = locomotion.state { return }
        scanWorld(now: CACurrentMediaTime())
        guard let destination = StickmanSurfaceMap.destination(for: screenPoint, windows: windows, surfaces: locomotion.surfaces) else { return }
        pendingPerch = nil
        seatedWindowIdentity = nil
        stickmanView.setRest(.awake)
        locomotion.go(to: .init(kind: destination.kind, x: screenPoint.x))
        markInteraction()
    }

    // MARK: Sparring

    var combatCharacterFrame: NSRect? {
        window?.frame
    }

    func combatDirector(_ director: CombatDirector, perform move: StickmanCombatMove) {
        stickmanView.performCombatMove(move)
    }

    func combatDirector(_ director: CombatDirector, applyWindowImpulse impulse: CGVector) {
        // Knockback launches him; gravity brings him back down.
        locomotion.impulse(CGVector(dx: impulse.dx * 8, dy: max(240, impulse.dy * 8 + 200)))
    }

    private func handleModeChange(_ notification: Notification) {
        guard let raw = notification.userInfo?["mode"] as? String,
              let mode = StickmanMode(rawValue: raw),
              let window
        else { return }

        locomotion.stop()
        clearPerch()
        stickmanView.setMode(mode)
        if mode == .sparring { closePanel() }
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        ScreenEffectsOverlayController.shared.showModeTransition(at: center, enteringCombat: mode == .sparring)
        if mode == .sparring {
            stickmanView.performCombatMove(.guardStance)
        } else {
            ScreenEffectsOverlayController.shared.clearGuidance()
        }
        markInteraction()
    }

    // MARK: Window affinity

    private func startWindowAffinityTracking() {
        guard windowAffinityTimer == nil else { return }
        trackedWindowSince = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.stepWindowAffinity() }
        RunLoop.main.add(timer, forMode: .common)
        windowAffinityTimer = timer
        stepWindowAffinity()
    }

    private func stopWindowAffinityTracking() {
        windowAffinityTimer?.invalidate()
        windowAffinityTimer = nil
        trackedWindowIdentity = nil
        trackedWindowSince = 0
        missingWindowSince = nil
        clearPerch()
    }

    private func stepWindowAffinity() {
        guard StickmanModeController.shared.mode == .peaceful else { return }
        let context = DesktopContextProvider.shared.currentContext()
        let now = ProcessInfo.processInfo.systemUptime
        guard let identity = context.stableWindowIdentity,
              let windowNumber = context.windowNumber,
              let frame = context.windowFrame,
              frame.width >= 240,
              frame.height >= 160
        else {
            if missingWindowSince == nil {
                missingWindowSince = now
                affinityLog("Foreground window temporarily unavailable; waiting for a stable change.")
            }
            guard now - (missingWindowSince ?? now) >= 2.5,
                  trackedWindowIdentity != nil || seatedWindowIdentity != nil || pendingPerch != nil
            else { return }
            affinityLog("Foreground window remained unavailable; leaving the perch.")
            leavePerch()
            trackedWindowIdentity = nil
            trackedWindowSince = now
            return
        }

        missingWindowSince = nil
        if identity != trackedWindowIdentity {
            affinityLog("Tracking \(identity).")
            leavePerch()
            trackedWindowIdentity = identity
            trackedWindowSince = now
            return
        }

        guard !panel.isVisible,
              seatedWindowIdentity == nil,
              pendingPerch == nil,
              !locomotion.isBusy,
              now - trackedWindowSince >= perchDelay
        else { return }

        beginPerching(windowNumber: windowNumber, frame: frame, identity: identity)
    }

    /// Walks to the focused window's top-right corner and sits down there.
    private func beginPerching(windowNumber: CGWindowID, frame: NSRect, identity: String) {
        scanWorld(now: CACurrentMediaTime())
        let kind = StickmanSurface.Kind.window(windowNumber)
        guard locomotion.surfaces.contains(where: { $0.kind == kind }) else {
            affinityLog("Window top is covered or too close to the menu bar; staying put.")
            trackedWindowSince = ProcessInfo.processInfo.systemUptime
            return
        }
        affinityLog("Perching on \(identity) after \(perchDelay) seconds.")
        pendingPerch = PerchTarget(identity: identity, kind: kind)
        stickmanView.setRest(.awake)
        locomotion.go(to: .init(kind: kind, x: frame.maxX - 48))
        if locomotion.groundedKind == kind, !locomotion.isBusy { completePerchIfNeeded() }
    }

    private func completePerchIfNeeded() {
        guard let pendingPerch else { return }
        self.pendingPerch = nil
        guard locomotion.groundedKind == pendingPerch.kind,
              DesktopContextProvider.shared.currentContext().stableWindowIdentity == pendingPerch.identity,
              StickmanModeController.shared.mode == .peaceful,
              !panel.isVisible
        else { return }
        seatedWindowIdentity = pendingPerch.identity
        stickmanView.setRest(.sitting)
    }

    private func leavePerch() {
        guard seatedWindowIdentity != nil || pendingPerch != nil else { return }
        let wasSeated = seatedWindowIdentity != nil
        clearPerch()
        guard wasSeated, !panel.isVisible else { return }
        stickmanView.setRest(.awake)
        markInteraction()
        // Stretch his legs after sitting for a while.
        if StickmanSettingsPanelView.allowsWandering { strollAlongLedge() }
    }

    private func clearPerch() {
        if pendingPerch != nil { locomotion.stop() }
        pendingPerch = nil
        if seatedWindowIdentity != nil {
            seatedWindowIdentity = nil
            stickmanView.setRest(.awake)
        }
    }

    private func affinityLog(_ message: String) {
        guard affinityDebugEnabled else { return }
        print("[Stickman window affinity] \(message)")
    }

    // MARK: Window server queries

    private static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
    }

    /// Normal on-screen windows from other apps, front to back, in AppKit coordinates.
    private static func onScreenWindows() -> [StickmanWindowSnapshot] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let height = primaryScreenHeight
        return info.compactMap { window in
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner != ownPID,
                  let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = window[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width >= 140, bounds.height >= 80
            else { return nil }
            if let alpha = window[kCGWindowAlpha as String] as? Double, alpha < 0.05 { return nil }
            return StickmanWindowSnapshot(
                id: number,
                frame: NSRect(x: bounds.minX, y: height - bounds.maxY, width: bounds.width, height: bounds.height)
            )
        }
    }

    private static func frame(ofWindow id: CGWindowID) -> NSRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let window = info.first,
              (window[kCGWindowIsOnscreen as String] as? Bool) ?? true,
              let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
        else { return nil }
        return NSRect(x: bounds.minX, y: primaryScreenHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }
}

private struct PerchTarget {
    let identity: String
    let kind: StickmanSurface.Kind
}

private final class StickmanCharacterWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        worksWhenModal = true
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = false
        isMovableByWindowBackground = false
    }

    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { true }
}
