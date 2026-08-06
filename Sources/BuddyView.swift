import AppKit

final class StickmanView: NSView {
    enum Activity {
        case quiet
        case listening
        case thinking
        case speaking
        case working
        case error
        case sleeping
    }

    enum PreviewState: String, CaseIterable {
        case idle
        case listening
        case thinking
        case walking
        case reaching
        case happy
        case speaking
        case working
        case agentWave
        case browserWand
        case calendarPeek
        case permissionKey
        case connectorLink
        case error
        case sleeping
        case perched
        case sparring
        case punch
        case kick

        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    var onToggleChat: (() -> Void)?
    var onCursorStrike: ((CGPoint) -> Void)?

    private enum StickmanState {
        case idle
        case listening
        case thinking
        case walking
        case reaching
        case happy
        case speaking
        case working
        case agentWave
        case browserWand
        case calendarPeek
        case permissionKey
        case connectorLink
        case error
        case sleeping
        case perched
        case combat
    }

    private struct StickPose {
        var head: CGPoint
        var neck: CGPoint
        var hip: CGPoint
        var leftElbow: CGPoint
        var leftHand: CGPoint
        var rightElbow: CGPoint
        var rightHand: CGPoint
        var leftKnee: CGPoint
        var leftFoot: CGPoint
        var rightKnee: CGPoint
        var rightFoot: CGPoint
        var headTilt: CGFloat = 0
        var bodyLean: CGFloat = 0

        func blended(toward other: StickPose, amount: CGFloat) -> StickPose {
            func point(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
                CGPoint(x: a.x + (b.x - a.x) * amount, y: a.y + (b.y - a.y) * amount)
            }
            return StickPose(
                head: point(head, other.head),
                neck: point(neck, other.neck),
                hip: point(hip, other.hip),
                leftElbow: point(leftElbow, other.leftElbow),
                leftHand: point(leftHand, other.leftHand),
                rightElbow: point(rightElbow, other.rightElbow),
                rightHand: point(rightHand, other.rightHand),
                leftKnee: point(leftKnee, other.leftKnee),
                leftFoot: point(leftFoot, other.leftFoot),
                rightKnee: point(rightKnee, other.rightKnee),
                rightFoot: point(rightFoot, other.rightFoot),
                headTilt: headTilt + (other.headTilt - headTilt) * amount,
                bodyLean: bodyLean + (other.bodyLean - bodyLean) * amount
            )
        }

        func offsetBy(dx: CGFloat, dy: CGFloat) -> StickPose {
            var copy = self
            copy.head.x += dx; copy.head.y += dy
            copy.neck.x += dx; copy.neck.y += dy
            copy.hip.x += dx; copy.hip.y += dy
            copy.leftElbow.x += dx; copy.leftElbow.y += dy
            copy.leftHand.x += dx; copy.leftHand.y += dy
            copy.rightElbow.x += dx; copy.rightElbow.y += dy
            copy.rightHand.x += dx; copy.rightHand.y += dy
            copy.leftKnee.x += dx; copy.leftKnee.y += dy
            copy.leftFoot.x += dx; copy.leftFoot.y += dy
            copy.rightKnee.x += dx; copy.rightKnee.y += dy
            copy.rightFoot.x += dx; copy.rightFoot.y += dy
            return copy
        }
    }

    private var displayTimer: Timer?
    private var time: TimeInterval = 0
    private var activity: Activity = .quiet
    private var mode: StickmanMode = .peaceful
    private var isChatVisible = false
    private var locomotionIntensity: CGFloat = 0
    private var facingDirection: CGFloat = 1
    private var navigationGripPoint: CGPoint?
    private var jumpStartedAt: TimeInterval?
    private var transientState: StickmanState?
    private var transientEndsAt: TimeInterval = 0
    private var taskAnimation: StickmanTaskAnimation?
    private var taskAnimationStartedAt: TimeInterval = 0
    private var taskAnimationEndsAt: TimeInterval = 0
    private var previewState: PreviewState?
    private var previewTime: TimeInterval?
    private var combatMove: StickmanCombatMove = .guardStance
    private var combatMoveStartedAt: TimeInterval = 0
    private var combatMoveEndsAt: TimeInterval = 0
    private var pose = StickmanView.neutralPose()
    private var dragOriginInWindow: CGPoint?
    private var windowOriginAtDragStart: CGPoint?
    private var showsChatHint = true
    private var isPerched = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        mode = StickmanModeController.shared.mode
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(modeDidChange(_:)),
            name: .stickmanModeDidChange,
            object: nil
        )
        startAnimation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        displayTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        let scale = min(bounds.width, bounds.height) / StickmanMetrics.designSize
        context.saveGState()
        context.scaleBy(x: scale, y: scale)

        if facingDirection < 0 {
            context.translateBy(x: 80, y: 0)
            context.scaleBy(x: -1, y: 1)
            context.translateBy(x: -80, y: 0)
        }

        drawShadow(context: context)
        drawMotionAccents(context: context)
        drawStickFigure(pose: pose, context: context)
        drawTaskEffects(context: context)
        context.restoreGState()

        drawChatHint()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 3, mode == .peaceful {
            StickmanModeController.shared.beginSparringFromTripleClick()
            return
        }
        if event.clickCount == 2, mode == .peaceful {
            onToggleChat?()
            return
        }

        let screenPoint = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation

        if mode == .sparring {
            onCursorStrike?(screenPoint)
            performCombatMove(.hit(direction: CGVector(dx: 0.7, dy: 0.25)))
            return
        }

        isPerched = false
        jumpStartedAt = time
        dragOriginInWindow = event.locationInWindow
        windowOriginAtDragStart = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .peaceful,
              let dragOriginInWindow,
              let windowOriginAtDragStart,
              let window
        else { return }

        let delta = CGPoint(
            x: event.locationInWindow.x - dragOriginInWindow.x,
            y: event.locationInWindow.y - dragOriginInWindow.y
        )
        window.setFrameOrigin(CGPoint(x: windowOriginAtDragStart.x + delta.x, y: windowOriginAtDragStart.y + delta.y))
    }

    override func mouseUp(with event: NSEvent) {
        dragOriginInWindow = nil
        windowOriginAtDragStart = nil
    }

    func setChatVisible(_ isVisible: Bool) {
        isChatVisible = isVisible
        needsDisplay = true
    }

    func setActivity(_ activity: Activity) {
        self.activity = activity
        needsDisplay = true
    }

    func showSuccessMoment() {
        transientState = .happy
        transientEndsAt = time + 1.15
        jumpStartedAt = time
    }

    func showErrorMoment() {
        transientState = .error
        transientEndsAt = time + 1.1
    }

    func performTaskAnimation(_ animation: StickmanTaskAnimation) {
        guard mode == .peaceful else { return }
        isPerched = false
        taskAnimation = animation
        taskAnimationStartedAt = time
        let duration: TimeInterval
        switch animation {
        case .spawnAgent: duration = 1.55
        case .openBrowserTab: duration = 1.4
        case .checkCalendar: duration = 1.35
        case .requestPermission: duration = 1.45
        case .connectService: duration = 1.5
        }
        taskAnimationEndsAt = time + duration
        needsDisplay = true
    }

    func setPreviewState(_ previewState: PreviewState, time: TimeInterval) {
        self.previewState = previewState
        previewTime = time
        self.time = time
        mode = [.sparring, .punch, .kick].contains(previewState) ? .sparring : .peaceful
        isPerched = previewState == .perched
        locomotionIntensity = previewState == .walking ? 0.9 : 0
        navigationGripPoint = previewState == .reaching ? CGPoint(x: 138, y: 45) : nil
        showsChatHint = false
        if previewState == .punch {
            let duration = 0.72
            combatMove = .jab
            combatMoveStartedAt = floor(time / duration) * duration
            combatMoveEndsAt = combatMoveStartedAt + duration
        }
        if previewState == .kick {
            let duration = 0.9
            combatMove = .kick
            combatMoveStartedAt = floor(time / duration) * duration
            combatMoveEndsAt = combatMoveStartedAt + duration
        }
        pose = targetPose()
        needsDisplay = true
    }

    func setLocomotion(intensity: CGFloat, facingDirection: CGFloat) {
        locomotionIntensity = max(0, min(1, intensity))
        if abs(facingDirection) > 0.1 { self.facingDirection = facingDirection >= 0 ? 1 : -1 }
    }

    func setNavigationGrip(_ point: CGPoint?) {
        navigationGripPoint = point
    }

    func setPerched(_ perched: Bool) {
        isPerched = perched
        if perched {
            locomotionIntensity = 0
            navigationGripPoint = nil
        }
        needsDisplay = true
    }

    func setMode(_ mode: StickmanMode) {
        self.mode = mode
        if mode == .sparring {
            isPerched = false
            isChatVisible = false
            performCombatMove(.guardStance)
        } else {
            combatMove = .guardStance
            transientState = .happy
            transientEndsAt = time + 0.8
        }
        needsDisplay = true
    }

    func performCombatMove(_ move: StickmanCombatMove) {
        combatMove = move
        combatMoveStartedAt = time
        let duration: TimeInterval
        switch move {
        case .guardStance: duration = 0.3
        case .dodge: duration = 0.44
        case .jab: duration = 0.46
        case .kick: duration = 0.64
        case .lasso: duration = 0.7
        case .groundSlam: duration = 0.82
        case .hit: duration = 0.52
        case .victory: duration = 1.15
        }
        combatMoveEndsAt = time + duration
        needsDisplay = true
    }

    @objc private func modeDidChange(_ notification: Notification) {
        let rawValue = notification.userInfo?["mode"] as? String
        guard let rawValue, let newMode = StickmanMode(rawValue: rawValue) else { return }
        setMode(newMode)
    }

    private func startAnimation() {
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if previewTime == nil { time += 1.0 / 60.0 }
            if let jumpStartedAt, time - jumpStartedAt > 0.72 { self.jumpStartedAt = nil }
            if time > transientEndsAt { transientState = nil }
            if time > taskAnimationEndsAt { taskAnimation = nil }
            if mode == .sparring, time > combatMoveEndsAt { combatMove = .guardStance }
            pose = pose.blended(toward: targetPose(), amount: mode == .sparring ? 0.32 : 0.2)
            needsDisplay = true
        }
        if let displayTimer { RunLoop.main.add(displayTimer, forMode: .common) }
    }

    private func currentState() -> StickmanState {
        if let previewState {
            switch previewState {
            case .idle: return .idle
            case .listening: return .listening
            case .thinking: return .thinking
            case .walking: return .walking
            case .reaching: return .reaching
            case .happy: return .happy
            case .speaking: return .speaking
            case .working: return .working
            case .agentWave: return .agentWave
            case .browserWand: return .browserWand
            case .calendarPeek: return .calendarPeek
            case .permissionKey: return .permissionKey
            case .connectorLink: return .connectorLink
            case .error: return .error
            case .sleeping: return .sleeping
            case .perched: return .perched
            case .sparring, .punch, .kick: return .combat
            }
        }
        if mode == .sparring { return .combat }
        if isPerched { return .perched }
        if let taskAnimation {
            switch taskAnimation {
            case .spawnAgent: return .agentWave
            case .openBrowserTab: return .browserWand
            case .checkCalendar: return .calendarPeek
            case .requestPermission: return .permissionKey
            case .connectService: return .connectorLink
            }
        }
        if let transientState { return transientState }
        if navigationGripPoint != nil { return .reaching }
        if locomotionIntensity > 0.08 { return .walking }
        switch activity {
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .working: return .working
        case .error: return .error
        case .sleeping: return .sleeping
        case .quiet: break
        }
        if isChatVisible { return .listening }
        let cycle = time.truncatingRemainder(dividingBy: 38)
        if cycle > 12, cycle < 14 { return .thinking }
        if cycle > 25, cycle < 29 { return .sleeping }
        return .idle
    }

    private func targetPose() -> StickPose {
        let state = currentState()
        var result: StickPose
        switch state {
        case .idle: result = idlePose()
        case .listening: result = listeningPose()
        case .thinking: result = thinkingPose()
        case .walking: result = walkingPose()
        case .reaching: result = reachingPose()
        case .happy: result = happyPose()
        case .speaking: result = speakingPose()
        case .working: result = workingPose()
        case .agentWave: result = agentWavePose()
        case .browserWand: result = browserWandPose()
        case .calendarPeek: result = calendarPeekPose()
        case .permissionKey: result = permissionKeyPose()
        case .connectorLink: result = connectorLinkPose()
        case .error: result = errorPose()
        case .sleeping: result = sleepingPose()
        case .perched: result = perchedPose()
        case .combat: result = combatPose()
        }

        if let jumpStartedAt {
            let progress = max(0, min(1, (time - jumpStartedAt) / 0.72))
            let lift = CGFloat(sin(progress * .pi)) * -28
            result = result.offsetBy(dx: 0, dy: lift)
        }
        return result
    }

    private static func neutralPose() -> StickPose {
        StickPose(
            head: CGPoint(x: 80, y: 26), neck: CGPoint(x: 80, y: 48), hip: CGPoint(x: 80, y: 92),
            leftElbow: CGPoint(x: 65, y: 67), leftHand: CGPoint(x: 60, y: 90),
            rightElbow: CGPoint(x: 95, y: 67), rightHand: CGPoint(x: 100, y: 90),
            leftKnee: CGPoint(x: 68, y: 119), leftFoot: CGPoint(x: 58, y: 145),
            rightKnee: CGPoint(x: 92, y: 119), rightFoot: CGPoint(x: 103, y: 145)
        )
    }

    private func idlePose() -> StickPose {
        let breath = CGFloat(sin(time * 1.7))
        let sway = CGFloat(sin(time * 0.82))
        return StickPose(
            head: CGPoint(x: 79 + sway * 1.3, y: 27 + breath * 0.7),
            neck: CGPoint(x: 80, y: 49 + breath * 0.5), hip: CGPoint(x: 81, y: 93),
            leftElbow: CGPoint(x: 65, y: 70 + breath), leftHand: CGPoint(x: 59, y: 94 + breath),
            rightElbow: CGPoint(x: 96, y: 68 - breath * 0.3), rightHand: CGPoint(x: 102, y: 91),
            leftKnee: CGPoint(x: 69, y: 119), leftFoot: CGPoint(x: 58, y: 145),
            rightKnee: CGPoint(x: 92, y: 118), rightFoot: CGPoint(x: 104, y: 145),
            headTilt: sway * 0.035, bodyLean: sway * 0.012
        )
    }

    private func listeningPose() -> StickPose {
        let pulse = CGFloat(sin(time * 3.4))
        return StickPose(
            head: CGPoint(x: 78, y: 24 + pulse), neck: CGPoint(x: 80, y: 47), hip: CGPoint(x: 81, y: 92),
            leftElbow: CGPoint(x: 62, y: 67), leftHand: CGPoint(x: 54, y: 86),
            rightElbow: CGPoint(x: 99, y: 62), rightHand: CGPoint(x: 105, y: 40),
            leftKnee: CGPoint(x: 68, y: 119), leftFoot: CGPoint(x: 57, y: 145),
            rightKnee: CGPoint(x: 93, y: 118), rightFoot: CGPoint(x: 104, y: 145),
            headTilt: -0.1
        )
    }

    private func thinkingPose() -> StickPose {
        return StickPose(
            head: CGPoint(x: 76, y: 27), neck: CGPoint(x: 79, y: 49), hip: CGPoint(x: 83, y: 93),
            leftElbow: CGPoint(x: 61, y: 73), leftHand: CGPoint(x: 62, y: 96),
            rightElbow: CGPoint(x: 100, y: 69), rightHand: CGPoint(x: 91, y: 48),
            leftKnee: CGPoint(x: 69, y: 119), leftFoot: CGPoint(x: 56, y: 145),
            rightKnee: CGPoint(x: 94, y: 120), rightFoot: CGPoint(x: 105, y: 145),
            headTilt: -0.11, bodyLean: 0.045
        )
    }

    private func walkingPose() -> StickPose {
        let phase = CGFloat(sin(time * 10.2))
        let bob = abs(CGFloat(sin(time * 10.2))) * -4 * locomotionIntensity
        return StickPose(
            head: CGPoint(x: 81, y: 27 + bob), neck: CGPoint(x: 80, y: 49 + bob), hip: CGPoint(x: 79, y: 91 + bob),
            leftElbow: CGPoint(x: 66 + phase * 8, y: 68 + bob), leftHand: CGPoint(x: 60 + phase * 15, y: 91 + bob),
            rightElbow: CGPoint(x: 95 - phase * 8, y: 68 + bob), rightHand: CGPoint(x: 101 - phase * 15, y: 91 + bob),
            leftKnee: CGPoint(x: 70 - phase * 11, y: 117 + bob), leftFoot: CGPoint(x: 58 - phase * 17, y: 143 + bob),
            rightKnee: CGPoint(x: 91 + phase * 11, y: 117 + bob), rightFoot: CGPoint(x: 103 + phase * 17, y: 143 + bob),
            bodyLean: 0.08
        )
    }

    private func reachingPose() -> StickPose {
        var result = idlePose()
        guard let target = navigationGripPoint else { return result }
        let local = CGPoint(x: min(150, max(10, target.x)), y: min(150, max(10, target.y)))
        result.rightElbow = CGPoint(x: (result.neck.x + local.x) * 0.52, y: (result.neck.y + local.y) * 0.52 - 7)
        result.rightHand = local
        result.bodyLean = local.x >= 80 ? 0.12 : -0.12
        return result
    }

    private func happyPose() -> StickPose {
        let energy = CGFloat(sin(time * 12)) * 2
        return StickPose(
            head: CGPoint(x: 80, y: 24 + energy), neck: CGPoint(x: 80, y: 47), hip: CGPoint(x: 80, y: 88),
            leftElbow: CGPoint(x: 58, y: 57), leftHand: CGPoint(x: 43, y: 34),
            rightElbow: CGPoint(x: 102, y: 57), rightHand: CGPoint(x: 117, y: 34),
            leftKnee: CGPoint(x: 69, y: 115), leftFoot: CGPoint(x: 54, y: 139),
            rightKnee: CGPoint(x: 92, y: 115), rightFoot: CGPoint(x: 107, y: 139)
        )
    }

    private func speakingPose() -> StickPose {
        let gesture = CGFloat(sin(time * 5.3))
        return StickPose(
            head: CGPoint(x: 80, y: 26), neck: CGPoint(x: 80, y: 49), hip: CGPoint(x: 80, y: 92),
            leftElbow: CGPoint(x: 62, y: 68), leftHand: CGPoint(x: 50 - gesture * 5, y: 76 - gesture * 6),
            rightElbow: CGPoint(x: 99, y: 65), rightHand: CGPoint(x: 112 + gesture * 7, y: 56 + gesture * 8),
            leftKnee: CGPoint(x: 68, y: 119), leftFoot: CGPoint(x: 57, y: 145),
            rightKnee: CGPoint(x: 92, y: 119), rightFoot: CGPoint(x: 104, y: 145),
            headTilt: gesture * 0.035
        )
    }

    private func workingPose() -> StickPose {
        let tap = CGFloat(sin(time * 13)) * 4
        return StickPose(
            head: CGPoint(x: 81, y: 28), neck: CGPoint(x: 80, y: 50), hip: CGPoint(x: 78, y: 93),
            leftElbow: CGPoint(x: 61, y: 68), leftHand: CGPoint(x: 72 + tap, y: 83),
            rightElbow: CGPoint(x: 99, y: 68), rightHand: CGPoint(x: 89 - tap, y: 83),
            leftKnee: CGPoint(x: 68, y: 120), leftFoot: CGPoint(x: 56, y: 145),
            rightKnee: CGPoint(x: 92, y: 120), rightFoot: CGPoint(x: 104, y: 145),
            bodyLean: 0.08
        )
    }

    private func agentWavePose() -> StickPose {
        let progress = taskProgress(duration: 1.55)
        let energy = CGFloat(sin(progress * .pi))
        let wave = CGFloat(sin(progress * .pi * 7)) * energy
        return StickPose(
            head: CGPoint(x: 77 - energy * 2, y: 25 - energy * 2),
            neck: CGPoint(x: 79, y: 48), hip: CGPoint(x: 80, y: 92),
            leftElbow: CGPoint(x: 63, y: 68), leftHand: CGPoint(x: 57, y: 91),
            rightElbow: CGPoint(x: 99 + energy * 3, y: 56 - energy * 7),
            rightHand: CGPoint(x: 112 + wave * 7, y: 35 + wave * 2),
            leftKnee: CGPoint(x: 68, y: 119), leftFoot: CGPoint(x: 56, y: 145),
            rightKnee: CGPoint(x: 93, y: 119), rightFoot: CGPoint(x: 105, y: 145),
            headTilt: -0.07 * energy, bodyLean: -0.04 * energy
        )
    }

    private func browserWandPose() -> StickPose {
        let progress = taskProgress(duration: 1.4)
        let energy = CGFloat(sin(progress * .pi))
        let flick = CGFloat(sin(min(1, progress * 1.35) * .pi)) * energy
        return StickPose(
            head: CGPoint(x: 79, y: 26 - energy), neck: CGPoint(x: 80, y: 49), hip: CGPoint(x: 78, y: 92),
            leftElbow: CGPoint(x: 62, y: 69), leftHand: CGPoint(x: 55, y: 91),
            rightElbow: CGPoint(x: 100 + energy * 3, y: 64 - energy * 4),
            rightHand: CGPoint(x: 116 + flick * 7, y: 52 - flick * 11),
            leftKnee: CGPoint(x: 68, y: 119), leftFoot: CGPoint(x: 56, y: 145),
            rightKnee: CGPoint(x: 92, y: 119), rightFoot: CGPoint(x: 105, y: 145),
            headTilt: 0.06 * energy, bodyLean: 0.07 * energy
        )
    }

    private func calendarPeekPose() -> StickPose {
        let progress = taskProgress(duration: 1.35)
        let energy = CGFloat(sin(progress * .pi))
        return StickPose(
            head: CGPoint(x: 76, y: 27 - energy * 2), neck: CGPoint(x: 79, y: 49), hip: CGPoint(x: 81, y: 93),
            leftElbow: CGPoint(x: 61, y: 66), leftHand: CGPoint(x: 51, y: 61 - energy * 5),
            rightElbow: CGPoint(x: 99, y: 65), rightHand: CGPoint(x: 111 + energy * 4, y: 55 - energy * 4),
            leftKnee: CGPoint(x: 68, y: 119), leftFoot: CGPoint(x: 56, y: 145),
            rightKnee: CGPoint(x: 93, y: 119), rightFoot: CGPoint(x: 105, y: 145),
            headTilt: -0.1 * energy, bodyLean: 0.04 * energy
        )
    }

    private func permissionKeyPose() -> StickPose {
        let progress = taskProgress(duration: 1.45)
        let energy = CGFloat(sin(progress * .pi))
        return StickPose(
            head: CGPoint(x: 79, y: 26), neck: CGPoint(x: 80, y: 49), hip: CGPoint(x: 79, y: 92),
            leftElbow: CGPoint(x: 63, y: 69), leftHand: CGPoint(x: 58, y: 92),
            rightElbow: CGPoint(x: 101 + energy * 4, y: 62 - energy * 4),
            rightHand: CGPoint(x: 120 + energy * 7, y: 54 - energy * 8),
            leftKnee: CGPoint(x: 68, y: 119), leftFoot: CGPoint(x: 56, y: 145),
            rightKnee: CGPoint(x: 92, y: 119), rightFoot: CGPoint(x: 105, y: 145),
            headTilt: 0.05 * energy, bodyLean: 0.05 * energy
        )
    }

    private func connectorLinkPose() -> StickPose {
        let progress = taskProgress(duration: 1.5)
        let energy = CGFloat(sin(progress * .pi))
        return StickPose(
            head: CGPoint(x: 80, y: 25 - energy * 2), neck: CGPoint(x: 80, y: 48), hip: CGPoint(x: 80, y: 92),
            leftElbow: CGPoint(x: 62, y: 63), leftHand: CGPoint(x: 75 - energy * 4, y: 72 - energy * 5),
            rightElbow: CGPoint(x: 98, y: 63), rightHand: CGPoint(x: 85 + energy * 4, y: 72 - energy * 5),
            leftKnee: CGPoint(x: 68, y: 119), leftFoot: CGPoint(x: 56, y: 145),
            rightKnee: CGPoint(x: 92, y: 119), rightFoot: CGPoint(x: 105, y: 145),
            bodyLean: 0
        )
    }

    private func errorPose() -> StickPose {
        let shake = CGFloat(sin(time * 34)) * 4
        return StickPose(
            head: CGPoint(x: 80 + shake, y: 28), neck: CGPoint(x: 80, y: 50), hip: CGPoint(x: 80, y: 94),
            leftElbow: CGPoint(x: 60, y: 62), leftHand: CGPoint(x: 48, y: 49),
            rightElbow: CGPoint(x: 100, y: 62), rightHand: CGPoint(x: 112, y: 49),
            leftKnee: CGPoint(x: 67, y: 120), leftFoot: CGPoint(x: 53, y: 145),
            rightKnee: CGPoint(x: 94, y: 120), rightFoot: CGPoint(x: 108, y: 145)
        )
    }

    private func sleepingPose() -> StickPose {
        let breath = CGFloat(sin(time * 1.25))
        return StickPose(
            head: CGPoint(x: 64, y: 70 + breath), neck: CGPoint(x: 75, y: 85), hip: CGPoint(x: 82, y: 112),
            leftElbow: CGPoint(x: 57, y: 93), leftHand: CGPoint(x: 71, y: 107),
            rightElbow: CGPoint(x: 92, y: 91), rightHand: CGPoint(x: 80, y: 108),
            leftKnee: CGPoint(x: 60, y: 126), leftFoot: CGPoint(x: 45, y: 145),
            rightKnee: CGPoint(x: 104, y: 126), rightFoot: CGPoint(x: 121, y: 145),
            headTilt: -0.38, bodyLean: -0.22
        )
    }

    private func perchedPose() -> StickPose {
        let breath = CGFloat(sin(time * 1.45)) * 0.65
        return StickPose(
            head: CGPoint(x: 77, y: 39 + breath), neck: CGPoint(x: 79, y: 61 + breath), hip: CGPoint(x: 82, y: 100),
            leftElbow: CGPoint(x: 62, y: 77), leftHand: CGPoint(x: 58, y: 108),
            rightElbow: CGPoint(x: 98, y: 77), rightHand: CGPoint(x: 105, y: 108),
            leftKnee: CGPoint(x: 55, y: 113), leftFoot: CGPoint(x: 98, y: 139),
            rightKnee: CGPoint(x: 108, y: 113), rightFoot: CGPoint(x: 65, y: 139),
            headTilt: -0.04, bodyLean: -0.035
        )
    }

    private func combatPose() -> StickPose {
        let bounce = CGFloat(sin(time * 7.8)) * 2.2
        var guardPose = StickPose(
            head: CGPoint(x: 83, y: 29 + bounce), neck: CGPoint(x: 78, y: 51 + bounce), hip: CGPoint(x: 76, y: 91 + bounce),
            leftElbow: CGPoint(x: 61, y: 59 + bounce), leftHand: CGPoint(x: 72, y: 48 + bounce),
            rightElbow: CGPoint(x: 98, y: 59 + bounce), rightHand: CGPoint(x: 91, y: 45 + bounce),
            leftKnee: CGPoint(x: 61, y: 116 + bounce), leftFoot: CGPoint(x: 47, y: 142),
            rightKnee: CGPoint(x: 92, y: 114 + bounce), rightFoot: CGPoint(x: 112, y: 139),
            headTilt: 0.08, bodyLean: 0.1
        )

        let elapsed = max(0, time - combatMoveStartedAt)
        let phase = CGFloat(min(1, elapsed / max(0.01, combatMoveEndsAt - combatMoveStartedAt)))
        let strike = sin(phase * .pi)
        switch combatMove {
        case .guardStance:
            return guardPose
        case .dodge(let direction):
            return guardPose.offsetBy(dx: direction * strike * 20, dy: strike * 6)
        case .jab:
            guardPose.head.x -= strike * 5
            guardPose.neck.x += strike * 7
            guardPose.hip.x += strike * 2
            guardPose.rightElbow = CGPoint(x: 106 + strike * 10, y: 54)
            guardPose.rightHand = CGPoint(x: 100 + strike * 42, y: 49)
            return guardPose
        case .kick:
            guardPose.neck.x += strike * 8
            guardPose.hip.x += strike * 12
            guardPose.rightKnee = CGPoint(x: 98 + strike * 12, y: 102 - strike * 14)
            guardPose.rightFoot = CGPoint(x: 111 + strike * 39, y: 112 - strike * 24)
            guardPose.leftFoot = CGPoint(x: 51, y: 144)
            return guardPose
        case .lasso:
            guardPose.rightElbow = CGPoint(x: 104, y: 48 - strike * 12)
            guardPose.rightHand = CGPoint(x: 120 + strike * 14, y: 35 + sin(phase * .pi * 2) * 16)
            return guardPose
        case .groundSlam:
            guardPose.head.y += strike * 22
            guardPose.neck.y += strike * 24
            guardPose.hip.y += strike * 28
            guardPose.leftHand = CGPoint(x: 54, y: 120 + strike * 24)
            guardPose.rightHand = CGPoint(x: 105, y: 120 + strike * 24)
            guardPose.leftKnee.y += strike * 17
            guardPose.rightKnee.y += strike * 17
            return guardPose
        case .hit(let direction):
            return guardPose.offsetBy(dx: direction.dx * strike * 18, dy: direction.dy * strike * -12)
        case .victory:
            return happyPose().offsetBy(dx: 0, dy: -strike * 12)
        }
    }

    private var visibleTaskAnimation: StickmanTaskAnimation? {
        switch previewState {
        case .agentWave: return .spawnAgent
        case .browserWand: return .openBrowserTab
        case .calendarPeek: return .checkCalendar
        case .permissionKey: return .requestPermission
        case .connectorLink: return .connectService
        default: return taskAnimation
        }
    }

    private func taskProgress(duration: TimeInterval) -> CGFloat {
        let elapsed: TimeInterval
        if previewTime != nil {
            elapsed = time.truncatingRemainder(dividingBy: duration)
        } else {
            elapsed = max(0, time - taskAnimationStartedAt)
        }
        return CGFloat(max(0, min(1, elapsed / duration)))
    }

    private func drawTaskEffects(context: CGContext) {
        guard let visibleTaskAnimation else { return }
        let joints = transformed(pose)
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch visibleTaskAnimation {
        case .spawnAgent:
            let progress = taskProgress(duration: 1.55)
            let energy = CGFloat(sin(progress * .pi))
            let center = CGPoint(x: 130, y: 31)
            let radius = 4 + energy * 13
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.78 * energy).cgColor)
            context.setLineWidth(6)
            context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.72 * energy).cgColor)
            context.setLineWidth(2)
            context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))

            for index in 0 ..< 3 {
                let angle = CGFloat(index) * (.pi * 2 / 3) + progress * 2.4
                let point = CGPoint(x: center.x + cos(angle) * (radius + 7), y: center.y + sin(angle) * (radius + 7))
                context.setFillColor(NSColor.black.withAlphaComponent(0.78 * energy).cgColor)
                context.fillEllipse(in: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4))
            }

        case .openBrowserTab:
            let progress = taskProgress(duration: 1.4)
            let energy = CGFloat(sin(progress * .pi))
            let hand = joints.rightHand
            let tip = CGPoint(x: min(151, hand.x + 24), y: max(12, hand.y - 22))
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.82 * energy).cgColor)
            context.setLineWidth(7)
            context.move(to: hand)
            context.addLine(to: tip)
            context.strokePath()
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.9 * energy).cgColor)
            context.setLineWidth(2.7)
            context.move(to: hand)
            context.addLine(to: tip)
            context.strokePath()

            let tabProgress = max(0, min(1, (progress - 0.24) / 0.42))
            let tabWidth: CGFloat = 34 * tabProgress
            let tabHeight: CGFloat = 22 * tabProgress
            let tabRect = CGRect(x: 109, y: 17, width: tabWidth, height: tabHeight)
            context.setFillColor(NSColor.white.withAlphaComponent(0.86 * energy).cgColor)
            context.fill(tabRect)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.8 * energy).cgColor)
            context.setLineWidth(2)
            context.stroke(tabRect)
            if tabProgress > 0.45 {
                context.move(to: CGPoint(x: tabRect.minX, y: tabRect.minY + 6))
                context.addLine(to: CGPoint(x: tabRect.maxX, y: tabRect.minY + 6))
                context.strokePath()
            }

            context.setFillColor(NSColor.black.withAlphaComponent(energy).cgColor)
            for angleIndex in 0 ..< 4 {
                let angle = CGFloat(angleIndex) * .pi / 2
                let inner = CGPoint(x: tip.x + cos(angle) * 3, y: tip.y + sin(angle) * 3)
                let outer = CGPoint(x: tip.x + cos(angle) * 8, y: tip.y + sin(angle) * 8)
                context.setStrokeColor(NSColor.black.withAlphaComponent(energy).cgColor)
                context.setLineWidth(1.7)
                context.move(to: inner)
                context.addLine(to: outer)
                context.strokePath()
            }

        case .checkCalendar:
            let progress = taskProgress(duration: 1.35)
            let energy = CGFloat(sin(progress * .pi))
            let rect = CGRect(x: 111, y: 29 - energy * 5, width: 34, height: 29)
            context.setFillColor(NSColor.white.withAlphaComponent(0.88 * energy).cgColor)
            context.fill(rect)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.86 * energy).cgColor)
            context.setLineWidth(2)
            context.stroke(rect)
            context.move(to: CGPoint(x: rect.minX, y: rect.minY + 8))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 8))
            context.strokePath()
            for x in [rect.minX + 9, rect.minX + 17, rect.minX + 25] {
                context.fillEllipse(in: CGRect(x: x - 1.5, y: rect.minY + 14, width: 3, height: 3))
            }
            context.move(to: CGPoint(x: rect.minX + 9, y: rect.minY + 22))
            context.addLine(to: CGPoint(x: rect.minX + 14, y: rect.minY + 26))
            context.addLine(to: CGPoint(x: rect.minX + 25, y: rect.minY + 18))
            context.strokePath()

        case .requestPermission:
            let progress = taskProgress(duration: 1.45)
            let energy = CGFloat(sin(progress * .pi))
            let hand = joints.rightHand
            let ringCenter = CGPoint(x: min(148, hand.x + 15), y: hand.y - 7)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.82 * energy).cgColor)
            context.setLineWidth(7)
            context.strokeEllipse(in: CGRect(x: ringCenter.x - 7, y: ringCenter.y - 7, width: 14, height: 14))
            context.move(to: CGPoint(x: ringCenter.x - 5, y: ringCenter.y + 5))
            context.addLine(to: CGPoint(x: hand.x - 5, y: hand.y + 17))
            context.strokePath()
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.88 * energy).cgColor)
            context.setLineWidth(2.5)
            context.strokeEllipse(in: CGRect(x: ringCenter.x - 7, y: ringCenter.y - 7, width: 14, height: 14))
            context.move(to: CGPoint(x: ringCenter.x - 5, y: ringCenter.y + 5))
            context.addLine(to: CGPoint(x: hand.x - 5, y: hand.y + 17))
            context.addLine(to: CGPoint(x: hand.x + 1, y: hand.y + 17))
            context.move(to: CGPoint(x: hand.x - 1, y: hand.y + 12))
            context.addLine(to: CGPoint(x: hand.x + 4, y: hand.y + 12))
            context.strokePath()

        case .connectService:
            let progress = taskProgress(duration: 1.5)
            let energy = CGFloat(sin(progress * .pi))
            let center = CGPoint(x: 80, y: 65)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.82 * energy).cgColor)
            context.setLineWidth(7)
            context.strokeEllipse(in: CGRect(x: center.x - 15, y: center.y - 7, width: 20, height: 14))
            context.strokeEllipse(in: CGRect(x: center.x - 5, y: center.y - 7, width: 20, height: 14))
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.86 * energy).cgColor)
            context.setLineWidth(2.3)
            context.strokeEllipse(in: CGRect(x: center.x - 15, y: center.y - 7, width: 20, height: 14))
            context.strokeEllipse(in: CGRect(x: center.x - 5, y: center.y - 7, width: 20, height: 14))
            for angleIndex in 0 ..< 3 {
                let angle = -CGFloat.pi / 2 + CGFloat(angleIndex - 1) * 0.5
                context.move(to: CGPoint(x: center.x + cos(angle) * 11, y: center.y + sin(angle) * 11))
                context.addLine(to: CGPoint(x: center.x + cos(angle) * 17, y: center.y + sin(angle) * 17))
                context.strokePath()
            }
        }
        context.restoreGState()
    }

    private func drawStickFigure(pose: StickPose, context: CGContext) {
        let joints = transformed(pose)
        let whiteHalo = NSColor.white.withAlphaComponent(0.72)
        strokeSkeleton(joints, context: context, color: whiteHalo, width: 12)
        strokeSkeleton(joints, context: context, color: .black, width: mode == .sparring ? 7.5 : 7)

        context.saveGState()
        let headRadius: CGFloat = 17
        context.translateBy(x: joints.head.x, y: joints.head.y)
        context.rotate(by: pose.headTilt)
        context.setStrokeColor(whiteHalo.cgColor)
        context.setLineWidth(12)
        context.strokeEllipse(in: CGRect(x: -headRadius, y: -headRadius, width: headRadius * 2, height: headRadius * 2))
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(mode == .sparring ? 7.5 : 7)
        context.strokeEllipse(in: CGRect(x: -headRadius, y: -headRadius, width: headRadius * 2, height: headRadius * 2))
        context.restoreGState()

        if mode == .sparring {
            drawCombatFocusMark(at: joints.head, context: context)
        }
    }

    private func transformed(_ pose: StickPose) -> StickPose {
        guard abs(pose.bodyLean) > 0.001 else { return pose }
        let pivot = pose.hip
        func rotate(_ point: CGPoint) -> CGPoint {
            let angle = pose.bodyLean
            let dx = point.x - pivot.x
            let dy = point.y - pivot.y
            return CGPoint(
                x: pivot.x + dx * cos(angle) - dy * sin(angle),
                y: pivot.y + dx * sin(angle) + dy * cos(angle)
            )
        }
        var copy = pose
        copy.head = rotate(pose.head)
        copy.neck = rotate(pose.neck)
        copy.leftElbow = rotate(pose.leftElbow)
        copy.leftHand = rotate(pose.leftHand)
        copy.rightElbow = rotate(pose.rightElbow)
        copy.rightHand = rotate(pose.rightHand)
        return copy
    }

    private func strokeSkeleton(_ pose: StickPose, context: CGContext, color: NSColor, width: CGFloat) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        func segment(_ points: [CGPoint]) {
            guard let first = points.first else { return }
            context.move(to: first)
            points.dropFirst().forEach(context.addLine)
            context.strokePath()
        }

        segment([pose.neck, pose.hip])
        segment([pose.neck, pose.leftElbow, pose.leftHand])
        segment([pose.neck, pose.rightElbow, pose.rightHand])
        segment([pose.hip, pose.leftKnee, pose.leftFoot])
        segment([pose.hip, pose.rightKnee, pose.rightFoot])
        context.restoreGState()
    }

    private func drawShadow(context: CGContext) {
        let feetY = max(pose.leftFoot.y, pose.rightFoot.y)
        let jumpHeight = max(0, 145 - feetY)
        let width = max(24, 64 - jumpHeight * 0.4)
        context.setFillColor(NSColor.black.withAlphaComponent(max(0.05, 0.16 - jumpHeight * 0.002)).cgColor)
        context.fillEllipse(in: CGRect(x: 80 - width / 2, y: 148, width: width, height: 7))
    }

    private func drawMotionAccents(context: CGContext) {
        guard mode == .sparring else { return }
        let elapsed = time - combatMoveStartedAt
        guard elapsed < 0.48 else { return }
        switch combatMove {
        case .jab, .kick, .dodge, .hit:
            context.saveGState()
            context.setStrokeColor(NSColor.black.withAlphaComponent(max(0, 0.35 - CGFloat(elapsed) * 0.6)).cgColor)
            context.setLineWidth(2)
            for index in 0 ..< 3 {
                let y = 54 + CGFloat(index * 12)
                context.move(to: CGPoint(x: 18, y: y))
                context.addLine(to: CGPoint(x: 45 + CGFloat(index * 4), y: y - 3))
            }
            context.strokePath()
            context.restoreGState()
        default:
            break
        }
    }

    private func drawCombatFocusMark(at head: CGPoint, context: CGContext) {
        guard case .guardStance = combatMove else { return }
        let pulse = CGFloat((sin(time * 8) + 1) * 0.5)
        context.setFillColor(NSColor.black.withAlphaComponent(0.35 + pulse * 0.25).cgColor)
        context.fillEllipse(in: CGRect(x: head.x + 12, y: head.y - 11, width: 4, height: 4))
    }

    private func drawChatHint() {
        guard showsChatHint, !isChatVisible, mode == .peaceful else { return }
        let scale = min(bounds.width, bounds.height) / StickmanMetrics.designSize
        let rect = CGRect(x: 121 * scale, y: 12 * scale, width: 29 * scale, height: 21 * scale)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8 * scale, yRadius: 8 * scale)
        NSColor.white.withAlphaComponent(0.9).setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.75).setStroke()
        path.lineWidth = max(1, 1.5 * scale)
        path.stroke()
        NSColor.black.withAlphaComponent(0.72).setFill()
        for index in 0 ..< 3 {
            NSBezierPath(ovalIn: CGRect(
                x: (129 + CGFloat(index) * 7) * scale,
                y: 21 * scale,
                width: 3 * scale,
                height: 3 * scale
            )).fill()
        }
    }
}
