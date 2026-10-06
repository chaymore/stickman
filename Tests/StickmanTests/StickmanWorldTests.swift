import Testing
import AppKit
@testable import Stickman

@Suite
struct StickmanWorldTests {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)

    private func simulate(_ body: StickmanLocomotion, seconds: Double, until stop: (StickmanLocomotion.Event) -> Bool = { _ in false }) -> [StickmanLocomotion.Event] {
        var events: [StickmanLocomotion.Event] = []
        var now: TimeInterval = 100
        let dt = 1.0 / 60.0
        for _ in 0 ..< Int(seconds / dt) {
            now += dt
            let stepEvents = body.step(dt: CGFloat(dt), now: now)
            events.append(contentsOf: stepEvents)
            if stepEvents.contains(where: stop) { break }
        }
        return events
    }

    @Test func surfacesIncludeFloorAndVisibleWindowTops() {
        let back = StickmanWindowSnapshot(id: 1, frame: NSRect(x: 100, y: 100, width: 600, height: 400))
        let front = StickmanWindowSnapshot(id: 2, frame: NSRect(x: 300, y: 50, width: 200, height: 600))
        let surfaces = StickmanSurfaceMap.build(windows: [front, back], screens: [screen], headroom: 100)

        #expect(surfaces.contains { $0.kind == .floor(screen: 0) && $0.y == 0 })
        let backLedges = surfaces.filter { $0.kind == .window(1) }
        // The front window splits the back window's top edge into two ledges.
        #expect(backLedges.count == 2)
        #expect(backLedges.allSatisfy { $0.y == 500 })
        #expect(backLedges.allSatisfy { $0.maxX <= 300 - StickmanSurfaceMap.occlusionMargin || $0.minX >= 500 + StickmanSurfaceMap.occlusionMargin })
    }

    @Test func windowTopsTooCloseToTheMenuBarAreSkipped() {
        let maximized = StickmanWindowSnapshot(id: 7, frame: NSRect(x: 0, y: 0, width: 1440, height: 860))
        let surfaces = StickmanSurfaceMap.build(windows: [maximized], screens: [screen], headroom: 100)
        #expect(!surfaces.contains { $0.kind == .window(7) })
    }

    @Test func jumpSolverLandsOnTarget() {
        let start = CGPoint(x: 200, y: 0)
        let end = CGPoint(x: 520, y: 380)
        let gravity: CGFloat = 2300
        let jump = StickmanJump.solve(from: start, to: end, gravity: gravity)
        let t = CGFloat(jump.duration)
        let x = start.x + jump.velocity.dx * t
        let y = start.y + jump.velocity.dy * t - 0.5 * gravity * t * t
        #expect(abs(x - end.x) < 0.5)
        #expect(abs(y - end.y) < 0.5)
    }

    @Test func droppedStickmanFallsAndLandsOnTheFloor() {
        let body = StickmanLocomotion(position: CGPoint(x: 700, y: 600))
        body.updateWorld(surfaces: StickmanSurfaceMap.build(windows: [], screens: [screen], headroom: 100), screens: [screen])
        let events = simulate(body, seconds: 2) { if case .landed = $0 { return true } else { return false } }

        #expect(body.groundedKind == .floor(screen: 0))
        #expect(body.position.y == 0)
        guard case .landed(let impact) = events.last else {
            Issue.record("Expected a landing event")
            return
        }
        #expect(impact > 1000)
    }

    @Test func walkingArrivesWithoutOvershooting() {
        let body = StickmanLocomotion(position: CGPoint(x: 200, y: 0))
        body.updateWorld(surfaces: StickmanSurfaceMap.build(windows: [], screens: [screen], headroom: 100), screens: [screen])
        _ = simulate(body, seconds: 0.2)
        body.go(to: .init(kind: .floor(screen: 0), x: 500))

        var maxX: CGFloat = 0
        var now: TimeInterval = 200
        var arrived = false
        for _ in 0 ..< 60 * 8 {
            now += 1.0 / 60.0
            if body.step(dt: 1.0 / 60.0, now: now).contains(.arrived) { arrived = true; break }
            maxX = max(maxX, body.position.x)
        }
        #expect(arrived)
        #expect(abs(body.position.x - 500) < 1)
        #expect(maxX <= 500.5)
        #expect(body.velocity.dx == 0)
    }

    @Test func leapsUpOntoAWindowTop() {
        let window = StickmanWindowSnapshot(id: 9, frame: NSRect(x: 500, y: 0, width: 500, height: 420))
        let body = StickmanLocomotion(position: CGPoint(x: 200, y: 0))
        body.updateWorld(surfaces: StickmanSurfaceMap.build(windows: [window], screens: [screen], headroom: 100), screens: [screen])
        _ = simulate(body, seconds: 0.2)
        body.go(to: .init(kind: .window(9), x: 760))

        let events = simulate(body, seconds: 10) { $0 == .arrived }
        #expect(events.contains(.launched))
        #expect(body.groundedKind == .window(9))
        #expect(body.position.y == 420)
        #expect(abs(body.position.x - 760) < 1)
    }

    @Test func fallsWhenTheLedgeDisappears() {
        let window = StickmanWindowSnapshot(id: 3, frame: NSRect(x: 400, y: 0, width: 500, height: 300))
        let body = StickmanLocomotion(position: CGPoint(x: 600, y: 320))
        body.updateWorld(surfaces: StickmanSurfaceMap.build(windows: [window], screens: [screen], headroom: 100), screens: [screen])
        _ = simulate(body, seconds: 1)
        #expect(body.groundedKind == .window(3))

        body.updateWorld(surfaces: StickmanSurfaceMap.build(windows: [], screens: [screen], headroom: 100), screens: [screen])
        let events = simulate(body, seconds: 2) { if case .landed = $0 { return true } else { return false } }
        #expect(events.contains(.startedFalling))
        #expect(body.groundedKind == .floor(screen: 0))
    }

    @Test func ridesAlongWithAMovingWindow() {
        let window = StickmanWindowSnapshot(id: 4, frame: NSRect(x: 400, y: 0, width: 500, height: 300))
        let body = StickmanLocomotion(position: CGPoint(x: 600, y: 300))
        body.updateWorld(surfaces: StickmanSurfaceMap.build(windows: [window], screens: [screen], headroom: 100), screens: [screen])
        _ = simulate(body, seconds: 0.5)
        #expect(body.groundedKind == .window(4))

        body.carry(window: 4, by: CGVector(dx: 120, dy: 40))
        _ = simulate(body, seconds: 0.2)
        #expect(body.groundedKind == .window(4))
        #expect(abs(body.position.x - 720) < 0.5)
        #expect(body.position.y == 340)
    }

    @Test func releasingAfterAFlickThrowsHim() {
        let body = StickmanLocomotion(position: CGPoint(x: 300, y: 0))
        body.updateWorld(surfaces: StickmanSurfaceMap.build(windows: [], screens: [screen], headroom: 100), screens: [screen])
        body.beginHold(now: 10)
        body.hold(at: CGPoint(x: 300, y: 200), now: 10.00)
        body.hold(at: CGPoint(x: 340, y: 230), now: 10.04)
        body.hold(at: CGPoint(x: 380, y: 260), now: 10.08)
        body.release(now: 10.09)

        #expect(body.velocity.dx > 800)
        #expect(body.velocity.dy > 500)
        _ = simulate(body, seconds: 3) { if case .landed = $0 { return true } else { return false } }
        #expect(body.isGrounded)
        #expect(body.position.x > 500)
    }

    @Test func pausedReleaseDropsInsteadOfThrowing() {
        let body = StickmanLocomotion(position: CGPoint(x: 300, y: 0))
        body.updateWorld(surfaces: StickmanSurfaceMap.build(windows: [], screens: [screen], headroom: 100), screens: [screen])
        body.beginHold(now: 10)
        body.hold(at: CGPoint(x: 360, y: 300), now: 10.05)
        body.release(now: 10.5)
        #expect(body.velocity == .zero)
    }

    @Test func clickedWindowBecomesTheDestination() {
        let window = StickmanWindowSnapshot(id: 5, frame: NSRect(x: 200, y: 100, width: 600, height: 400))
        let surfaces = StickmanSurfaceMap.build(windows: [window], screens: [screen], headroom: 100)
        let insideWindow = StickmanSurfaceMap.destination(for: CGPoint(x: 400, y: 250), windows: [window], surfaces: surfaces)
        #expect(insideWindow?.kind == .window(5))
        let onDesktop = StickmanSurfaceMap.destination(for: CGPoint(x: 1100, y: 600), windows: [window], surfaces: surfaces)
        #expect(onDesktop?.kind == .floor(screen: 0))
    }
}
