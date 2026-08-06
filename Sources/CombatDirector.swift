import AppKit
import CoreGraphics

protocol CombatDirectorDelegate: AnyObject {
    var combatCharacterFrame: NSRect? { get }
    func combatDirector(_ director: CombatDirector, perform move: StickmanCombatMove)
    func combatDirector(_ director: CombatDirector, applyWindowImpulse impulse: CGVector)
}

final class CombatDirector {
    weak var delegate: CombatDirectorDelegate?

    private var monitors: [Any] = []
    private var timer: Timer?
    private var lastCursorPoint = NSEvent.mouseLocation
    private var lastCursorAt = ProcessInfo.processInfo.systemUptime
    private var cursorVelocity = CGVector.zero
    private var nextAttackAt: TimeInterval = 0
    private var lastCollisionAt: TimeInterval = 0
    private var tugEndsAt: TimeInterval = 0
    private var tugTarget = CGPoint.zero
    private var orbitAngle: CGFloat?
    private var orbitAccumulation: CGFloat = 0
    private var orbitStartedAt: TimeInterval = 0

    init(delegate: CombatDirectorDelegate) {
        self.delegate = delegate
    }

    func start() {
        guard timer == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            DispatchQueue.main.async { self?.observe(event) }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.observe(event)
            return event
        }) {
            monitors.append(monitor)
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        scheduleNextAttack()
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        timer?.invalidate()
        timer = nil
    }

    func registerDirectStrike(at screenPoint: CGPoint) {
        guard StickmanModeController.shared.mode == .sparring else { return }
        landCursorHit(at: screenPoint, velocity: cursorVelocity)
    }

    private func observe(_ event: NSEvent) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let point = NSEvent.mouseLocation
        let elapsed = max(1.0 / 240.0, timestamp - lastCursorAt)
        cursorVelocity = CGVector(
            dx: (point.x - lastCursorPoint.x) / CGFloat(elapsed),
            dy: (point.y - lastCursorPoint.y) / CGFloat(elapsed)
        )
        lastCursorPoint = point
        lastCursorAt = timestamp

        guard let frame = delegate?.combatCharacterFrame else { return }
        let hitFrame = frame.insetBy(dx: -14, dy: -10)
        let speed = hypot(cursorVelocity.dx, cursorVelocity.dy)

        if StickmanModeController.shared.mode == .peaceful {
            return
        }

        updateTruceOrbit(point: point, center: CGPoint(x: frame.midX, y: frame.midY), timestamp: timestamp)
        if hitFrame.contains(point), speed > 680, timestamp - lastCollisionAt > 0.34 {
            landCursorHit(at: point, velocity: cursorVelocity)
        }
    }

    private func landCursorHit(at point: CGPoint, velocity: CGVector) {
        lastCollisionAt = ProcessInfo.processInfo.systemUptime
        let speed = max(1, hypot(velocity.dx, velocity.dy))
        let direction = CGVector(dx: velocity.dx / speed, dy: velocity.dy / speed)
        delegate?.combatDirector(self, perform: .hit(direction: direction))
        delegate?.combatDirector(self, applyWindowImpulse: CGVector(dx: direction.dx * 58, dy: direction.dy * 34))
        ScreenEffectsOverlayController.shared.showImpact(at: point, strength: min(1.5, speed / 1100))
    }

    private func tick() {
        guard StickmanModeController.shared.mode == .sparring,
              let frame = delegate?.combatCharacterFrame
        else { return }

        let timestamp = ProcessInfo.processInfo.systemUptime
        if timestamp >= nextAttackAt {
            performAttack(from: CGPoint(x: frame.midX, y: frame.midY), cursor: NSEvent.mouseLocation)
            scheduleNextAttack()
        }

        if timestamp < tugEndsAt {
            let cursor = NSEvent.mouseLocation
            let delta = CGVector(dx: tugTarget.x - cursor.x, dy: tugTarget.y - cursor.y)
            let distance = max(1, hypot(delta.dx, delta.dy))
            let pull = min(13, distance * 0.055)
            let target = CGPoint(x: cursor.x + delta.dx / distance * pull, y: cursor.y + delta.dy / distance * pull)
            warpCursor(toAppKitPoint: target)
            ScreenEffectsOverlayController.shared.showTether(
                from: CGPoint(x: frame.midX, y: frame.midY),
                to: target,
                duration: 0.09
            )
        }
    }

    private func performAttack(from stickman: CGPoint, cursor: CGPoint) {
        let distance = hypot(cursor.x - stickman.x, cursor.y - stickman.y)
        let roll = Int.random(in: 0 ..< 100)

        if distance < 230, roll < 34 {
            delegate?.combatDirector(self, perform: .jab)
            ScreenEffectsOverlayController.shared.showSlash(from: stickman, to: cursor)
            recoilCursor(awayFrom: stickman, cursor: cursor, distance: 34)
        } else if distance < 330, roll < 58 {
            delegate?.combatDirector(self, perform: .kick)
            ScreenEffectsOverlayController.shared.showSlash(from: stickman, to: cursor)
            recoilCursor(awayFrom: stickman, cursor: cursor, distance: 48)
        } else if roll < 78 {
            delegate?.combatDirector(self, perform: .lasso)
            tugTarget = stickman
            tugEndsAt = ProcessInfo.processInfo.systemUptime + 0.46
            ScreenEffectsOverlayController.shared.showTether(from: stickman, to: cursor, duration: 0.55)
        } else if roll < 93 {
            delegate?.combatDirector(self, perform: .groundSlam)
            ScreenEffectsOverlayController.shared.showImpact(at: stickman, strength: 1.35)
            recoilCursor(awayFrom: stickman, cursor: cursor, distance: min(62, max(20, 180 - distance * 0.25)))
        } else {
            let direction: CGFloat = cursor.x >= stickman.x ? -1 : 1
            delegate?.combatDirector(self, perform: .dodge(direction: direction))
            delegate?.combatDirector(self, applyWindowImpulse: CGVector(dx: direction * 78, dy: 22))
        }
    }

    private func recoilCursor(awayFrom origin: CGPoint, cursor: CGPoint, distance: CGFloat) {
        let delta = CGVector(dx: cursor.x - origin.x, dy: cursor.y - origin.y)
        let length = max(1, hypot(delta.dx, delta.dy))
        warpCursor(toAppKitPoint: CGPoint(
            x: cursor.x + delta.dx / length * distance,
            y: cursor.y + delta.dy / length * distance
        ))
    }

    private func warpCursor(toAppKitPoint point: CGPoint) {
        guard !NSScreen.screens.isEmpty else { return }
        let globalTop = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        let quartzPoint = CGPoint(x: point.x, y: globalTop - point.y)
        _ = CGWarpMouseCursorPosition(quartzPoint)
    }

    private func updateTruceOrbit(point: CGPoint, center: CGPoint, timestamp: TimeInterval) {
        let radius = hypot(point.x - center.x, point.y - center.y)
        guard radius > 55, radius < 190 else {
            orbitAngle = nil
            orbitAccumulation = 0
            return
        }

        let angle = atan2(point.y - center.y, point.x - center.x)
        if orbitAngle == nil {
            orbitAngle = angle
            orbitAccumulation = 0
            orbitStartedAt = timestamp
            return
        }

        var delta = angle - (orbitAngle ?? angle)
        if delta > .pi { delta -= .pi * 2 }
        if delta < -.pi { delta += .pi * 2 }
        if abs(delta) < 0.65 { orbitAccumulation += delta }
        orbitAngle = angle

        if timestamp - orbitStartedAt > 3.2 {
            orbitAccumulation = 0
            orbitStartedAt = timestamp
        } else if abs(orbitAccumulation) > .pi * 3.1 {
            orbitAccumulation = 0
            delegate?.combatDirector(self, perform: .victory)
            StickmanModeController.shared.setMode(.peaceful, reason: "cursor truce circle")
        }
    }

    private func scheduleNextAttack() {
        nextAttackAt = ProcessInfo.processInfo.systemUptime + Double.random(in: 1.45 ... 2.9)
    }
}
