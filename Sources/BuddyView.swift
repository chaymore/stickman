import AppKit

/// What the body is doing in the world, reported by the window controller every frame.
enum StickmanMotion: Equatable {
    /// Standing or walking on a ledge. Velocity is in screen points per second.
    case grounded(velocityX: CGFloat)
    /// Winding up before a jump, from 0 to 1.
    case crouching(progress: CGFloat)
    case airborne(velocity: CGVector, planned: Bool)
    case held(velocity: CGVector)
}

enum StickmanFidget: CaseIterable {
    case lookAround
    case stretch
    case tapFoot
    case wave

    var duration: TimeInterval {
        switch self {
        case .lookAround: return 2.4
        case .stretch: return 2.2
        case .tapFoot: return 2.0
        case .wave: return 1.6
        }
    }
}

enum StickmanRest: Equatable {
    case awake
    case sitting
    case sleeping
}

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
        case walking
        case running
        case crouching
        case jumping
        case falling
        case landing
        case held
        case listening
        case thinking
        case happy
        case speaking
        case working
        case agentWave
        case browserWand
        case calendarPeek
        case permissionKey
        case connectorLink
        case stretching
        case error
        case perched
        case sleeping
        case sparring
        case punch
        case kick

        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    var onToggleChat: (() -> Void)?
    var onCursorStrike: ((CGPoint) -> Void)?
    var onDragBegan: ((CGPoint) -> Void)?
    var onDragMoved: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?
    var onPoke: (() -> Void)?

    // MARK: Skeleton

    private enum Bone {
        static let torso: CGFloat = 44
        static let neck: CGFloat = 22
        static let upperArm: CGFloat = 24
        static let forearm: CGFloat = 23
        static let thigh: CGFloat = 29
        static let shin: CGFloat = 28.8
        static let ground: CGFloat = 145
        static let headRadius: CGFloat = 17
    }

    private enum StickmanState: Equatable {
        case idle
        case listening
        case thinking
        case locomotion
        case happy
        case speaking
        case working
        case agentWave
        case browserWand
        case calendarPeek
        case permissionKey
        case connectorLink
        case error
        case sitting
        case sleeping
        case combat(serial: Int)
        case crouching
        case airborne
        case landing
        case held
        case fidget(StickmanFidget)
    }

    /// An authored pose. Hands and feet are IK targets; elbows and knees only pick the bend side.
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
        /// Rotation of the whole body around the head, used while dangling from the cursor.
        var hangSwing: CGFloat = 0

        func blended(toward other: StickPose, amount: CGFloat) -> StickPose {
            func point(_ a: CGPoint, _ b: CGPoint) -> CGPoint { SMath.mix(a, b, amount) }
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
                headTilt: SMath.mix(headTilt, other.headTilt, amount),
                bodyLean: SMath.mix(bodyLean, other.bodyLean, amount),
                hangSwing: SMath.mix(hangSwing, other.hangSwing, amount)
            )
        }

        func offsetBy(dx: CGFloat, dy: CGFloat) -> StickPose {
            var copy = self
            for keyPath in StickPose.points { copy[keyPath: keyPath].x += dx; copy[keyPath: keyPath].y += dy }
            return copy
        }

        static let points: [WritableKeyPath<StickPose, CGPoint>] = [
            \.head, \.neck, \.hip, \.leftElbow, \.leftHand, \.rightElbow, \.rightHand,
            \.leftKnee, \.leftFoot, \.rightKnee, \.rightFoot
        ]
    }

    /// The solved figure that gets drawn: every bone at its true length.
    private struct Skeleton {
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
    }

    // MARK: State

    private var time: TimeInterval = 0
    private var activity: Activity = .quiet
    private var mode: StickmanMode = .peaceful
    private var rest: StickmanRest = .awake
    private var isChatVisible = false
    private var motion: StickmanMotion = .grounded(velocityX: 0)
    private var heightAboveGround: CGFloat = 0
    private var isWalking = false
    private var gaitPhase: CGFloat = 0
    private static let walkStride: CGFloat = 46
    private static let runStride: CGFloat = 68
    private var strideLength: CGFloat = 46
    private var runBlend: CGFloat = 0
    private var smoothedAcceleration: CGFloat = 0
    private var lastGroundVelocity: CGFloat = 0
    private var swingAngle: CGFloat = 0
    private var swingVelocity: CGFloat = 0
    private(set) var facingDirection: CGFloat = 1
    private var facingScale: CGFloat = 1
    private var transientState: StickmanState?
    private var transientEndsAt: TimeInterval = 0
    private var taskAnimation: StickmanTaskAnimation?
    private var taskAnimationStartedAt: TimeInterval = 0
    private var taskAnimationEndsAt: TimeInterval = 0
    private var fidget: StickmanFidget?
    private var fidgetStartedAt: TimeInterval = 0
    private var landingStartedAt: TimeInterval = -10
    private var landingDuration: TimeInterval = 0
    private var landingImpact: CGFloat = 0
    private var combatMove: StickmanCombatMove = .guardStance
    private var combatMoveStartedAt: TimeInterval = 0
    private var combatMoveEndsAt: TimeInterval = 0
    private var combatSerial = 0
    private var previewState: PreviewState?

    private var displayedState: StickmanState = .idle
    private var transitionFrom: StickPose?
    private var transitionStartedAt: TimeInterval = 0
    private var transitionDuration: TimeInterval = 0.2
    private var blendedPose = StickmanView.neutralPose()
    private var skeleton: Skeleton

    private var mouseDownScreenPoint: CGPoint?
    private var isDraggingFigure = false
    private var pendingPoke: DispatchWorkItem?
    private var isHovering = false
    private var hoverAlpha: CGFloat = 0

    override init(frame frameRect: NSRect) {
        skeleton = StickmanView.solve(StickmanView.neutralPose())
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var renderScale: CGFloat { max(0.01, min(bounds.width, bounds.height) / StickmanMetrics.designSize) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        context.saveGState()
        context.scaleBy(x: renderScale, y: renderScale)

        drawShadow(context: context)
        drawLandingDust(context: context)

        context.saveGState()
        let flip = facingScale >= 0 ? max(0.08, facingScale) : min(-0.08, facingScale)
        context.translateBy(x: 80, y: 0)
        context.scaleBy(x: flip, y: 1)
        context.translateBy(x: -80, y: 0)
        drawMotionAccents(context: context)
        drawStickFigure(context: context)
        drawTaskEffects(context: context)
        context.restoreGState()

        drawSleepMarks(context: context, flip: flip)
        context.restoreGState()

        drawChatHint()
    }

    private func drawStickFigure(context: CGContext) {
        let halo = NSColor.white.withAlphaComponent(0.72)
        let width: CGFloat = mode == .sparring ? 7.5 : 7
        strokeSkeleton(skeleton, context: context, color: halo, width: width + 5)
        strokeSkeleton(skeleton, context: context, color: .black, width: width)

        let r = Bone.headRadius
        let headRect = CGRect(x: skeleton.head.x - r, y: skeleton.head.y - r, width: r * 2, height: r * 2)
        context.setStrokeColor(halo.cgColor)
        context.setLineWidth(width + 5)
        context.strokeEllipse(in: headRect)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(width)
        context.strokeEllipse(in: headRect)

        if mode == .sparring { drawCombatFocusMark(at: skeleton.head, context: context) }
    }

    private func strokeSkeleton(_ figure: Skeleton, context: CGContext, color: NSColor, width: CGFloat) {
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

        segment([figure.neck, figure.hip])
        segment([figure.neck, figure.leftElbow, figure.leftHand])
        segment([figure.neck, figure.rightElbow, figure.rightHand])
        segment([figure.hip, figure.leftKnee, figure.leftFoot])
        segment([figure.hip, figure.rightKnee, figure.rightFoot])
        context.restoreGState()
    }

    private func drawShadow(context: CGContext) {
        let lift = heightAboveGround / renderScale
        let feetY = max(skeleton.leftFoot.y, skeleton.rightFoot.y)
        let poseLift = max(0, Bone.ground - feetY)
        let total = lift + poseLift
        guard total < 90 else { return }
        let width = max(18, 62 - total * 0.5)
        let alpha = max(0, 0.16 - total * 0.0018)
        context.setFillColor(NSColor.black.withAlphaComponent(alpha).cgColor)
        let centerX = 80 + (skeleton.hip.x - 80) * 0.6 * (facingScale >= 0 ? 1 : -1)
        context.fillEllipse(in: CGRect(x: centerX - width / 2, y: 148 + lift, width: width, height: 7))
    }

    private func drawLandingDust(context: CGContext) {
        let elapsed = time - landingStartedAt
        guard landingImpact > 520, elapsed < 0.42 else { return }
        let progress = CGFloat(elapsed / 0.42)
        let strength = min(1, (landingImpact - 520) / 1200)
        context.saveGState()
        context.setLineCap(.round)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.5 * (1 - progress) * (0.4 + strength * 0.6)).cgColor)
        context.setLineWidth(2.2)
        for side in [-1.0, 1.0] as [CGFloat] {
            for index in 0 ..< 3 {
                let spread = 18 + progress * (26 + strength * 18) + CGFloat(index) * 6
                let x = 80 + side * spread
                let y = 146 - CGFloat(index) * 4 - progress * 6
                context.move(to: CGPoint(x: x - side * 5, y: y + 2))
                context.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.strokePath()
        context.restoreGState()
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

    private func drawSleepMarks(context: CGContext, flip: CGFloat) {
        guard displayedState == .sleeping || previewState == .sleeping else { return }
        // Drawn outside the facing flip so the letters never mirror.
        let headX = 80 + (skeleton.head.x - 80) * flip
        let side: CGFloat = flip >= 0 ? 1 : -1
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for index in 0 ..< 3 {
            let phase = CGFloat((time * 0.42 + Double(index) / 3).truncatingRemainder(dividingBy: 1))
            let size = 5 + phase * 5
            let origin = CGPoint(x: headX + side * (14 + phase * 20), y: skeleton.head.y - 14 - phase * 30)
            context.setStrokeColor(NSColor.black.withAlphaComponent(sin(phase * .pi) * 0.8).cgColor)
            context.setLineWidth(1.8 + phase * 0.6)
            context.move(to: origin)
            context.addLine(to: CGPoint(x: origin.x + size, y: origin.y))
            context.addLine(to: CGPoint(x: origin.x, y: origin.y + size))
            context.addLine(to: CGPoint(x: origin.x + size, y: origin.y + size))
            context.strokePath()
        }
        context.restoreGState()
    }

    private func drawChatHint() {
        guard hoverAlpha > 0.01, previewState == nil else { return }
        let scale = renderScale
        let rect = CGRect(x: 118 * scale, y: 6 * scale, width: 32 * scale, height: 22 * scale)
        let path = NSBezierPath(roundedRect: rect, xRadius: 11 * scale, yRadius: 11 * scale)
        NSColor.white.withAlphaComponent(0.94 * hoverAlpha).setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.7 * hoverAlpha).setStroke()
        path.lineWidth = max(1, 1.4 * scale)
        path.stroke()
        NSColor.black.withAlphaComponent(0.72 * hoverAlpha).setFill()
        for index in 0 ..< 3 {
            NSBezierPath(ovalIn: CGRect(
                x: (126.5 + CGFloat(index) * 6.5) * scale,
                y: 15.5 * scale,
                width: 3 * scale,
                height: 3 * scale
            )).fill()
        }
    }

    // MARK: Input

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }

    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func mouseDown(with event: NSEvent) {
        let screenPoint = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation

        if mode == .sparring {
            onCursorStrike?(screenPoint)
            performCombatMove(.hit(direction: CGVector(dx: 0.7, dy: 0.25)))
            return
        }
        if event.clickCount >= 3 {
            pendingPoke?.cancel()
            // Option keeps a burst of pokes from starting a fight by accident.
            if event.modifierFlags.contains(.option) {
                StickmanModeController.shared.beginSparringFromTripleClick()
            }
            return
        }
        if event.clickCount == 2 {
            pendingPoke?.cancel()
            onToggleChat?()
            return
        }
        mouseDownScreenPoint = screenPoint
        isDraggingFigure = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .peaceful, let start = mouseDownScreenPoint else { return }
        let point = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        if !isDraggingFigure {
            guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
            isDraggingFigure = true
            pendingPoke?.cancel()
            onDragBegan?(start)
        }
        onDragMoved?(point)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownScreenPoint = nil
            isDraggingFigure = false
        }
        guard mode == .peaceful, mouseDownScreenPoint != nil else { return }
        if isDraggingFigure {
            let point = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            onDragEnded?(point)
            return
        }
        guard event.clickCount == 1 else { return }
        // Wait out the double-click window so opening chat does not also trigger a poke.
        let poke = DispatchWorkItem { [weak self] in self?.onPoke?() }
        pendingPoke = poke
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: poke)
    }

    // MARK: Controller API

    func tick(dt: TimeInterval) {
        guard previewState == nil else { return }
        time += dt
        let step = CGFloat(dt)
        advanceGait(dt: step)
        advanceFacing(dt: step)
        advanceSwing(dt: step)
        hoverAlpha = SMath.approach(hoverAlpha, wantsChatHint ? 1 : 0, step * 6)

        if time > transientEndsAt { transientState = nil }
        if time > taskAnimationEndsAt { taskAnimation = nil }
        if let fidget, time - fidgetStartedAt > fidget.duration { self.fidget = nil }
        if mode == .sparring, time > combatMoveEndsAt, !isGuarding {
            combatMove = .guardStance
            combatSerial += 1
        }

        let state = currentState()
        if state != displayedState {
            transitionFrom = blendedPose
            transitionStartedAt = time
            transitionDuration = Self.transitionDuration(from: displayedState, to: state)
            displayedState = state
        }

        let target = targetPose(for: state)
        if let from = transitionFrom {
            let progress = CGFloat((time - transitionStartedAt) / max(0.001, transitionDuration))
            blendedPose = from.blended(toward: target, amount: SMath.smoothstep(0, 1, progress))
            if progress >= 1 { transitionFrom = nil }
        } else {
            blendedPose = target
        }
        skeleton = Self.solve(blendedPose)
        needsDisplay = true
    }

    func updateMotion(_ motion: StickmanMotion, heightAboveGround: CGFloat) {
        self.motion = motion
        self.heightAboveGround = max(0, heightAboveGround)
        if case .grounded = motion {} else { fidget = nil }
        if case .held = motion { rest = .awake }
    }

    func playLanding(impact: CGFloat) {
        landingImpact = impact
        landingStartedAt = time
        landingDuration = impact > 1500 ? 0.78 : 0.18 + min(0.3, Double(impact) / 3800)
        fidget = nil
    }

    func setFacing(_ direction: CGFloat) {
        guard abs(direction) > 0.1 else { return }
        facingDirection = direction >= 0 ? 1 : -1
    }

    func setChatVisible(_ isVisible: Bool) {
        isChatVisible = isVisible
        if isVisible { rest = .awake }
    }

    func setActivity(_ activity: Activity) {
        self.activity = activity
    }

    func setRest(_ rest: StickmanRest) {
        self.rest = rest
    }

    var currentRest: StickmanRest { rest }

    /// True when nothing scripted is playing, so the controller may start an idle behavior.
    var isAvailableForIdleBehavior: Bool {
        fidget == nil && taskAnimation == nil && transientState == nil && !isLanding && activity == .quiet && !isChatVisible
    }

    func playFidget(_ fidget: StickmanFidget) {
        guard mode == .peaceful else { return }
        rest = .awake
        self.fidget = fidget
        fidgetStartedAt = time
    }

    func showSuccessMoment() {
        transientState = .happy
        transientEndsAt = time + 1.15
    }

    func showErrorMoment() {
        transientState = .error
        transientEndsAt = time + 1.1
    }

    func performTaskAnimation(_ animation: StickmanTaskAnimation) {
        guard mode == .peaceful else { return }
        rest = .awake
        taskAnimation = animation
        taskAnimationStartedAt = time
        taskAnimationEndsAt = time + Self.taskDuration(animation)
    }

    func setMode(_ mode: StickmanMode) {
        self.mode = mode
        if mode == .sparring {
            rest = .awake
            isChatVisible = false
            fidget = nil
            performCombatMove(.guardStance)
        } else {
            combatMove = .guardStance
            transientState = .happy
            transientEndsAt = time + 0.8
        }
    }

    func performCombatMove(_ move: StickmanCombatMove) {
        combatMove = move
        combatMoveStartedAt = time
        combatSerial += 1
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
    }

    @objc private func modeDidChange(_ notification: Notification) {
        let rawValue = notification.userInfo?["mode"] as? String
        guard let rawValue, let newMode = StickmanMode(rawValue: rawValue) else { return }
        setMode(newMode)
    }

    // MARK: Preview rendering

    func setPreviewState(_ previewState: PreviewState, time: TimeInterval) {
        self.previewState = previewState
        self.time = time
        mode = [.sparring, .punch, .kick].contains(previewState) ? .sparring : .peaceful
        motion = .grounded(velocityX: 0)
        heightAboveGround = 0
        rest = .awake
        activity = .quiet
        fidget = nil
        taskAnimation = nil
        transientState = nil
        landingStartedAt = -10
        runBlend = 0
        strideLength = Self.walkStride
        facingScale = 1

        switch previewState {
        case .walking, .running:
            let speed: CGFloat = previewState == .walking ? 92 : 245
            motion = .grounded(velocityX: speed)
            isWalking = true
            runBlend = SMath.smoothstep(130, 220, speed)
            strideLength = SMath.mix(Self.walkStride, Self.runStride, runBlend)
            gaitPhase = CGFloat(time) * (speed / renderScale) / (2 * strideLength)
            gaitPhase -= floor(gaitPhase)
        case .crouching:
            motion = .crouching(progress: CGFloat(time.truncatingRemainder(dividingBy: 0.5) / 0.5))
        case .jumping:
            let t = CGFloat(time.truncatingRemainder(dividingBy: 0.9) / 0.9)
            motion = .airborne(velocity: CGVector(dx: 180, dy: 900 - t * 1800), planned: true)
            heightAboveGround = 60
        case .falling:
            motion = .airborne(velocity: CGVector(dx: 40, dy: -1500), planned: false)
            heightAboveGround = 200
        case .landing:
            landingImpact = 1100
            landingDuration = 0.18 + min(0.3, Double(landingImpact) / 3800)
            landingStartedAt = floor(time / 0.6) * 0.6
        case .held:
            motion = .held(velocity: CGVector(dx: CGFloat(sin(time * 3)) * 600, dy: 0))
            swingAngle = CGFloat(sin(time * 3 - 0.8)) * -0.35
            heightAboveGround = 120
        case .listening: activity = .listening
        case .thinking: activity = .thinking
        case .speaking: activity = .speaking
        case .working: activity = .working
        case .happy: transientState = .happy; transientEndsAt = .infinity
        case .error: transientState = .error; transientEndsAt = .infinity
        case .agentWave, .browserWand, .calendarPeek, .permissionKey, .connectorLink:
            let animation = Self.taskAnimation(for: previewState) ?? .spawnAgent
            let duration = Self.taskDuration(animation)
            taskAnimation = animation
            taskAnimationStartedAt = floor(time / duration) * duration
            taskAnimationEndsAt = .infinity
        case .stretching:
            fidget = .stretch
            fidgetStartedAt = floor(time / StickmanFidget.stretch.duration) * StickmanFidget.stretch.duration
        case .perched: rest = .sitting
        case .sleeping: rest = .sleeping
        case .punch, .kick:
            let duration = previewState == .punch ? 0.72 : 0.9
            combatMove = previewState == .punch ? .jab : .kick
            combatMoveStartedAt = floor(time / duration) * duration
            combatMoveEndsAt = combatMoveStartedAt + duration
        case .idle, .sparring:
            break
        }

        let state = currentState()
        displayedState = state
        transitionFrom = nil
        blendedPose = targetPose(for: state)
        skeleton = Self.solve(blendedPose)
        needsDisplay = true
    }

    // MARK: Vector export

    /// The current pose as SVG strokes in the 160-point design space, for web pages.
    func skeletonSVG() -> String {
        let figure = skeleton
        func point(_ p: CGPoint) -> String { String(format: "%.1f,%.1f", p.x, p.y) }
        let limbs = [
            [figure.neck, figure.hip],
            [figure.neck, figure.leftElbow, figure.leftHand],
            [figure.neck, figure.rightElbow, figure.rightHand],
            [figure.hip, figure.leftKnee, figure.leftFoot],
            [figure.hip, figure.rightKnee, figure.rightFoot]
        ]
        let polylines = limbs.map { "<polyline points=\"\($0.map(point).joined(separator: " "))\"/>" }.joined()
        return polylines + String(format: "<circle cx=\"%.1f\" cy=\"%.1f\" r=\"%.1f\"/>", figure.head.x, figure.head.y, Bone.headRadius)
    }

    /// Guard stance at two points in its bounce, then a jab at full extension.
    static func fightingPoseFrames() -> [String] {
        let view = StickmanView(frame: NSRect(x: 0, y: 0, width: StickmanMetrics.characterSize, height: StickmanMetrics.characterSize))
        view.setPreviewState(.sparring, time: 0.2)
        let guardHigh = view.skeletonSVG()
        view.setPreviewState(.sparring, time: 0.6)
        let guardLow = view.skeletonSVG()
        view.setPreviewState(.punch, time: 0.36)
        let jab = view.skeletonSVG()
        return [guardHigh, guardLow, jab]
    }

    // MARK: State selection

    private var isLanding: Bool { time - landingStartedAt < landingDuration }

    private var isGuarding: Bool {
        if case .guardStance = combatMove { return true }
        return false
    }

    private var wantsChatHint: Bool {
        isHovering && !isChatVisible && mode == .peaceful && !isDraggingFigure
    }

    private func currentState() -> StickmanState {
        switch motion {
        case .held: return .held
        case .airborne: return .airborne
        case .crouching: return .crouching
        case .grounded: break
        }
        if isLanding { return .landing }
        if mode == .sparring { return .combat(serial: combatSerial) }
        if let taskAnimation { return Self.state(for: taskAnimation) }
        if let transientState { return transientState }
        if isWalking { return .locomotion }
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
        if let fidget { return .fidget(fidget) }
        switch rest {
        case .sitting: return .sitting
        case .sleeping: return .sleeping
        case .awake: return .idle
        }
    }

    private static func transitionDuration(from: StickmanState, to: StickmanState) -> TimeInterval {
        switch (from, to) {
        case (_, .landing), (.crouching, .airborne): return 0.05
        case (.combat, .combat): return 0.07
        case (_, .held), (_, .crouching): return 0.12
        case (.airborne, _), (.held, _): return 0.1
        case (_, .sleeping), (.sleeping, _): return 0.8
        case (_, .sitting), (.sitting, _): return 0.45
        case (_, .locomotion), (.locomotion, _): return 0.18
        default: return 0.24
        }
    }

    private static func state(for animation: StickmanTaskAnimation) -> StickmanState {
        switch animation {
        case .spawnAgent: return .agentWave
        case .openBrowserTab: return .browserWand
        case .checkCalendar: return .calendarPeek
        case .requestPermission: return .permissionKey
        case .connectService: return .connectorLink
        }
    }

    private static func taskAnimation(for preview: PreviewState) -> StickmanTaskAnimation? {
        switch preview {
        case .agentWave: return .spawnAgent
        case .browserWand: return .openBrowserTab
        case .calendarPeek: return .checkCalendar
        case .permissionKey: return .requestPermission
        case .connectorLink: return .connectService
        default: return nil
        }
    }

    private static func taskDuration(_ animation: StickmanTaskAnimation) -> TimeInterval {
        switch animation {
        case .spawnAgent: return 1.55
        case .openBrowserTab: return 1.4
        case .checkCalendar: return 1.35
        case .requestPermission: return 1.45
        case .connectService: return 1.5
        }
    }

    // MARK: Per-frame dynamics

    private var groundVelocityX: CGFloat {
        if case .grounded(let velocity) = motion { return velocity }
        return 0
    }

    private func advanceGait(dt: CGFloat) {
        let velocity = groundVelocityX
        let speed = abs(velocity)
        if isWalking { isWalking = speed > 4 } else { isWalking = speed > 10 }

        let acceleration = (velocity - lastGroundVelocity) / max(dt, 0.001)
        lastGroundVelocity = velocity
        let towardFacing = acceleration * facingDirection
        smoothedAcceleration += (towardFacing - smoothedAcceleration) * min(1, dt * 8)

        runBlend = SMath.smoothstep(130, 220, speed)
        let walkReference: CGFloat = 92
        let baseStride = SMath.mix(Self.walkStride, Self.runStride, runBlend)
        strideLength = baseStride * min(1, max(0.45, 0.45 + 0.55 * speed / walkReference))
        // Phase advances with distance travelled, so planted feet never slide.
        gaitPhase += (speed / renderScale) * dt / (2 * strideLength)
        gaitPhase -= floor(gaitPhase)
    }

    private func advanceFacing(dt: CGFloat) {
        var target = facingDirection
        if let fidget, fidget == .lookAround {
            let progress = (time - fidgetStartedAt) / fidget.duration
            if progress > 0.38, progress < 0.78 { target = -facingDirection }
        }
        facingScale = SMath.approach(facingScale, target, dt * 11)
    }

    private func advanceSwing(dt: CGFloat) {
        // Pendulum: the body trails behind the direction the cursor drags it.
        var targetAngle: CGFloat = 0
        if case .held(let velocity) = motion {
            targetAngle = max(-0.6, min(0.6, -velocity.dx * 0.00055)) * (facingScale >= 0 ? 1 : -1)
        }
        let stiffness: CGFloat = 70
        let damping: CGFloat = 7
        swingVelocity += ((targetAngle - swingAngle) * stiffness - swingVelocity * damping) * dt
        swingAngle += swingVelocity * dt
    }

    // MARK: Poses

    private func targetPose(for state: StickmanState) -> StickPose {
        switch state {
        case .idle: return idlePose()
        case .listening: return listeningPose()
        case .thinking: return thinkingPose()
        case .locomotion: return gaitPose()
        case .happy: return happyPose()
        case .speaking: return speakingPose()
        case .working: return workingPose()
        case .agentWave: return agentWavePose()
        case .browserWand: return browserWandPose()
        case .calendarPeek: return calendarPeekPose()
        case .permissionKey: return permissionKeyPose()
        case .connectorLink: return connectorLinkPose()
        case .error: return errorPose()
        case .sitting: return sittingPose()
        case .sleeping: return sleepingPose()
        case .combat: return combatPose()
        case .crouching: return crouchPose()
        case .airborne: return airbornePose()
        case .landing: return landingPose()
        case .held: return heldPose()
        case .fidget(let fidget): return fidgetPose(fidget)
        }
    }

    private static func neutralPose() -> StickPose {
        StickPose(
            head: CGPoint(x: 80, y: 26), neck: CGPoint(x: 80, y: 48), hip: CGPoint(x: 80, y: 92),
            leftElbow: CGPoint(x: 65, y: 67), leftHand: CGPoint(x: 60, y: 90),
            rightElbow: CGPoint(x: 95, y: 67), rightHand: CGPoint(x: 100, y: 90),
            leftKnee: CGPoint(x: 68, y: 119), leftFoot: CGPoint(x: 59, y: 145),
            rightKnee: CGPoint(x: 92, y: 119), rightFoot: CGPoint(x: 102, y: 145)
        )
    }

    private func idlePose() -> StickPose {
        let breath = CGFloat(sin(time * 1.7))
        let shift = CGFloat(sin(time * 0.55))
        let sway = CGFloat(sin(time * 0.82))
        return StickPose(
            head: CGPoint(x: 80 + shift * 1.6 + sway * 0.8, y: 26 + breath * 0.7),
            neck: CGPoint(x: 80 + shift * 1.6, y: 48 + breath * 0.5),
            hip: CGPoint(x: 80 + shift * 2.4, y: 92 + abs(shift) * 0.7),
            leftElbow: CGPoint(x: 65 + shift, y: 69 + breath), leftHand: CGPoint(x: 60 + shift * 1.4, y: 92 + breath),
            rightElbow: CGPoint(x: 96 + shift, y: 68 - breath * 0.3), rightHand: CGPoint(x: 101 + shift * 1.4, y: 91),
            leftKnee: CGPoint(x: 67, y: 119), leftFoot: CGPoint(x: 59, y: 145),
            rightKnee: CGPoint(x: 93, y: 119), rightFoot: CGPoint(x: 102, y: 145),
            headTilt: sway * 0.05, bodyLean: shift * 0.02
        )
    }

    private func gaitPose() -> StickPose {
        let run = runBlend
        let speedDesign = abs(groundVelocityX) / renderScale
        let amplitude = min(1, speedDesign / 40)
        let stanceFraction = 0.5 - 0.14 * run
        let travel = 2 * strideLength * stanceFraction
        let lift = (9 + 7 * run) * amplitude

        func foot(_ phase: CGFloat) -> (offset: CGFloat, lift: CGFloat) {
            let p = phase - floor(phase)
            if p < stanceFraction {
                let t = p / stanceFraction
                return (travel / 2 - travel * t, 0)
            }
            let t = (p - stanceFraction) / (1 - stanceFraction)
            let eased = t * t * (3 - 2 * t)
            return (-travel / 2 + travel * eased, sin(t * .pi) * lift)
        }

        let left = foot(gaitPhase)
        let right = foot(gaitPhase + 0.5)
        let walkBob = cos(gaitPhase * 4 * .pi) * 2
        let runBob = cos((gaitPhase - stanceFraction / 2) * 4 * .pi) * 2.5
        let bob = (walkBob * (1 - run) + runBob * run) * amplitude
        let hipX: CGFloat = 80
        let hipY = 90 + 2 * run + bob
        let accelerationLean = max(-0.08, min(0.08, smoothedAcceleration * 0.00012))
        let lean = (0.05 + 0.17 * run) * amplitude + accelerationLean
        let neck = CGPoint(x: hipX, y: hipY - Bone.torso)
        let head = CGPoint(x: hipX + 1 + 2 * run, y: neck.y - Bone.neck)

        func footPoint(_ f: (offset: CGFloat, lift: CGFloat)) -> CGPoint {
            CGPoint(x: hipX + f.offset, y: Bone.ground - f.lift)
        }
        func kneeHint(_ foot: CGPoint) -> CGPoint {
            CGPoint(x: max(foot.x, hipX) + 12, y: (hipY + foot.y) / 2)
        }
        func arm(oppositeOf offset: CGFloat) -> (hand: CGPoint, elbow: CGPoint) {
            let swing = -offset * amplitude
            let walkHand = CGPoint(x: neck.x + swing * 0.8, y: neck.y + 44.5 - abs(swing) * 0.12)
            let walkElbow = CGPoint(x: neck.x + swing * 0.3 - 5, y: neck.y + 22)
            let runHand = CGPoint(x: neck.x + 6 + swing * 0.75, y: neck.y + 30 - swing * 0.3)
            let runElbow = CGPoint(x: neck.x - 16 + swing * 0.3, y: neck.y + 20)
            return (SMath.mix(walkHand, runHand, run), SMath.mix(walkElbow, runElbow, run))
        }

        let leftFoot = footPoint(left)
        let rightFoot = footPoint(right)
        let leftArm = arm(oppositeOf: left.offset)
        let rightArm = arm(oppositeOf: right.offset)
        return StickPose(
            head: head, neck: neck, hip: CGPoint(x: hipX, y: hipY),
            leftElbow: leftArm.elbow, leftHand: leftArm.hand,
            rightElbow: rightArm.elbow, rightHand: rightArm.hand,
            leftKnee: kneeHint(leftFoot), leftFoot: leftFoot,
            rightKnee: kneeHint(rightFoot), rightFoot: rightFoot,
            headTilt: 0.06 * run, bodyLean: lean
        )
    }

    private func crouchPose() -> StickPose {
        var progress: CGFloat = 1
        if case .crouching(let value) = motion { progress = value }
        let p = SMath.easeOutCubic(progress)
        let depth = 15 * p
        return StickPose(
            head: CGPoint(x: 81 + 4 * p, y: 26 + depth + 2 * p),
            neck: CGPoint(x: 80 + 3 * p, y: 48 + depth + 2 * p),
            hip: CGPoint(x: 79, y: 92 + depth),
            leftElbow: CGPoint(x: 64 - 4 * p, y: 69 + depth), leftHand: CGPoint(x: 60 - 12 * p, y: 92 + depth * 0.4),
            rightElbow: CGPoint(x: 92 - 10 * p, y: 69 + depth), rightHand: CGPoint(x: 98 - 26 * p, y: 92 + depth * 0.5),
            leftKnee: CGPoint(x: 64, y: 122), leftFoot: CGPoint(x: 60, y: 145),
            rightKnee: CGPoint(x: 98, y: 122), rightFoot: CGPoint(x: 100, y: 145),
            headTilt: 0.12 * p, bodyLean: 0.16 * p
        )
    }

    private func airbornePose() -> StickPose {
        var velocity = CGVector.zero
        var planned = true
        if case .airborne(let v, let isPlanned) = motion {
            velocity = v
            planned = isPlanned
        }
        let rising = SMath.smoothstep(-380, 380, velocity.dy)
        let leap = SMath.smoothstep(90, 240, abs(velocity.dx))
        let flail = planned ? 0 : SMath.smoothstep(-650, -1250, velocity.dy)

        let tuck = StickPose(
            head: CGPoint(x: 80, y: 24), neck: CGPoint(x: 80, y: 46), hip: CGPoint(x: 80, y: 88),
            leftElbow: CGPoint(x: 60, y: 30), leftHand: CGPoint(x: 50, y: 4),
            rightElbow: CGPoint(x: 100, y: 28), rightHand: CGPoint(x: 110, y: 2),
            leftKnee: CGPoint(x: 64, y: 106), leftFoot: CGPoint(x: 72, y: 128),
            rightKnee: CGPoint(x: 99, y: 104), rightFoot: CGPoint(x: 90, y: 126)
        )
        let stride = StickPose(
            head: CGPoint(x: 85, y: 26), neck: CGPoint(x: 82, y: 48), hip: CGPoint(x: 79, y: 90),
            leftElbow: CGPoint(x: 64, y: 62), leftHand: CGPoint(x: 52, y: 78),
            rightElbow: CGPoint(x: 98, y: 54), rightHand: CGPoint(x: 110, y: 44),
            leftKnee: CGPoint(x: 70, y: 118), leftFoot: CGPoint(x: 50, y: 132),
            rightKnee: CGPoint(x: 102, y: 102), rightFoot: CGPoint(x: 106, y: 128),
            headTilt: 0.08, bodyLean: 0.12
        )
        let reach = StickPose(
            head: CGPoint(x: 80, y: 26), neck: CGPoint(x: 80, y: 48), hip: CGPoint(x: 80, y: 92),
            leftElbow: CGPoint(x: 62, y: 52), leftHand: CGPoint(x: 45, y: 56),
            rightElbow: CGPoint(x: 98, y: 52), rightHand: CGPoint(x: 115, y: 56),
            leftKnee: CGPoint(x: 68, y: 118), leftFoot: CGPoint(x: 66, y: 144),
            rightKnee: CGPoint(x: 94, y: 118), rightFoot: CGPoint(x: 95, y: 143)
        )
        var pose = reach.blended(toward: tuck.blended(toward: stride, amount: leap), amount: rising)
        if flail > 0 {
            let wave = CGFloat(time * 14)
            let pedal = CGFloat(time * 12)
            let flailing = StickPose(
                head: CGPoint(x: 80, y: 26), neck: CGPoint(x: 80, y: 48), hip: CGPoint(x: 80, y: 91),
                leftElbow: CGPoint(x: 58, y: 34), leftHand: CGPoint(x: 46 + sin(wave) * 10, y: 8 + cos(wave) * 6),
                rightElbow: CGPoint(x: 102, y: 32), rightHand: CGPoint(x: 114 - sin(wave + 1) * 10, y: 6 + cos(wave + 1) * 6),
                leftKnee: CGPoint(x: 62, y: 112), leftFoot: CGPoint(x: 70 + sin(pedal) * 10, y: 134 + cos(pedal) * 7),
                rightKnee: CGPoint(x: 98, y: 112), rightFoot: CGPoint(x: 90 - sin(pedal) * 10, y: 134 - cos(pedal) * 7)
            )
            pose = pose.blended(toward: flailing, amount: flail)
        }
        return pose
    }

    private func landingPose() -> StickPose {
        let progress = CGFloat((time - landingStartedAt) / max(0.01, landingDuration))
        if landingImpact > 1500 {
            // Superhero landing: one knee down, a fist on the ground, then stand up.
            let kneel = StickPose(
                head: CGPoint(x: 116, y: 84), neck: CGPoint(x: 104, y: 98), hip: CGPoint(x: 74, y: 125),
                leftElbow: CGPoint(x: 78, y: 86), leftHand: CGPoint(x: 52, y: 84),
                rightElbow: CGPoint(x: 116, y: 120), rightHand: CGPoint(x: 110, y: 145),
                leftKnee: CGPoint(x: 60, y: 150), leftFoot: CGPoint(x: 44, y: 145),
                rightKnee: CGPoint(x: 96, y: 108), rightFoot: CGPoint(x: 102, y: 145)
            )
            let recover = SMath.smoothstep(0.55, 1, progress)
            return kneel.blended(toward: idlePose(), amount: recover)
        }
        let depth = min(24, 6 + landingImpact * 0.012) * (1 - SMath.easeOutCubic(progress))
        return StickPose(
            head: CGPoint(x: 80 + depth * 0.25, y: 26 + depth * 1.08),
            neck: CGPoint(x: 80 + depth * 0.15, y: 48 + depth * 1.05),
            hip: CGPoint(x: 80, y: 92 + depth),
            leftElbow: CGPoint(x: 62, y: 66 + depth), leftHand: CGPoint(x: 52 - depth * 0.4, y: 86 + depth * 0.6),
            rightElbow: CGPoint(x: 98, y: 66 + depth), rightHand: CGPoint(x: 108 + depth * 0.4, y: 86 + depth * 0.6),
            leftKnee: CGPoint(x: 62, y: 121), leftFoot: CGPoint(x: 58, y: 145),
            rightKnee: CGPoint(x: 98, y: 121), rightFoot: CGPoint(x: 102, y: 145),
            headTilt: 0.1 * depth / 24, bodyLean: 0.12 * depth / 24
        )
    }

    private func heldPose() -> StickPose {
        let kick = CGFloat(sin(time * 9.5))
        let fidgetArms = CGFloat(sin(time * 4.2))
        return StickPose(
            head: CGPoint(x: 80, y: 22), neck: CGPoint(x: 80, y: 44), hip: CGPoint(x: 80, y: 88),
            leftElbow: CGPoint(x: 64, y: 64), leftHand: CGPoint(x: 66 + fidgetArms * 2, y: 86 + kick * 1.5),
            rightElbow: CGPoint(x: 97, y: 63), rightHand: CGPoint(x: 94 - fidgetArms * 2, y: 85 - kick * 1.5),
            leftKnee: CGPoint(x: 72, y: 114), leftFoot: CGPoint(x: 73 + kick * 3, y: 140 - max(0, kick) * 6),
            rightKnee: CGPoint(x: 92, y: 114), rightFoot: CGPoint(x: 88 - kick * 3, y: 140 - max(0, -kick) * 6),
            hangSwing: swingAngle
        )
    }

    private func sittingPose() -> StickPose {
        let breath = CGFloat(sin(time * 1.45)) * 0.6
        return StickPose(
            head: CGPoint(x: 79, y: 60 + breath), neck: CGPoint(x: 80, y: 82 + breath), hip: CGPoint(x: 80, y: 126),
            leftElbow: CGPoint(x: 58, y: 104), leftHand: CGPoint(x: 50, y: 132),
            rightElbow: CGPoint(x: 102, y: 104), rightHand: CGPoint(x: 110, y: 132),
            leftKnee: CGPoint(x: 50, y: 136), leftFoot: CGPoint(x: 86, y: 143),
            rightKnee: CGPoint(x: 110, y: 136), rightFoot: CGPoint(x: 74, y: 143),
            headTilt: -0.04
        )
    }

    private func sleepingPose() -> StickPose {
        let breath = CGFloat(sin(time * 1.1))
        return StickPose(
            head: CGPoint(x: 92, y: 72 + breath * 1.2), neck: CGPoint(x: 82, y: 84 + breath * 0.8), hip: CGPoint(x: 80, y: 127),
            leftElbow: CGPoint(x: 60, y: 108), leftHand: CGPoint(x: 56, y: 134),
            rightElbow: CGPoint(x: 100, y: 108), rightHand: CGPoint(x: 104, y: 134),
            leftKnee: CGPoint(x: 50, y: 136), leftFoot: CGPoint(x: 86, y: 143),
            rightKnee: CGPoint(x: 110, y: 136), rightFoot: CGPoint(x: 74, y: 143),
            headTilt: 0.9, bodyLean: 0.12
        )
    }

    private func fidgetPose(_ fidget: StickmanFidget) -> StickPose {
        let elapsed = time - fidgetStartedAt
        let progress = CGFloat(elapsed / fidget.duration)
        let envelope = SMath.smoothstep(0, 0.18, progress) * (1 - SMath.smoothstep(0.82, 1, progress))
        let base = idlePose()
        switch fidget {
        case .stretch:
            let reach = SMath.smoothstep(0.05, 0.38, progress) * (1 - SMath.smoothstep(0.72, 0.98, progress))
            let bend = CGFloat(sin(Double(progress) * .pi * 2)) * SMath.smoothstep(0.35, 0.5, progress) * (1 - SMath.smoothstep(0.62, 0.75, progress))
            let stretch = StickPose(
                head: CGPoint(x: 80, y: 23), neck: CGPoint(x: 80, y: 45), hip: CGPoint(x: 80, y: 89),
                leftElbow: CGPoint(x: 64, y: 22), leftHand: CGPoint(x: 75, y: 2),
                rightElbow: CGPoint(x: 96, y: 22), rightHand: CGPoint(x: 85, y: 2),
                leftKnee: CGPoint(x: 68, y: 118), leftFoot: CGPoint(x: 62, y: 145),
                rightKnee: CGPoint(x: 92, y: 118), rightFoot: CGPoint(x: 98, y: 145),
                headTilt: -0.12, bodyLean: bend * 0.12
            )
            return base.blended(toward: stretch, amount: reach)
        case .tapFoot:
            let tap = max(0, CGFloat(sin(elapsed * 15)))
            let impatient = StickPose(
                head: CGPoint(x: 80 + CGFloat(sin(elapsed * 2.6)) * 1.5, y: 26), neck: CGPoint(x: 80, y: 48), hip: CGPoint(x: 79, y: 92),
                leftElbow: CGPoint(x: 56, y: 70), leftHand: CGPoint(x: 70, y: 88),
                rightElbow: CGPoint(x: 104, y: 70), rightHand: CGPoint(x: 90, y: 88),
                leftKnee: CGPoint(x: 67, y: 119), leftFoot: CGPoint(x: 60, y: 145),
                rightKnee: CGPoint(x: 96, y: 117), rightFoot: CGPoint(x: 103, y: 145 - tap * 5),
                headTilt: CGFloat(sin(elapsed * 2.6)) * 0.08
            )
            return base.blended(toward: impatient, amount: envelope)
        case .lookAround:
            let glance = CGFloat(sin(Double(progress) * .pi * 2))
            let shading = SMath.smoothstep(0.15, 0.3, progress) * (1 - SMath.smoothstep(0.85, 0.95, progress))
            var look = base
            look.head.x += 3 + glance * 2
            look.headTilt = 0.1 + glance * 0.06
            look.rightElbow = CGPoint(x: 100, y: 42)
            look.rightHand = CGPoint(x: 90, y: 22)
            look.bodyLean = 0.04
            return base.blended(toward: look, amount: shading)
        case .wave:
            let wave = CGFloat(sin(elapsed * 15))
            let waving = StickPose(
                head: CGPoint(x: 79, y: 25), neck: CGPoint(x: 80, y: 48), hip: CGPoint(x: 80, y: 92),
                leftElbow: CGPoint(x: 64, y: 69), leftHand: CGPoint(x: 59, y: 92),
                rightElbow: CGPoint(x: 101, y: 46), rightHand: CGPoint(x: 108 + wave * 7, y: 22 - abs(wave) * 2),
                leftKnee: CGPoint(x: 67, y: 119), leftFoot: CGPoint(x: 59, y: 145),
                rightKnee: CGPoint(x: 93, y: 119), rightFoot: CGPoint(x: 102, y: 145),
                headTilt: -0.08, bodyLean: -0.03
            )
            return base.blended(toward: waving, amount: envelope)
        }
    }

    private func listeningPose() -> StickPose {
        let pulse = CGFloat(sin(time * 3.4))
        return StickPose(
            head: CGPoint(x: 78, y: 24 + pulse), neck: CGPoint(x: 80, y: 47), hip: CGPoint(x: 81, y: 92),
            leftElbow: CGPoint(x: 62, y: 67), leftHand: CGPoint(x: 55, y: 88),
            rightElbow: CGPoint(x: 99, y: 62), rightHand: CGPoint(x: 103, y: 40),
            leftKnee: CGPoint(x: 68, y: 119), leftFoot: CGPoint(x: 58, y: 145),
            rightKnee: CGPoint(x: 93, y: 118), rightFoot: CGPoint(x: 103, y: 145),
            headTilt: -0.1
        )
    }

    private func thinkingPose() -> StickPose {
        let tap = CGFloat(sin(time * 2.2))
        return StickPose(
            head: CGPoint(x: 76, y: 27), neck: CGPoint(x: 79, y: 49), hip: CGPoint(x: 82, y: 93),
            leftElbow: CGPoint(x: 61, y: 73), leftHand: CGPoint(x: 64, y: 96),
            rightElbow: CGPoint(x: 100, y: 69), rightHand: CGPoint(x: 90, y: 47 + tap),
            leftKnee: CGPoint(x: 68, y: 119), leftFoot: CGPoint(x: 58, y: 145),
            rightKnee: CGPoint(x: 94, y: 120), rightFoot: CGPoint(x: 103, y: 145),
            headTilt: -0.11, bodyLean: 0.045
        )
    }

    private func happyPose() -> StickPose {
        let energy = CGFloat(sin(time * 12)) * 2
        return StickPose(
            head: CGPoint(x: 80, y: 24 + energy), neck: CGPoint(x: 80, y: 47 + energy * 0.5), hip: CGPoint(x: 80, y: 90 + energy * 0.5),
            leftElbow: CGPoint(x: 58, y: 57), leftHand: CGPoint(x: 45, y: 32),
            rightElbow: CGPoint(x: 102, y: 57), rightHand: CGPoint(x: 115, y: 32),
            leftKnee: CGPoint(x: 66, y: 118), leftFoot: CGPoint(x: 58, y: 145),
            rightKnee: CGPoint(x: 94, y: 118), rightFoot: CGPoint(x: 102, y: 145)
        )
    }

    private func speakingPose() -> StickPose {
        let gesture = CGFloat(sin(time * 5.3))
        return StickPose(
            head: CGPoint(x: 80, y: 26), neck: CGPoint(x: 80, y: 49), hip: CGPoint(x: 80, y: 92),
            leftElbow: CGPoint(x: 62, y: 68), leftHand: CGPoint(x: 52 - gesture * 5, y: 78 - gesture * 6),
            rightElbow: CGPoint(x: 99, y: 65), rightHand: CGPoint(x: 110 + gesture * 6, y: 58 + gesture * 8),
            leftKnee: CGPoint(x: 67, y: 119), leftFoot: CGPoint(x: 59, y: 145),
            rightKnee: CGPoint(x: 93, y: 119), rightFoot: CGPoint(x: 102, y: 145),
            headTilt: gesture * 0.05
        )
    }

    private func workingPose() -> StickPose {
        let tap = CGFloat(sin(time * 13)) * 4
        return StickPose(
            head: CGPoint(x: 81, y: 28), neck: CGPoint(x: 80, y: 50), hip: CGPoint(x: 78, y: 93),
            leftElbow: CGPoint(x: 61, y: 68), leftHand: CGPoint(x: 72 + tap, y: 83),
            rightElbow: CGPoint(x: 99, y: 68), rightHand: CGPoint(x: 89 - tap, y: 83),
            leftKnee: CGPoint(x: 67, y: 120), leftFoot: CGPoint(x: 58, y: 145),
            rightKnee: CGPoint(x: 93, y: 120), rightFoot: CGPoint(x: 102, y: 145),
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
            leftElbow: CGPoint(x: 63, y: 68), leftHand: CGPoint(x: 58, y: 91),
            rightElbow: CGPoint(x: 99 + energy * 3, y: 56 - energy * 7),
            rightHand: CGPoint(x: 112 + wave * 7, y: 35 + wave * 2),
            leftKnee: CGPoint(x: 67, y: 119), leftFoot: CGPoint(x: 58, y: 145),
            rightKnee: CGPoint(x: 93, y: 119), rightFoot: CGPoint(x: 103, y: 145),
            headTilt: -0.07 * energy, bodyLean: -0.04 * energy
        )
    }

    private func browserWandPose() -> StickPose {
        let progress = taskProgress(duration: 1.4)
        let energy = CGFloat(sin(progress * .pi))
        let flick = CGFloat(sin(min(1, progress * 1.35) * .pi)) * energy
        return StickPose(
            head: CGPoint(x: 79, y: 26 - energy), neck: CGPoint(x: 80, y: 49), hip: CGPoint(x: 78, y: 92),
            leftElbow: CGPoint(x: 62, y: 69), leftHand: CGPoint(x: 56, y: 91),
            rightElbow: CGPoint(x: 100 + energy * 3, y: 64 - energy * 4),
            rightHand: CGPoint(x: 116 + flick * 7, y: 52 - flick * 11),
            leftKnee: CGPoint(x: 67, y: 119), leftFoot: CGPoint(x: 58, y: 145),
            rightKnee: CGPoint(x: 92, y: 119), rightFoot: CGPoint(x: 103, y: 145),
            headTilt: 0.06 * energy, bodyLean: 0.07 * energy
        )
    }

    private func calendarPeekPose() -> StickPose {
        let progress = taskProgress(duration: 1.35)
        let energy = CGFloat(sin(progress * .pi))
        return StickPose(
            head: CGPoint(x: 76, y: 27 - energy * 2), neck: CGPoint(x: 79, y: 49), hip: CGPoint(x: 81, y: 93),
            leftElbow: CGPoint(x: 61, y: 66), leftHand: CGPoint(x: 52, y: 62 - energy * 5),
            rightElbow: CGPoint(x: 99, y: 65), rightHand: CGPoint(x: 111 + energy * 4, y: 55 - energy * 4),
            leftKnee: CGPoint(x: 67, y: 119), leftFoot: CGPoint(x: 58, y: 145),
            rightKnee: CGPoint(x: 93, y: 119), rightFoot: CGPoint(x: 103, y: 145),
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
            leftKnee: CGPoint(x: 67, y: 119), leftFoot: CGPoint(x: 58, y: 145),
            rightKnee: CGPoint(x: 92, y: 119), rightFoot: CGPoint(x: 103, y: 145),
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
            leftKnee: CGPoint(x: 67, y: 119), leftFoot: CGPoint(x: 58, y: 145),
            rightKnee: CGPoint(x: 93, y: 119), rightFoot: CGPoint(x: 103, y: 145)
        )
    }

    private func errorPose() -> StickPose {
        let shake = CGFloat(sin(time * 34)) * 3
        return StickPose(
            head: CGPoint(x: 80 + shake, y: 28), neck: CGPoint(x: 80, y: 50), hip: CGPoint(x: 80, y: 94),
            leftElbow: CGPoint(x: 60, y: 62), leftHand: CGPoint(x: 49, y: 50),
            rightElbow: CGPoint(x: 100, y: 62), rightHand: CGPoint(x: 111, y: 50),
            leftKnee: CGPoint(x: 66, y: 120), leftFoot: CGPoint(x: 56, y: 145),
            rightKnee: CGPoint(x: 94, y: 120), rightFoot: CGPoint(x: 104, y: 145)
        )
    }

    private func combatPose() -> StickPose {
        let bounce = CGFloat(sin(time * 7.8)) * 2.2
        // Boxer's stance: staggered feet, bent knees, lead fist out front, rear fist at the chin.
        var guardPose = StickPose(
            head: CGPoint(x: 86, y: 31 + bounce), neck: CGPoint(x: 82, y: 53 + bounce), hip: CGPoint(x: 76, y: 99 + bounce * 0.6),
            leftElbow: CGPoint(x: 68, y: 70 + bounce), leftHand: CGPoint(x: 92, y: 56 + bounce),
            rightElbow: CGPoint(x: 100, y: 68 + bounce), rightHand: CGPoint(x: 112, y: 52 + bounce),
            leftKnee: CGPoint(x: 58, y: 121), leftFoot: CGPoint(x: 46, y: 145),
            rightKnee: CGPoint(x: 101, y: 119), rightFoot: CGPoint(x: 110, y: 145),
            headTilt: 0.1, bodyLean: 0.12
        )

        let elapsed = max(0, time - combatMoveStartedAt)
        let phase = CGFloat(min(1, elapsed / max(0.01, combatMoveEndsAt - combatMoveStartedAt)))
        let strike = sin(phase * .pi)
        switch combatMove {
        case .guardStance:
            return guardPose
        case .dodge(let direction):
            return guardPose.offsetBy(dx: direction * strike * 14, dy: 0)
        case .jab:
            guardPose.head.x -= strike * 5
            guardPose.neck.x += strike * 7
            guardPose.hip.x += strike * 2
            guardPose.rightElbow = CGPoint(x: 104 + strike * 16, y: 62 - strike * 8)
            guardPose.rightHand = CGPoint(x: 112 + strike * 38, y: 52 - strike * 2)
            return guardPose
        case .kick:
            guardPose.neck.x -= strike * 6
            guardPose.hip.x -= strike * 2
            guardPose.rightKnee = CGPoint(x: 98 + strike * 12, y: 102 - strike * 14)
            guardPose.rightFoot = CGPoint(x: 111 + strike * 32, y: 140 - strike * 52)
            guardPose.leftFoot = CGPoint(x: 52, y: 145)
            guardPose.bodyLean = 0.1 - strike * 0.25
            return guardPose
        case .lasso:
            guardPose.rightElbow = CGPoint(x: 104, y: 48 - strike * 12)
            guardPose.rightHand = CGPoint(x: 120 + strike * 14, y: 35 + sin(phase * .pi * 2) * 16)
            return guardPose
        case .groundSlam:
            guardPose.head.y += strike * 22
            guardPose.neck.y += strike * 24
            guardPose.hip.y += strike * 22
            guardPose.leftHand = CGPoint(x: 54, y: 120 + strike * 24)
            guardPose.rightHand = CGPoint(x: 105, y: 120 + strike * 24)
            return guardPose
        case .hit(let direction):
            var hit = guardPose.offsetBy(dx: direction.dx * strike * 10, dy: 0)
            hit.leftFoot = guardPose.leftFoot
            hit.rightFoot = guardPose.rightFoot
            hit.bodyLean -= direction.dx * strike * 0.3
            hit.headTilt -= direction.dx * strike * 0.4
            return hit
        case .victory:
            return happyPose()
        }
    }

    private func taskProgress(duration: TimeInterval) -> CGFloat {
        let elapsed = max(0, time - taskAnimationStartedAt)
        return CGFloat(max(0, min(1, elapsed / duration)))
    }

    // MARK: Solving

    private static func solve(_ pose: StickPose) -> Skeleton {
        let leaned = leanApplied(pose)

        // Torso and head keep their length; the authored direction is kept.
        let hip = leaned.hip
        let neck = point(from: hip, toward: leaned.neck, length: Bone.torso)
        let neckShift = CGPoint(x: neck.x - leaned.neck.x, y: neck.y - leaned.neck.y)
        let headTarget = CGPoint(x: leaned.head.x + neckShift.x, y: leaned.head.y + neckShift.y)
        let headDirection = rotate(unit(from: neck, to: headTarget, fallback: CGPoint(x: 0, y: -1)), by: pose.headTilt * 0.6)
        let head = CGPoint(x: neck.x + headDirection.x * Bone.neck, y: neck.y + headDirection.y * Bone.neck)

        func shifted(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + neckShift.x, y: point.y + neckShift.y) }

        let leftArm = twoBone(root: neck, target: shifted(leaned.leftHand), hint: shifted(leaned.leftElbow), upper: Bone.upperArm, lower: Bone.forearm, outward: -1)
        let rightArm = twoBone(root: neck, target: shifted(leaned.rightHand), hint: shifted(leaned.rightElbow), upper: Bone.upperArm, lower: Bone.forearm, outward: 1)
        let leftLeg = twoBone(root: hip, target: leaned.leftFoot, hint: leaned.leftKnee, upper: Bone.thigh, lower: Bone.shin, outward: -1)
        let rightLeg = twoBone(root: hip, target: leaned.rightFoot, hint: leaned.rightKnee, upper: Bone.thigh, lower: Bone.shin, outward: 1)

        var skeleton = Skeleton(
            head: head, neck: neck, hip: hip,
            leftElbow: leftArm.joint, leftHand: leftArm.end,
            rightElbow: rightArm.joint, rightHand: rightArm.end,
            leftKnee: leftLeg.joint, leftFoot: leftLeg.end,
            rightKnee: rightLeg.joint, rightFoot: rightLeg.end
        )

        if abs(pose.hangSwing) > 0.0001 {
            let pivot = skeleton.head
            func swing(_ p: CGPoint) -> CGPoint { rotate(p, around: pivot, by: pose.hangSwing) }
            skeleton = Skeleton(
                head: pivot, neck: swing(skeleton.neck), hip: swing(skeleton.hip),
                leftElbow: swing(skeleton.leftElbow), leftHand: swing(skeleton.leftHand),
                rightElbow: swing(skeleton.rightElbow), rightHand: swing(skeleton.rightHand),
                leftKnee: swing(skeleton.leftKnee), leftFoot: swing(skeleton.leftFoot),
                rightKnee: swing(skeleton.rightKnee), rightFoot: swing(skeleton.rightFoot)
            )
        }
        return skeleton
    }

    /// Leaning rotates the upper body around the hip; legs stay planted.
    private static func leanApplied(_ pose: StickPose) -> StickPose {
        guard abs(pose.bodyLean) > 0.0001 else { return pose }
        var copy = pose
        for keyPath in [\StickPose.head, \.neck, \.leftElbow, \.leftHand, \.rightElbow, \.rightHand] {
            copy[keyPath: keyPath] = rotate(pose[keyPath: keyPath], around: pose.hip, by: pose.bodyLean)
        }
        return copy
    }

    /// Two-bone inverse kinematics. The joint bends toward the side of `hint`; when the hint
    /// sits on the bone line, it bends away from the body (`outward` is -1 for left limbs).
    private static func twoBone(
        root: CGPoint,
        target: CGPoint,
        hint: CGPoint,
        upper: CGFloat,
        lower: CGFloat,
        outward: CGFloat
    ) -> (joint: CGPoint, end: CGPoint) {
        var dx = target.x - root.x
        var dy = target.y - root.y
        var distance = hypot(dx, dy)
        if distance < 0.0001 {
            dx = 0
            dy = 1
            distance = 1
        }
        let ux = dx / distance
        let uy = dy / distance
        let reach = min(max(distance, abs(upper - lower) + 0.5), (upper + lower) * 0.999)
        let end = CGPoint(x: root.x + ux * reach, y: root.y + uy * reach)
        let cosine = (upper * upper + reach * reach - lower * lower) / (2 * upper * reach)
        let angle = acos(min(1, max(-1, cosine)))
        let cross = dx * (hint.y - root.y) - dy * (hint.x - root.x)
        let hintIsOnLine = abs(cross) / distance <= 2.5
        // A positive turn moves the joint toward -x on a downward limb and +x on a raised one.
        let side: CGFloat = hintIsOnLine ? outward * (uy >= 0 ? -1 : 1) : (cross > 0 ? 1 : -1)
        let c = cos(angle)
        let s = sin(angle) * side
        var joint = CGPoint(x: root.x + (ux * c - uy * s) * upper, y: root.y + (ux * s + uy * c) * upper)
        if hintIsOnLine {
            // Front-facing limbs read as straight when nearly extended (the bend points at the viewer).
            let straightness = SMath.smoothstep(0.86, 0.995, reach / (upper + lower))
            let straight = CGPoint(x: root.x + ux * reach * upper / (upper + lower), y: root.y + uy * reach * upper / (upper + lower))
            joint = SMath.mix(joint, straight, straightness)
        }
        return (joint, end)
    }

    private static func point(from origin: CGPoint, toward target: CGPoint, length: CGFloat) -> CGPoint {
        let direction = unit(from: origin, to: target, fallback: CGPoint(x: 0, y: -1))
        return CGPoint(x: origin.x + direction.x * length, y: origin.y + direction.y * length)
    }

    private static func unit(from origin: CGPoint, to target: CGPoint, fallback: CGPoint) -> CGPoint {
        let dx = target.x - origin.x
        let dy = target.y - origin.y
        let length = hypot(dx, dy)
        guard length > 0.0001 else { return fallback }
        return CGPoint(x: dx / length, y: dy / length)
    }

    private static func rotate(_ vector: CGPoint, by angle: CGFloat) -> CGPoint {
        CGPoint(x: vector.x * cos(angle) - vector.y * sin(angle), y: vector.x * sin(angle) + vector.y * cos(angle))
    }

    private static func rotate(_ point: CGPoint, around pivot: CGPoint, by angle: CGFloat) -> CGPoint {
        let offset = rotate(CGPoint(x: point.x - pivot.x, y: point.y - pivot.y), by: angle)
        return CGPoint(x: pivot.x + offset.x, y: pivot.y + offset.y)
    }

    // MARK: Task props

    private func drawTaskEffects(context: CGContext) {
        guard let taskAnimation else { return }
        let joints = skeleton
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch taskAnimation {
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
            let tabRect = CGRect(x: 109, y: 17, width: 34 * tabProgress, height: 22 * tabProgress)
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

            for angleIndex in 0 ..< 4 {
                let angle = CGFloat(angleIndex) * .pi / 2
                context.setStrokeColor(NSColor.black.withAlphaComponent(energy).cgColor)
                context.setLineWidth(1.7)
                context.move(to: CGPoint(x: tip.x + cos(angle) * 3, y: tip.y + sin(angle) * 3))
                context.addLine(to: CGPoint(x: tip.x + cos(angle) * 8, y: tip.y + sin(angle) * 8))
                context.strokePath()
            }

        case .checkCalendar:
            let progress = taskProgress(duration: 1.35)
            let energy = CGFloat(sin(progress * .pi))
            let rect = CGRect(x: 111, y: 29 - energy * 5, width: 34, height: 29)
            context.setFillColor(NSColor.white.withAlphaComponent(0.88 * energy).cgColor)
            context.fill(rect)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.86 * energy).cgColor)
            context.setFillColor(NSColor.black.withAlphaComponent(0.86 * energy).cgColor)
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
}
