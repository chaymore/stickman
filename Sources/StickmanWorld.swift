import AppKit
import CoreGraphics

/// Small math helpers shared by the locomotion model and the renderer.
enum SMath {
    static func clamp01(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }

    /// Hermite smoothstep. `edge0` may be greater than `edge1` for a falling ramp.
    static func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ value: CGFloat) -> CGFloat {
        guard edge0 != edge1 else { return value < edge0 ? 0 : 1 }
        let t = clamp01((value - edge0) / (edge1 - edge0))
        return t * t * (3 - 2 * t)
    }

    static func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    static func mix(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    static func easeOutCubic(_ t: CGFloat) -> CGFloat {
        let clamped = clamp01(t)
        return 1 - (1 - clamped) * (1 - clamped) * (1 - clamped)
    }

    static func approach(_ value: CGFloat, _ target: CGFloat, _ maxDelta: CGFloat) -> CGFloat {
        if value < target { return min(target, value + maxDelta) }
        return max(target, value - maxDelta)
    }
}

/// A horizontal ledge Stickman can stand on, in AppKit global screen coordinates.
struct StickmanSurface: Equatable {
    enum Kind: Hashable {
        case floor(screen: Int)
        case window(CGWindowID)
    }

    let kind: Kind
    var y: CGFloat
    var minX: CGFloat
    var maxX: CGFloat

    var isFloor: Bool {
        if case .floor = kind { return true }
        return false
    }

    func contains(x: CGFloat, margin: CGFloat = 0) -> Bool {
        x >= minX - margin && x <= maxX + margin
    }

    func clampedX(_ x: CGFloat, inset: CGFloat) -> CGFloat {
        let low = minX + inset
        let high = maxX - inset
        guard low <= high else { return (minX + maxX) / 2 }
        return min(max(x, low), high)
    }

    func distance(toX x: CGFloat) -> CGFloat {
        if x < minX { return minX - x }
        if x > maxX { return x - maxX }
        return 0
    }
}

struct StickmanWindowSnapshot: Equatable {
    let id: CGWindowID
    /// AppKit global coordinates.
    let frame: NSRect
}

/// Turns the on-screen window list into walkable ledges: every display's floor plus
/// the visible part of each normal window's top edge.
enum StickmanSurfaceMap {
    static let minimumLedgeWidth: CGFloat = 64
    static let cornerInset: CGFloat = 10
    static let occlusionMargin: CGFloat = 10

    /// - Parameters:
    ///   - windows: normal windows ordered front to back.
    ///   - screens: each display's visible frame (menu bar and Dock excluded).
    ///   - headroom: vertical space a ledge needs above it so Stickman fits under the menu bar.
    static func build(windows: [StickmanWindowSnapshot], screens: [NSRect], headroom: CGFloat) -> [StickmanSurface] {
        var surfaces = screens.enumerated().map { index, frame in
            StickmanSurface(kind: .floor(screen: index), y: frame.minY, minX: frame.minX, maxX: frame.maxX)
        }

        for (index, window) in windows.enumerated() {
            let top = window.frame.maxY
            guard let screen = screens.first(where: {
                $0.minX <= window.frame.midX && window.frame.midX <= $0.maxX
                    && top > $0.minY + 40 && top + headroom <= $0.maxY
            }) else { continue }

            let low = max(window.frame.minX + cornerInset, screen.minX)
            let high = min(window.frame.maxX - cornerInset, screen.maxX)
            guard high - low >= minimumLedgeWidth else { continue }

            // A window in front that crosses this top edge hides that stretch of it.
            var spans: [(CGFloat, CGFloat)] = [(low, high)]
            for front in windows[..<index] where front.frame.minY <= top + 1 && front.frame.maxY >= top - 1 {
                spans = subtract((front.frame.minX - occlusionMargin, front.frame.maxX + occlusionMargin), from: spans)
            }

            for span in spans where span.1 - span.0 >= minimumLedgeWidth {
                surfaces.append(StickmanSurface(kind: .window(window.id), y: top, minX: span.0, maxX: span.1))
            }
        }
        return surfaces
    }

    static func subtract(_ cut: (CGFloat, CGFloat), from spans: [(CGFloat, CGFloat)]) -> [(CGFloat, CGFloat)] {
        spans.flatMap { span -> [(CGFloat, CGFloat)] in
            guard cut.1 > span.0, cut.0 < span.1 else { return [span] }
            var pieces: [(CGFloat, CGFloat)] = []
            if cut.0 > span.0 { pieces.append((span.0, cut.0)) }
            if cut.1 < span.1 { pieces.append((cut.1, span.1)) }
            return pieces
        }
    }

    /// The highest ledge at or below `point`.
    static func support(at point: CGPoint, in surfaces: [StickmanSurface], tolerance: CGFloat = 1.5) -> StickmanSurface? {
        surfaces
            .filter { $0.contains(x: point.x) && $0.y <= point.y + tolerance }
            .max { $0.y < $1.y }
    }

    /// The highest ledge crossed while moving down from `previousY` to `newY`.
    static func landing(
        previousY: CGFloat,
        newY: CGFloat,
        x: CGFloat,
        in surfaces: [StickmanSurface],
        kind: StickmanSurface.Kind? = nil
    ) -> StickmanSurface? {
        surfaces
            .filter { surface in
                (kind == nil || surface.kind == kind)
                    && surface.contains(x: x)
                    && surface.y <= previousY + 0.5
                    && surface.y >= newY
            }
            .max { $0.y < $1.y }
    }

    static func segment(of kind: StickmanSurface.Kind, nearestTo x: CGFloat, in surfaces: [StickmanSurface]) -> StickmanSurface? {
        surfaces
            .filter { $0.kind == kind }
            .min { $0.distance(toX: x) < $1.distance(toX: x) }
    }

    /// Where a right-click sends Stickman: onto the clicked window if its top is usable,
    /// otherwise onto the ledge below the click.
    static func destination(
        for point: CGPoint,
        windows: [StickmanWindowSnapshot],
        surfaces: [StickmanSurface]
    ) -> StickmanSurface? {
        if let window = windows.first(where: { $0.frame.contains(point) }),
           let top = segment(of: .window(window.id), nearestTo: point.x, in: surfaces) {
            return top
        }
        if let below = support(at: point, in: surfaces) {
            return below
        }
        return surfaces.filter(\.isFloor).min { abs($0.y - point.y) < abs($1.y - point.y) }
    }
}

/// Ballistic jump that leaves `start` and lands on `end` under constant gravity.
struct StickmanJump: Equatable {
    let velocity: CGVector
    let duration: TimeInterval

    static func solve(from start: CGPoint, to end: CGPoint, gravity: CGFloat) -> StickmanJump {
        let dx = end.x - start.x
        let clearance = min(170, 34 + abs(dx) * 0.16)
        let apex = max(start.y, end.y) + clearance
        let rise = max(1, apex - start.y)
        let drop = max(1, apex - end.y)
        let launchSpeed = (2 * gravity * rise).squareRoot()
        let duration = launchSpeed / gravity + (2 * drop / gravity).squareRoot()
        return StickmanJump(velocity: CGVector(dx: dx / duration, dy: launchSpeed), duration: TimeInterval(duration))
    }
}

/// Stickman's body in screen space: walking along ledges, leaping between them,
/// falling under gravity, and being carried or thrown by the cursor.
/// `position` is the point between his feet, in AppKit global coordinates.
final class StickmanLocomotion {
    struct Tuning {
        var gravity: CGFloat = 2300
        var walkSpeed: CGFloat = 92
        var runSpeed: CGFloat = 245
        var runDistance: CGFloat = 380
        var acceleration: CGFloat = 640
        var braking: CGFloat = 900
        var edgeInset: CGFloat = 22
        var maxLeap: CGFloat = 440
        var bodyHeight: CGFloat = 96
        var maxThrowSpeed: CGFloat = 2600
    }

    enum State: Equatable {
        case grounded(StickmanSurface.Kind)
        case crouching(StickmanSurface.Kind, launch: CGVector, target: StickmanSurface.Kind?, started: TimeInterval, until: TimeInterval)
        case airborne(target: StickmanSurface.Kind?)
        case held
    }

    enum Event: Equatable {
        case landed(impact: CGFloat)
        case launched
        case startedFalling
        case arrived
    }

    struct Destination: Equatable {
        let kind: StickmanSurface.Kind
        var x: CGFloat
    }

    var tuning = Tuning()
    private(set) var position: CGPoint
    private(set) var velocity: CGVector = .zero
    private(set) var state: State = .airborne(target: nil)
    private(set) var destination: Destination?
    private(set) var surfaces: [StickmanSurface] = []
    private var screens: [NSRect] = []
    private var gaitSpeed: CGFloat = 92
    private var holdSamples: [(time: TimeInterval, point: CGPoint)] = []

    init(position: CGPoint) {
        self.position = position
    }

    var isGrounded: Bool {
        if case .grounded = state { return true }
        return false
    }

    var groundedKind: StickmanSurface.Kind? {
        if case .grounded(let kind) = state { return kind }
        return nil
    }

    var isBusy: Bool {
        if destination != nil { return true }
        switch state {
        case .grounded: return abs(velocity.dx) > 1
        case .crouching, .airborne, .held: return true
        }
    }

    // MARK: World

    func updateWorld(surfaces: [StickmanSurface], screens: [NSRect]) {
        self.surfaces = surfaces
        self.screens = screens
    }

    /// Moves Stickman (and any plan targeting the same window) along with a window that moved.
    func carry(window id: CGWindowID, by delta: CGVector) {
        guard delta.dx != 0 || delta.dy != 0 else { return }
        surfaces = surfaces.map { surface in
            guard surface.kind == .window(id) else { return surface }
            return StickmanSurface(kind: surface.kind, y: surface.y + delta.dy, minX: surface.minX + delta.dx, maxX: surface.maxX + delta.dx)
        }
        if groundedKind == .window(id) {
            position.x += delta.dx
            position.y += delta.dy
        }
        if destination?.kind == .window(id) {
            destination?.x += delta.dx
        }
    }

    // MARK: Commands

    func place(at point: CGPoint) {
        position = point
        velocity = .zero
        destination = nil
        state = .airborne(target: nil)
    }

    func go(to destination: Destination) {
        self.destination = destination
        let distance = abs(destination.x - position.x)
        gaitSpeed = distance > tuning.runDistance ? tuning.runSpeed : tuning.walkSpeed
    }

    func stop() {
        destination = nil
    }

    /// A small hop in place.
    func hop(height: CGFloat, now: TimeInterval) {
        guard case .grounded(let kind) = state else { return }
        let launch = CGVector(dx: 0, dy: (2 * tuning.gravity * height).squareRoot())
        state = .crouching(kind, launch: launch, target: kind, started: now, until: now + 0.1)
        velocity = .zero
    }

    /// Knockback or a shove. Leaves the ground.
    func impulse(_ delta: CGVector) {
        if case .held = state { return }
        destination = nil
        velocity.dx += delta.dx
        velocity.dy = max(velocity.dy, 0) + delta.dy
        state = .airborne(target: nil)
    }

    func beginHold(now: TimeInterval) {
        state = .held
        destination = nil
        velocity = .zero
        holdSamples = [(now, position)]
    }

    func hold(at point: CGPoint, now: TimeInterval) {
        guard case .held = state else { return }
        position = point
        holdSamples.append((now, point))
        holdSamples.removeAll { now - $0.time > 0.12 }
        if holdSamples.count >= 2, let first = holdSamples.first, let last = holdSamples.last, last.time > first.time {
            let elapsed = CGFloat(last.time - first.time)
            velocity = CGVector(dx: (last.point.x - first.point.x) / elapsed, dy: (last.point.y - first.point.y) / elapsed)
        }
    }

    func release(now: TimeInterval) {
        guard case .held = state else { return }
        // A cursor that paused before letting go drops Stickman instead of throwing him.
        let recent = holdSamples.filter { now - $0.time <= 0.08 }
        if recent.count >= 2, let first = recent.first, let last = recent.last, last.time > first.time {
            let elapsed = CGFloat(last.time - first.time)
            var throwVelocity = CGVector(dx: (last.point.x - first.point.x) / elapsed, dy: (last.point.y - first.point.y) / elapsed)
            let speed = hypot(throwVelocity.dx, throwVelocity.dy)
            if speed > tuning.maxThrowSpeed {
                throwVelocity.dx *= tuning.maxThrowSpeed / speed
                throwVelocity.dy *= tuning.maxThrowSpeed / speed
            }
            velocity = throwVelocity
        } else {
            velocity = .zero
        }
        holdSamples.removeAll()
        state = .airborne(target: nil)
    }

    // MARK: Simulation

    func step(dt: CGFloat, now: TimeInterval) -> [Event] {
        var events: [Event] = []
        switch state {
        case .held:
            break
        case .crouching(_, let launch, let target, _, let until):
            velocity = .zero
            if now >= until {
                velocity = launch
                state = .airborne(target: target)
                events.append(.launched)
            }
        case .grounded(let kind):
            stepGrounded(kind: kind, dt: dt, now: now, events: &events)
        case .airborne(let target):
            stepAirborne(target: target, dt: dt, events: &events)
        }
        return events
    }

    private func stepGrounded(kind: StickmanSurface.Kind, dt: CGFloat, now: TimeInterval, events: inout [Event]) {
        guard let ledge = surfaces.first(where: { $0.kind == kind && $0.contains(x: position.x, margin: 4) }) else {
            state = .airborne(target: nil)
            velocity = CGVector(dx: velocity.dx * 0.5, dy: 0)
            events.append(.startedFalling)
            return
        }
        position.y = ledge.y

        guard let destination else {
            velocity.dx = SMath.approach(velocity.dx, 0, tuning.braking * dt)
            position.x = ledge.clampedX(position.x + velocity.dx * dt, inset: 4)
            return
        }

        guard let target = StickmanSurfaceMap.segment(of: destination.kind, nearestTo: destination.x, in: surfaces) else {
            self.destination = nil
            return
        }

        let targetX = target.clampedX(destination.x, inset: tuning.edgeInset)
        if target == ledge {
            if move(toward: targetX, on: ledge, dt: dt) {
                self.destination = nil
                events.append(.arrived)
            }
            return
        }

        // A different ledge: leap once close enough, or from the end of this one.
        let dx = targetX - position.x
        let edgeX = ledge.clampedX(dx > 0 ? ledge.maxX : ledge.minX, inset: tuning.edgeInset)
        let atEdge = dx > 0 ? position.x >= edgeX - 2 : position.x <= edgeX + 2
        if abs(dx) <= tuning.maxLeap || atEdge {
            let jump = StickmanJump.solve(from: position, to: CGPoint(x: targetX, y: target.y), gravity: tuning.gravity)
            let windUp = 0.13 + min(0.17, Double(abs(target.y - position.y)) / 2400)
            state = .crouching(kind, launch: jump.velocity, target: target.kind, started: now, until: now + windUp)
            velocity = .zero
        } else {
            _ = move(toward: ledge.clampedX(targetX, inset: tuning.edgeInset), on: ledge, dt: dt)
        }
    }

    /// Walks with eased acceleration and braking. Returns true on arrival.
    private func move(toward x: CGFloat, on ledge: StickmanSurface, dt: CGFloat) -> Bool {
        let dx = x - position.x
        if abs(dx) < 0.8, abs(velocity.dx) < 30 {
            position.x = x
            velocity.dx = 0
            return true
        }
        let direction: CGFloat = dx > 0 ? 1 : -1
        let desired = direction * min(gaitSpeed, (2 * tuning.braking * abs(dx)).squareRoot())
        let slowing = desired * velocity.dx < 0 || abs(desired) < abs(velocity.dx)
        velocity.dx = SMath.approach(velocity.dx, desired, (slowing ? tuning.braking : tuning.acceleration) * dt)
        let previousX = position.x
        position.x += velocity.dx * dt

        if (x - position.x) * dx < 0 {
            position.x = x
            velocity.dx = 0
            return true
        }
        // Stop at the ledge's end, but never yank him inward if he already stands near it.
        let low = ledge.minX + tuning.edgeInset
        let high = ledge.maxX - tuning.edgeInset
        if velocity.dx > 0, position.x > high {
            position.x = max(previousX, high)
            velocity.dx = 0
        } else if velocity.dx < 0, position.x < low {
            position.x = min(previousX, low)
            velocity.dx = 0
        }
        return false
    }

    private func stepAirborne(target: StickmanSurface.Kind?, dt: CGFloat, events: inout [Event]) {
        velocity.dy -= tuning.gravity * dt
        velocity.dx *= max(0, 1 - 0.2 * dt)
        let previous = position
        position.x += velocity.dx * dt
        position.y += velocity.dy * dt

        if let screen = screen(nearestTo: position) {
            let margin: CGFloat = 30
            if position.x < screen.minX + margin {
                position.x = screen.minX + margin
                velocity.dx = abs(velocity.dx) * 0.35
            } else if position.x > screen.maxX - margin {
                position.x = screen.maxX - margin
                velocity.dx = -abs(velocity.dx) * 0.35
            }
            if position.y + tuning.bodyHeight > screen.maxY {
                position.y = screen.maxY - tuning.bodyHeight
                velocity.dy = min(0, -velocity.dy * 0.2)
            }
        }

        guard velocity.dy <= 0 else { return }

        var landing: StickmanSurface?
        var plannedTarget = target
        if let kind = target {
            landing = StickmanSurfaceMap.landing(previousY: previous.y, newY: position.y, x: position.x, in: surfaces, kind: kind)
            if landing == nil {
                let targetY = StickmanSurfaceMap.segment(of: kind, nearestTo: position.x, in: surfaces)?.y ?? .infinity
                if position.y < targetY - 4 || targetY == .infinity {
                    // The ledge moved or vanished mid-jump; fall onto whatever is below.
                    plannedTarget = nil
                    state = .airborne(target: nil)
                }
            }
        }
        if plannedTarget == nil {
            landing = StickmanSurfaceMap.landing(previousY: previous.y, newY: position.y, x: position.x, in: surfaces)
        }

        if let landing {
            let impact = -velocity.dy
            position.y = landing.y
            velocity = .zero
            state = .grounded(landing.kind)
            events.append(.landed(impact: impact))
            return
        }

        // Safety net for display changes: never fall out of the world.
        if let floor = lowestFloor(), position.y < floor.y - 240 {
            let screenFloor = surfaces.filter(\.isFloor).min { $0.distance(toX: position.x) < $1.distance(toX: position.x) } ?? floor
            position = CGPoint(x: screenFloor.clampedX(position.x, inset: tuning.edgeInset), y: screenFloor.y)
            velocity = .zero
            state = .grounded(screenFloor.kind)
            events.append(.landed(impact: 0))
        }
    }

    private func screen(nearestTo point: CGPoint) -> NSRect? {
        screens.first { $0.minX <= point.x && point.x <= $0.maxX }
            ?? screens.min { abs($0.midX - point.x) < abs($1.midX - point.x) }
    }

    private func lowestFloor() -> StickmanSurface? {
        surfaces.filter(\.isFloor).min { $0.y < $1.y }
    }
}
