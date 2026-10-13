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
    private let cloneDirector = StickmanCloneDirector()
    private var sleepCorner: SleepCorner?

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
    private(set) var isTuckedInNotch = false
    private var notchMove: NotchMove?
    private var scriptedPosition: CGPoint?
    private var settingsReturnsToChat = false

    private var stillSince: TimeInterval = 0
    private var nextIdleBehaviorAt: TimeInterval = 0

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
            if animation == .dance {
                self?.locomotion.stop()
                self?.clearPerch()
            }
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
        observers.append(center.addObserver(forName: .stickmanClaudeCloneRequested, object: nil, queue: .main) { [weak self] notification in
            guard let self, let key = notification.userInfo?["key"] as? String else { return }
            self.splitOffClone(sessionKey: key, name: notification.userInfo?["name"] as? String ?? key)
        })
        observers.append(center.addObserver(forName: .stickmanComputerUseDidChange, object: nil, queue: .main) { [weak self] notification in
            guard let self else { return }
            self.reactToComputerUse(
                active: notification.userInfo?["active"] as? Bool ?? false,
                stopped: notification.userInfo?["stopped"] as? Bool ?? false
            )
        })
    }

    // MARK: Showing and hiding

    func showStickman() {
        guard let window else { return }
        isShown = true
        guard !isHiddenForScreenShare else { return }
        if isTuckedInNotch {
            comeOutOfNotch()
            return
        }
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
        cloneDirector.setHidden(hidden)
        guard isShown, let window else { return }

        if hidden {
            settleNotchMove()
            guard !isTuckedInNotch else { return }
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
            guard !isTuckedInNotch else { return }
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

    var isVoiceModeActive: Bool { panel.chatView.isVoiceModeActive }

    func stopVoiceMode() {
        panel.chatView.stopVoiceMode()
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
        guard isShown, !isHiddenForScreenShare, !isTuckedInNotch, notchMove == nil,
              StickmanModeController.shared.mode == .peaceful
        else { return }
        markInteraction()
        if needsAttention {
            stickmanView.playFidget(.wave)
        } else if session.state == "failed" {
            stickmanView.showErrorMoment()
        } else {
            stickmanView.showSuccessMoment()
            locomotion.hop(height: 26, now: CACurrentMediaTime())
        }
    }

    /// Stickman looks busy while Claude drives the computer, and startled when the user stops it.
    private func reactToComputerUse(active: Bool, stopped: Bool) {
        if active {
            stickmanView.setActivity(.working)
        } else {
            stickmanView.setActivity(.quiet)
            guard stopped, isShown, !isHiddenForScreenShare, !isTuckedInNotch, notchMove == nil else { return }
            stickmanView.showErrorMoment()
        }
        markInteraction()
    }

    /// Stickman buzzes, then a colored copy of him splits off to go work on the session.
    /// When he's out of sight, the clone just appears at its spot.
    private func splitOffClone(sessionKey: String, name: String) {
        guard isShown, !isHiddenForScreenShare, !isTuckedInNotch, notchMove == nil,
              StickmanModeController.shared.mode == .peaceful
        else {
            cloneDirector.spawn(sessionKey: sessionKey, name: name, from: nil)
            return
        }
        locomotion.stop()
        clearPerch()
        stickmanView.setRest(.awake)
        stickmanView.vibrate(for: 0.6)
        markInteraction()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self else { return }
            self.stickmanView.showBurst()
            let origin = self.isShown && !self.isHiddenForScreenShare && !self.isTuckedInNotch ? self.locomotion.position : nil
            self.cloneDirector.spawn(sessionKey: sessionKey, name: name, from: origin)
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
        if isTuckedInNotch || notchMove != nil { comeOutOfNotch() }
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

        if stepNotchMove(now: now) {
            stickmanView.tick(dt: dt)
            if panel.isVisible, let window { panel.follow(window.frame) }
            return
        }

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
            if impact > 450 {
                ScreenEffectsOverlayController.shared.showLandingDust(at: locomotion.position, strength: impact / 1300)
            }
            if !locomotion.isBusy { stillSince = now }
        case .arrived:
            stillSince = now
            nextIdleBehaviorAt = max(nextIdleBehaviorAt, now + Double.random(in: 6 ... 14))
            completePerchIfNeeded()
            completeSleepCornerIfNeeded()
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
            }
        case .crouching(_, let launch, _, _, _):
            if abs(launch.dx) > 20 { stickmanView.setFacing(launch.dx) }
        case .airborne:
            if abs(locomotion.velocity.dx) > 60 { stickmanView.setFacing(locomotion.velocity.dx) }
        case .held:
            break
        }
    }

    // MARK: Idle life

    private func markInteraction() {
        let now = CACurrentMediaTime()
        stillSince = now
        nextIdleBehaviorAt = now + Double.random(in: 14 ... 30)
        sleepCorner = nil
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
            if !headToSleepingCorner() { stickmanView.setRest(.sleeping) }
            return
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

    /// Walks to the nearer bottom corner of his screen to sleep against the wall there.
    private func headToSleepingCorner() -> Bool {
        let here = locomotion.position
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard let index = screens.firstIndex(where: { $0.minX <= here.x && here.x < $0.maxX })
                ?? screens.indices.min(by: { abs(screens[$0].midX - here.x) < abs(screens[$1].midX - here.x) }),
              let floor = locomotion.surfaces.first(where: { $0.kind == .floor(screen: index) })
        else { return false }
        clearPerch()
        let wallOnRight = here.x > (floor.minX + floor.maxX) / 2
        sleepCorner = SleepCorner(kind: floor.kind, wallOnRight: wallOnRight)
        let x = wallOnRight ? floor.maxX : floor.minX
        let parkedX = floor.clampedX(x, inset: locomotion.tuning.edgeInset)
        if locomotion.groundedKind == floor.kind, abs(here.x - parkedX) < 3 {
            completeSleepCornerIfNeeded()
        } else {
            locomotion.go(to: .init(kind: floor.kind, x: x))
        }
        return true
    }

    private func completeSleepCornerIfNeeded() {
        guard let corner = sleepCorner else { return }
        sleepCorner = nil
        guard locomotion.groundedKind == corner.kind, StickmanModeController.shared.mode == .peaceful, !panel.isVisible else { return }
        // His back goes to the wall, so he faces into the screen.
        stickmanView.setFacing(corner.wallOnRight ? -1 : 1)
        stickmanView.setRest(.sleeping, againstWall: true)
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
        stickmanView.playFidget(fidget)
    }

    // MARK: Pointer

    private func beginDrag(at point: CGPoint) {
        guard StickmanModeController.shared.mode == .peaceful, notchMove == nil else { return }
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
        guard StickmanModeController.shared.mode == .peaceful, locomotion.isGrounded, notchMove == nil else { return }
        let wasResting = stickmanView.currentRest != .awake
        clearPerch()
        stickmanView.setRest(.awake)
        locomotion.hop(height: wasResting ? 34 : 22, now: CACurrentMediaTime())
        markInteraction()
    }

    /// Option+click destination. Stickman walks there, leaping onto or off windows as needed.
    func walkStickman(to screenPoint: NSPoint) {
        guard StickmanModeController.shared.mode == .peaceful, !panel.isVisible, !isTuckedInNotch, notchMove == nil else { return }
        if case .held = locomotion.state { return }
        scanWorld(now: CACurrentMediaTime())
        guard let destination = StickmanSurfaceMap.destination(for: screenPoint, windows: windows, surfaces: locomotion.surfaces) else { return }
        pendingPerch = nil
        seatedWindowIdentity = nil
        stickmanView.setRest(.awake)
        locomotion.go(to: .init(kind: destination.kind, x: screenPoint.x))
        markInteraction()
    }

    // MARK: Notch

    func toggleNotchHide() {
        if isTuckedInNotch || notchMove?.isHiding == true {
            comeOutOfNotch()
        } else {
            tuckIntoNotch()
        }
    }

    /// From the top half of the screen: crouch, leap straight up under the notch, grab it,
    /// and pull up into it. From the bottom half: sprint to the nearer side of the screen,
    /// leap onto the wall, kick off it, and catch the notch at the top of the arc.
    private func tuckIntoNotch() {
        guard isShown, !isHiddenForScreenShare, notchMove == nil, !isTuckedInNotch else { return }
        if case .held = locomotion.state { return }
        StickmanModeController.shared.setMode(.peaceful, reason: "notch")
        closePanel(animated: false)
        clearPerch()
        locomotion.stop()
        stickmanView.setRest(.awake)

        let notch = Self.notchGeometry()
        let entry = CGPoint(x: notch.rect.midX, y: notch.rect.minY - Self.handReach)
        let start = locomotion.position
        stickmanView.setFacing(entry.x - start.x)
        let now = CACurrentMediaTime()
        if let wallJump = planWallJump(from: start, entry: entry, notch: notch, now: now) {
            notchMove = wallJump
            stickmanView.setFacing(wallJump.wallOnRight ? 1 : -1)
            return
        }
        if entry.y - start.y > 24 {
            notchMove = NotchMove(phase: .crouch, startedAt: now, duration: 0.16, from: start, to: entry, aboveScreen: notch.screenTop + 24)
        } else {
            notchMove = NotchMove(phase: .climb, startedAt: now, duration: 0.42, from: start, to: CGPoint(x: entry.x, y: notch.screenTop + 24), aboveScreen: notch.screenTop + 24)
        }
    }

    /// Plans the wall-jump route when he starts in the bottom half of the notch's screen.
    private func planWallJump(from start: CGPoint, entry: CGPoint, notch: (rect: NSRect, screenTop: CGFloat), now: TimeInterval) -> NotchMove? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.maxY == notch.screenTop && $0.frame.minX <= start.x && start.x < $0.frame.maxX }),
              start.y < screen.frame.midY,
              entry.y - start.y > 200
        else { return nil }
        let frame = screen.frame
        let wallOnRight = start.x > frame.midX
        let wallX = wallOnRight ? frame.maxX : frame.minX
        let away: CGFloat = wallOnRight ? -1 : 1
        // Feet sit about 27 points in front of his center in the cling pose.
        let clingX = wallX + away * 27
        let rise = min(360, max(120, (entry.y - start.y) * 0.4))
        let cling = CGPoint(x: clingX, y: min(start.y + rise, entry.y - 120))

        // Sprint along his ledge toward the wall, stopping short enough to leave a real leap.
        var runEnd = start
        if let kind = locomotion.groundedKind,
           let ledge = locomotion.surfaces.first(where: { $0.kind == kind && $0.contains(x: start.x, margin: 4) }) {
            let target = wallX + away * 150
            let edge = ledge.clampedX(target, inset: locomotion.tuning.edgeInset)
            if (edge - start.x) * -away > 0 { runEnd.x = edge }
        }
        var move = NotchMove(phase: .run, startedAt: now, duration: max(0.05, Double(abs(runEnd.x - start.x) / 520)), from: start, to: runEnd, aboveScreen: notch.screenTop + 24)
        move.entry = entry
        move.cling = cling
        move.wallOnRight = wallOnRight
        return move
    }

    /// Slide out of the notch, dangle for a moment, then drop to the ledge below.
    private func comeOutOfNotch() {
        guard let window else { return }
        let now = CACurrentMediaTime()
        if let move = notchMove, move.isHiding {
            // Changed his mind mid-leap: fall from wherever he is.
            notchMove = nil
            locomotion.place(at: scriptedPosition ?? locomotion.position)
            scriptedPosition = nil
            return
        }
        guard isTuckedInNotch else { return }
        isTuckedInNotch = false
        guard isShown, !isHiddenForScreenShare else { return }

        let notch = Self.notchGeometry()
        let top = CGPoint(x: notch.rect.midX, y: notch.screenTop + 24)
        let hang = CGPoint(x: notch.rect.midX, y: notch.rect.minY - Self.handReach)
        notchMove = NotchMove(phase: .emerge, startedAt: now, duration: 0.45, from: top, to: hang, aboveScreen: top.y)
        place(window: window, at: top)
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        window.orderFrontRegardless()
        startTicking()
        combatDirector.start()
        startWindowAffinityTracking()
        markInteraction()
    }

    /// Drives the scripted notch moves. Returns false when physics should run instead.
    private func stepNotchMove(now: TimeInterval) -> Bool {
        guard var move = notchMove, let window else { return false }
        let elapsed = max(0, now - move.startedAt)
        let progress = CGFloat(min(1, elapsed / move.duration))
        let gravity = locomotion.tuning.gravity
        var position = move.from
        let motion: StickmanMotion

        switch move.phase {
        case .run:
            position = SMath.mix(move.from, move.to, progress)
            motion = .grounded(velocityX: move.to.x >= move.from.x ? 520 : -520)
        case .crouch:
            motion = .crouching(progress: progress)
        case .cling:
            motion = .wallCling
        case .leap, .wallLeap:
            let t = CGFloat(min(elapsed, move.duration))
            position = CGPoint(x: move.from.x + move.launch.dx * t, y: move.from.y + move.launch.dy * t - 0.5 * gravity * t * t)
            motion = .airborne(velocity: CGVector(dx: move.launch.dx, dy: move.launch.dy - gravity * t), planned: true)
        case .grab:
            motion = .hanging
        case .climb:
            position = SMath.mix(move.from, move.to, progress * progress)
            motion = .hanging
        case .emerge:
            position = SMath.mix(move.from, move.to, SMath.easeOutCubic(progress))
            motion = .hanging
        case .hang:
            motion = .hanging
        }

        scriptedPosition = position
        place(window: window, at: position)
        if case .grounded = motion {
            stickmanView.updateMotion(motion, heightAboveGround: 0)
        } else {
            stickmanView.updateMotion(motion, heightAboveGround: 400)
        }
        guard progress >= 1 else { return true }

        switch move.phase {
        case .run:
            move.phase = .crouch
            move.startedAt = now
            move.duration = 0.12
            move.from = position
            notchMove = move
        case .crouch where move.cling != nil:
            // Leap onto the wall.
            let jump = StickmanJump.solve(from: position, to: move.cling ?? position, gravity: gravity)
            move.phase = .wallLeap
            move.startedAt = now
            move.duration = jump.duration
            move.from = position
            move.launch = jump.velocity
            notchMove = move
        case .wallLeap:
            move.phase = .cling
            move.startedAt = now
            move.duration = 0.16
            move.from = position
            notchMove = move
        case .cling:
            // Kick off the wall so the top of the arc lands his hands on the notch.
            let entry = move.entry ?? position
            let rise = max(1, entry.y - position.y)
            let launchSpeed = (2 * gravity * rise).squareRoot()
            let duration = Double(launchSpeed / gravity)
            stickmanView.setFacing(entry.x - position.x)
            move.phase = .leap
            move.startedAt = now
            move.duration = duration
            move.from = position
            move.to = entry
            move.launch = CGVector(dx: (entry.x - position.x) / CGFloat(duration), dy: launchSpeed)
            move.cling = nil
            notchMove = move
        case .crouch:
            let rise = max(1, move.to.y - move.from.y)
            let launchSpeed = (2 * gravity * rise).squareRoot()
            let duration = Double(launchSpeed / gravity)
            move.phase = .leap
            move.startedAt = now
            move.duration = duration
            move.launch = CGVector(dx: (move.to.x - move.from.x) / CGFloat(duration), dy: launchSpeed)
            notchMove = move
        case .leap:
            // Catch the notch's bottom edge, hang for a beat, then pull up into it.
            notchMove = NotchMove(phase: .grab, startedAt: now, duration: 0.22, from: position, to: position, aboveScreen: move.aboveScreen)
        case .grab:
            notchMove = NotchMove(phase: .climb, startedAt: now, duration: 0.42, from: position, to: CGPoint(x: position.x, y: move.aboveScreen), aboveScreen: move.aboveScreen)
        case .climb:
            notchMove = nil
            finishTuck()
        case .emerge:
            notchMove = NotchMove(phase: .hang, startedAt: now, duration: 1.0, from: position, to: position, aboveScreen: move.aboveScreen)
        case .hang:
            notchMove = nil
            scriptedPosition = nil
            locomotion.place(at: position)
            scanWorld(now: now)
        }
        return true
    }

    private func finishTuck() {
        isTuckedInNotch = true
        scriptedPosition = nil
        positionBeforeHide = nil
        window?.alphaValue = 0
        window?.ignoresMouseEvents = true
        stopTicking()
        combatDirector.stop()
        stopWindowAffinityTracking()
    }

    /// Ends a notch move at once, for when a screen share starts mid-move.
    private func settleNotchMove() {
        guard let move = notchMove else { return }
        notchMove = nil
        if move.isHiding {
            finishTuck()
        } else {
            scriptedPosition = nil
            locomotion.place(at: move.to)
        }
    }

    private func place(window: NSWindow, at feet: CGPoint) {
        let origin = NSPoint(
            x: (feet.x - characterSize.width / 2).rounded(),
            y: (feet.y - StickmanMetrics.footInset).rounded()
        )
        if window.frame.origin != origin { window.setFrameOrigin(origin) }
    }

    /// Height from his feet to his raised hands. Puts his grip just inside the notch's bottom edge.
    private static let handReach: CGFloat = 94

    /// The camera notch on the built-in display, or a notch-sized spot at the top center
    /// of the main screen's menu bar when no display has one.
    static func notchGeometry() -> (rect: NSRect, screenTop: CGFloat) {
        let screens = NSScreen.screens
        let notched = screens.first { $0.safeAreaInsets.top > 0 }
        guard let screen = notched ?? NSScreen.main ?? screens.first else {
            return (NSRect(x: 640, y: 860, width: 180, height: 32), 900)
        }
        let frame = screen.frame
        let menuBarHeight = max(24, frame.maxY - screen.visibleFrame.maxY)
        if notched != nil, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let height = screen.safeAreaInsets.top
            // The side areas may be global or relative to the screen; use whichever lands on it.
            for offset in [0, frame.minX] {
                let minX = left.maxX + offset
                let maxX = right.minX + offset
                if minX >= frame.minX, maxX <= frame.maxX, maxX - minX > 60 {
                    return (NSRect(x: minX, y: frame.maxY - height, width: maxX - minX, height: height), frame.maxY)
                }
            }
        }
        let width: CGFloat = 180
        return (NSRect(x: frame.midX - width / 2, y: frame.maxY - menuBarHeight, width: width, height: menuBarHeight), frame.maxY)
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
              stickmanView.currentRest != .sleeping,
              sleepCorner == nil,
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

private struct NotchMove {
    enum Phase {
        case run
        case crouch
        case wallLeap
        case cling
        case leap
        case grab
        case climb
        case emerge
        case hang
    }

    var phase: Phase
    var startedAt: TimeInterval
    var duration: TimeInterval
    var from: CGPoint
    var to: CGPoint
    /// Feet height that puts him fully above the screen's top edge.
    var aboveScreen: CGFloat
    var launch = CGVector.zero
    /// Wall-jump route only: the notch grip point, the wall contact point, and which wall.
    var entry: CGPoint?
    var cling: CGPoint?
    var wallOnRight = false

    var isHiding: Bool { [.run, .crouch, .wallLeap, .cling, .leap, .grab, .climb].contains(phase) }
}

private struct SleepCorner {
    let kind: StickmanSurface.Kind
    let wallOnRight: Bool
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

    /// Lets Stickman leave the screen's top edge when he climbs into the notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
