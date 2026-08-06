import AppKit
import CoreGraphics

final class StickmanWindowController: NSWindowController, CombatDirectorDelegate {
    private let collapsedSize = NSSize(width: StickmanMetrics.characterSize, height: StickmanMetrics.characterSize)
    private let chatSize = NSSize(width: 500, height: 350)
    private let settingsSize = NSSize(width: 560, height: 430)
    private let rootView: StickmanRootView
    private var panelMode: PanelMode = .collapsed
    private var visibleFrameBeforeHide: NSRect?
    private var walkTimer: Timer?
    private var personalityTimer: Timer?
    private var walkTargetOrigin: NSPoint?
    private var walkGrabPoint: NSPoint?
    private var pullStartsAt: TimeInterval?
    private var lastWalkTick: TimeInterval?
    private let walkSpeed: CGFloat = 520
    private let personalityDelayRange: ClosedRange<TimeInterval> = 75 ... 150
    private lazy var combatDirector = CombatDirector(delegate: self)
    private var modeObserver: NSObjectProtocol?
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
        let size = collapsedSize
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(
            x: visibleFrame.midX - (size.width / 2),
            y: visibleFrame.midY - (size.height / 2),
            width: size.width,
            height: size.height
        )
        rootView = StickmanRootView(frame: NSRect(origin: .zero, size: frame.size))
        let window = StickmanWindow(contentRect: frame)
        window.contentView = rootView
        super.init(window: window)
        shouldCascadeWindows = false
        rootView.onToggleChat = { [weak self] in
            self?.toggleChat()
        }
        rootView.onOpenSettings = { [weak self] in
            self?.showSettings()
        }
        rootView.onCloseSettings = { [weak self] in
            self?.setPanelMode(.chat)
        }
        rootView.onCursorStrike = { [weak self] point in
            self?.combatDirector.registerDirectStrike(at: point)
        }
        rootView.onScreenGuidance = { markers in
            ScreenEffectsOverlayController.shared.showGuidance(markers)
        }
        modeObserver = NotificationCenter.default.addObserver(
            forName: .stickmanModeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleModeChange(notification)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        walkTimer?.invalidate()
        personalityTimer?.invalidate()
        windowAffinityTimer?.invalidate()
        combatDirector.stop()
        if let modeObserver { NotificationCenter.default.removeObserver(modeObserver) }
    }

    func toggleChat() {
        setPanelMode(panelMode == .collapsed ? .chat : .collapsed)
    }

    func showStickman() {
        guard let window else { return }

        if let visibleFrameBeforeHide {
            window.setFrame(visibleFrameBeforeHide, display: true, animate: false)
            self.visibleFrameBeforeHide = nil
        }

        showWindow(self)
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        window.level = .screenSaver
        window.orderFrontRegardless()
        combatDirector.start()
        startAmbientPersonality()
        startWindowAffinityTracking()
    }

    func hideStickman() {
        guard let window else { return }

        if panelMode != .collapsed {
            setPanelMode(.collapsed, animate: false)
        }

        stopWalking()
        stopAmbientPersonality()
        stopWindowAffinityTracking()
        visibleFrameBeforeHide = window.frame
        window.ignoresMouseEvents = true
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    }

    func setChatVisible(_ isVisible: Bool) {
        setPanelMode(isVisible ? .chat : .collapsed)
    }

    func quickAssist() {
        StickmanModeController.shared.setMode(.peaceful, reason: "quick assist")
        if panelMode != .chat { setPanelMode(.chat) }
        rootView.prepareQuickAssist()
        rootView.focusChatInput()
    }

    func openMenu() {
        StickmanModeController.shared.setMode(.peaceful, reason: "menu shortcut")
        if panelMode != .chat { setPanelMode(.chat) }
        rootView.focusChatInput()
    }

    func startVoiceMode() {
        StickmanModeController.shared.setMode(.peaceful, reason: "voice shortcut")
        if panelMode != .chat { setPanelMode(.chat) }
        rootView.startVoiceMode()
    }

    func showAgentStatus() {
        StickmanModeController.shared.setMode(.peaceful, reason: "agent status")
        if panelMode != .chat { setPanelMode(.chat) }
        rootView.showAgentStatus()
    }

    func openSettings() {
        StickmanModeController.shared.setMode(.peaceful, reason: "settings menu")
        showSettings()
    }

    func openPermissions() {
        StickmanModeController.shared.setMode(.peaceful, reason: "permissions menu")
        showSettings()
        rootView.showPermissionSettings()
    }

    func openConnections() {
        StickmanModeController.shared.setMode(.peaceful, reason: "connections menu")
        showSettings()
        rootView.showConnectionSettings()
    }

    func toggleCombatMode() {
        StickmanModeController.shared.toggle(reason: "Option-F")
    }

    var combatCharacterFrame: NSRect? {
        guard let window else { return nil }
        return NSRect(
            x: window.frame.minX,
            y: window.frame.minY,
            width: StickmanMetrics.characterSize,
            height: StickmanMetrics.characterSize
        )
    }

    func combatDirector(_ director: CombatDirector, perform move: StickmanCombatMove) {
        rootView.performCombatMove(move)
    }

    func combatDirector(_ director: CombatDirector, applyWindowImpulse impulse: CGVector) {
        guard let window else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(window.frame) }) ?? NSScreen.main
        let safeFrame = (screen?.visibleFrame ?? window.frame).insetBy(dx: 8, dy: 8)
        let origin = CGPoint(
            x: min(max(window.frame.minX + impulse.dx, safeFrame.minX), safeFrame.maxX - window.frame.width),
            y: min(max(window.frame.minY + impulse.dy, safeFrame.minY), safeFrame.maxY - window.frame.height)
        )
        window.setFrameOrigin(origin)
    }

    private func handleModeChange(_ notification: Notification) {
        guard let raw = notification.userInfo?["mode"] as? String,
              let mode = StickmanMode(rawValue: raw),
              let window
        else { return }

        stopWalking()
        clearPerch()
        rootView.setMode(mode)
        if mode == .sparring, panelMode != .collapsed {
            setPanelMode(.collapsed)
        }
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        ScreenEffectsOverlayController.shared.showModeTransition(at: center, enteringCombat: mode == .sparring)
        if mode == .sparring {
            rootView.performCombatMove(.guardStance)
        } else {
            ScreenEffectsOverlayController.shared.clearGuidance()
        }
    }

    private func showSettings() {
        setPanelMode(.settings)
    }

    private func setPanelMode(_ mode: PanelMode, animate: Bool = true) {
        guard mode != panelMode, let window else { return }

        panelMode = mode
        if mode != .collapsed {
            stopWalking()
            clearPerch()
        }
        let oldFrame = window.frame
        let newSize = size(for: mode)
        let newFrame = NSRect(
            x: oldFrame.minX,
            y: oldFrame.maxY - newSize.height,
            width: newSize.width,
            height: newSize.height
        )

        rootView.setChatVisible(mode == .chat)
        rootView.setSettingsVisible(mode == .settings)
        window.setFrame(newFrame, display: true, animate: animate)

        if mode == .chat {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.rootView.focusChatInput()
            }
        } else if mode == .settings {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.rootView.focusSettingsInput()
            }
        }
    }

    private func size(for mode: PanelMode) -> NSSize {
        switch mode {
        case .collapsed:
            return collapsedSize
        case .chat:
            return chatSize
        case .settings:
            return settingsSize
        }
    }

    func walkStickman(to screenPoint: NSPoint) {
        guard StickmanModeController.shared.mode == .peaceful, panelMode == .collapsed else { return }
        pendingPerch = nil
        seatedWindowIdentity = nil
        rootView.setPerched(false)
        walkStickman(to: screenPoint, grabbing: nil)
    }

    private func walkStickman(to screenPoint: NSPoint, grabbing grabPoint: NSPoint?) {
        guard let window else { return }

        let targetFrame = targetFrame(for: screenPoint, currentFrame: window.frame)
        let currentOrigin = window.frame.origin
        walkTargetOrigin = targetFrame.origin
        walkGrabPoint = grabPoint
        let now = ProcessInfo.processInfo.systemUptime
        pullStartsAt = grabPoint == nil ? nil : now + 0.52
        lastWalkTick = now

        if let grabPoint {
            let deltaX = targetFrame.origin.x - currentOrigin.x
            rootView.setLocomotion(intensity: 0, facingDirection: deltaX >= 0 ? 1 : -1)
            rootView.setNavigationGrip(screenPoint: grabPoint)
        }

        if walkTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.stepWalk()
            }
            RunLoop.main.add(timer, forMode: .common)
            walkTimer = timer
        }
    }

    private func stepWalk() {
        guard let window, let walkTargetOrigin else {
            stopWalking()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if let pullStartsAt, now < pullStartsAt {
            lastWalkTick = now
            let deltaX = walkTargetOrigin.x - window.frame.origin.x
            rootView.setLocomotion(intensity: 0, facingDirection: deltaX >= 0 ? 1 : -1)
            rootView.setNavigationGrip(screenPoint: walkGrabPoint)
            return
        }

        pullStartsAt = nil
        let previousTick = lastWalkTick ?? now
        let deltaTime = max(1.0 / 120.0, min(now - previousTick, 1.0 / 20.0))
        lastWalkTick = now

        let currentOrigin = window.frame.origin
        let delta = CGPoint(
            x: walkTargetOrigin.x - currentOrigin.x,
            y: walkTargetOrigin.y - currentOrigin.y
        )
        let distance = hypot(delta.x, delta.y)

        guard distance > 1 else {
            window.setFrameOrigin(walkTargetOrigin)
            stopWalking(completed: true)
            return
        }

        let stepDistance = min(distance, walkSpeed * CGFloat(deltaTime))
        let progress = stepDistance / distance
        let newOrigin = NSPoint(
            x: currentOrigin.x + delta.x * progress,
            y: currentOrigin.y + delta.y * progress
        )

        window.setFrameOrigin(newOrigin)
        let intensity = min(1, max(0.25, distance / 180))
        rootView.setLocomotion(intensity: intensity, facingDirection: delta.x >= 0 ? 1 : -1)
        rootView.setNavigationGrip(screenPoint: walkGrabPoint)
    }

    private func stopWalking(completed: Bool = false) {
        let completedPerch = completed ? pendingPerch : nil
        walkTimer?.invalidate()
        walkTimer = nil
        walkTargetOrigin = nil
        walkGrabPoint = nil
        pullStartsAt = nil
        lastWalkTick = nil
        rootView.setLocomotion(intensity: 0, facingDirection: 0)
        rootView.setNavigationGrip(screenPoint: nil)

        if let completedPerch,
           DesktopContextProvider.shared.currentContext().stableWindowIdentity == completedPerch.identity,
           StickmanModeController.shared.mode == .peaceful,
           panelMode == .collapsed {
            seatedWindowIdentity = completedPerch.identity
            rootView.setPerched(true)
        }
        pendingPerch = nil
    }

    private func startAmbientPersonality() {
        scheduleNextAmbientPersonality()
    }

    private func stopAmbientPersonality() {
        personalityTimer?.invalidate()
        personalityTimer = nil
        rootView.cancelAmbientPersonality()
    }

    private func scheduleNextAmbientPersonality() {
        personalityTimer?.invalidate()
        let delay = TimeInterval.random(in: personalityDelayRange)
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.performAmbientPersonality()
        }
        RunLoop.main.add(timer, forMode: .common)
        personalityTimer = timer
    }

    private func performAmbientPersonality() {
        defer { scheduleNextAmbientPersonality() }

        guard panelMode == .collapsed,
              walkTimer == nil,
              seatedWindowIdentity == nil,
              pendingPerch == nil
        else {
            return
        }

        switch Int.random(in: 0 ..< 100) {
        case 0 ..< 38:
            rootView.showAmbientPersonality(.thoughtfulGlance)
        case 38 ..< 66:
            rootView.showAmbientPersonality(.screenCuriosity)
        case 66 ..< 86:
            rootView.showAmbientPersonality(.cursorReach(screenPoint: NSEvent.mouseLocation))
        default:
            rootView.showAmbientPersonality(.tinyCelebrate)
        }
    }

    private func nextRoamRoute() -> RoamRoute {
        if let edgeRoute = windowEdgeRoutes().randomElement() {
            return edgeRoute
        }

        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let destination = NSPoint(
            x: CGFloat.random(in: (visibleFrame.minX + 90) ... (visibleFrame.maxX - 90)),
            y: CGFloat.random(in: (visibleFrame.minY + 90) ... (visibleFrame.maxY - 90))
        )
        return RoamRoute(destination: destination, grabPoint: nil)
    }

    private func windowEdgeRoutes() -> [RoamRoute] {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let fallbackFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        return windows.compactMap { windowInfo in
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != ProcessInfo.processInfo.processIdentifier,
                  let layer = windowInfo[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let cgBounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  cgBounds.width >= StickmanMetrics.characterSize,
                  cgBounds.height >= 120
            else {
                return nil
            }

            let screenFrame = visibleFrames.first { $0.intersects(cgBounds) } ?? fallbackFrame
            let windowRect = appKitRect(fromWindowServerRect: cgBounds, in: screenFrame)
            guard windowRect.intersects(screenFrame) else { return nil }

            return route(forWindowRect: windowRect, visibleFrame: screenFrame)
        }
    }

    private func route(forWindowRect windowRect: NSRect, visibleFrame: NSRect) -> RoamRoute {
        enum Edge {
            case left
            case right
            case top
            case bottom
        }

        let edge = [Edge.left, .right, .top, .bottom].randomElement() ?? .right
        let grabPoint: NSPoint
        let destination: NSPoint

        switch edge {
        case .left:
            grabPoint = NSPoint(x: windowRect.minX, y: CGFloat.random(in: windowRect.minY ... windowRect.maxY))
            destination = NSPoint(x: grabPoint.x - 58, y: grabPoint.y)
        case .right:
            grabPoint = NSPoint(x: windowRect.maxX, y: CGFloat.random(in: windowRect.minY ... windowRect.maxY))
            destination = NSPoint(x: grabPoint.x + 58, y: grabPoint.y)
        case .top:
            grabPoint = NSPoint(x: CGFloat.random(in: windowRect.minX ... windowRect.maxX), y: windowRect.maxY)
            destination = NSPoint(x: grabPoint.x, y: grabPoint.y + 58)
        case .bottom:
            grabPoint = NSPoint(x: CGFloat.random(in: windowRect.minX ... windowRect.maxX), y: windowRect.minY)
            destination = NSPoint(x: grabPoint.x, y: grabPoint.y - 58)
        }

        return RoamRoute(
            destination: clamped(
                point: destination,
                to: visibleFrame.insetBy(dx: StickmanMetrics.characterSize / 2 + 4, dy: StickmanMetrics.characterSize / 2 + 4)
            ),
            grabPoint: clamped(point: grabPoint, to: visibleFrame.insetBy(dx: 8, dy: 8))
        )
    }

    private func appKitRect(fromWindowServerRect rect: CGRect, in screenFrame: NSRect) -> NSRect {
        NSRect(
            x: rect.minX,
            y: screenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func clamped(point: NSPoint, to rect: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    private func targetFrame(for screenPoint: NSPoint, currentFrame: NSRect) -> NSRect {
        let stickmanCenter = stickmanCenterOffset(in: currentFrame.size)
        let proposedOrigin = NSPoint(
            x: screenPoint.x - stickmanCenter.x,
            y: screenPoint.y - stickmanCenter.y
        )
        var targetFrame = NSRect(origin: proposedOrigin, size: currentFrame.size)
        let visibleFrame = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        targetFrame.origin.x = min(max(targetFrame.minX, visibleFrame.minX), visibleFrame.maxX - targetFrame.width)
        targetFrame.origin.y = min(max(targetFrame.minY, visibleFrame.minY), visibleFrame.maxY - targetFrame.height)
        return targetFrame
    }

    private func stickmanCenterOffset(in windowSize: NSSize) -> CGPoint {
        let half = StickmanMetrics.characterSize / 2
        let stickmanViewY = max(0, (windowSize.height / 2) - half)
        return CGPoint(x: half, y: windowSize.height - stickmanViewY - half)
    }

    private func startWindowAffinityTracking() {
        guard windowAffinityTimer == nil else { return }
        trackedWindowSince = ProcessInfo.processInfo.systemUptime
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.stepWindowAffinity()
        }
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
            if seatedWindowIdentity != nil || pendingPerch != nil { leavePerchAndRoam() }
            trackedWindowIdentity = nil
            trackedWindowSince = now
            return
        }

        missingWindowSince = nil
        if identity != trackedWindowIdentity {
            affinityLog("Tracking \(identity).")
            if seatedWindowIdentity != nil || pendingPerch != nil { leavePerchAndRoam() }
            trackedWindowIdentity = identity
            trackedWindowSince = now
            return
        }

        guard panelMode == .collapsed,
              seatedWindowIdentity == nil,
              pendingPerch == nil,
              walkTimer == nil,
              now - trackedWindowSince >= perchDelay
        else { return }

        beginPerching(on: frame, identity: identity)
    }

    private func beginPerching(on windowFrame: NSRect, identity: String) {
        affinityLog("Perching on \(identity) after \(perchDelay) seconds.")
        let half = StickmanMetrics.characterSize / 2
        let preferredPoint = NSPoint(
            x: windowFrame.maxX - half - 10,
            y: windowFrame.maxY + half - 7
        )
        pendingPerch = PerchTarget(identity: identity)
        rootView.setPerched(false)
        walkStickman(to: preferredPoint, grabbing: nil)
    }

    private func leavePerchAndRoam() {
        let wasResting = seatedWindowIdentity != nil || pendingPerch != nil
        pendingPerch = nil
        seatedWindowIdentity = nil
        rootView.setPerched(false)
        guard wasResting, panelMode == .collapsed else { return }
        let route = nextRoamRoute()
        walkStickman(to: route.destination, grabbing: route.grabPoint)
    }

    private func clearPerch() {
        pendingPerch = nil
        seatedWindowIdentity = nil
        rootView.setPerched(false)
    }

    private func affinityLog(_ message: String) {
        guard affinityDebugEnabled else { return }
        print("[Stickman window affinity] \(message)")
    }
}

private enum PanelMode {
    case collapsed
    case chat
    case settings
}

private struct RoamRoute {
    let destination: NSPoint
    let grabPoint: NSPoint?
}

private struct PerchTarget {
    let identity: String
}

private final class StickmanWindow: NSPanel {
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
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }

    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { true }

    override var acceptsFirstResponder: Bool { true }
}
