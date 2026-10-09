import AppKit

final class ScreenEffectsOverlayController {
    static let shared = ScreenEffectsOverlayController()

    private var panels: [ScreenEffectsPanel] = []

    private init() {}

    func start() {
        rebuildPanels()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildPanels()
        }
    }

    func stop() {
        panels.forEach { $0.close() }
        panels.removeAll()
    }

    func showImpact(at screenPoint: CGPoint, strength: CGFloat = 1) {
        panel(containing: screenPoint)?.effectView.addImpact(
            at: localPoint(screenPoint, in: panel(containing: screenPoint)),
            strength: strength
        )
    }

    /// Dust rolling out from where Stickman lands. Strength 1 is a solid drop; above 1 adds a ground shockwave.
    func showLandingDust(at screenPoint: CGPoint, strength: CGFloat) {
        guard let panel = panel(containing: screenPoint) else { return }
        panel.effectView.addLandingDust(at: localPoint(screenPoint, in: panel), strength: strength)
    }

    func showSlash(from start: CGPoint, to end: CGPoint) {
        guard let panel = panel(containing: end) ?? panel(containing: start) else { return }
        panel.effectView.addSlash(
            from: CGPoint(x: start.x - panel.frame.minX, y: start.y - panel.frame.minY),
            to: CGPoint(x: end.x - panel.frame.minX, y: end.y - panel.frame.minY)
        )
    }

    func showTether(from start: CGPoint, to end: CGPoint, duration: TimeInterval = 0.42) {
        guard let panel = panel(containing: end) ?? panel(containing: start) else { return }
        panel.effectView.setTether(
            from: CGPoint(x: start.x - panel.frame.minX, y: start.y - panel.frame.minY),
            to: CGPoint(x: end.x - panel.frame.minX, y: end.y - panel.frame.minY),
            duration: duration
        )
    }

    /// Marks where Claude clicked during computer use.
    func showClickRipple(at screenPoint: CGPoint) {
        guard let panel = panel(containing: screenPoint) else { return }
        panel.effectView.addClickRipple(at: localPoint(screenPoint, in: panel))
    }

    func showModeTransition(at screenPoint: CGPoint, enteringCombat: Bool) {
        guard let panel = panel(containing: screenPoint) else { return }
        let point = CGPoint(x: screenPoint.x - panel.frame.minX, y: screenPoint.y - panel.frame.minY)
        panel.effectView.addModeTransition(at: point, enteringCombat: enteringCombat)
    }

    func showGuidance(_ markers: [ScreenGuidanceMarker], on screen: NSScreen? = NSScreen.main) {
        guard let targetScreen = screen,
              let panel = panels.first(where: { $0.targetScreen === targetScreen })
        else { return }
        panel.effectView.setGuidance(markers)
    }

    func clearGuidance() {
        panels.forEach { $0.effectView.setGuidance([]) }
    }

    private func rebuildPanels() {
        panels.forEach { $0.close() }
        panels = NSScreen.screens.map { screen in
            let panel = ScreenEffectsPanel(screen: screen)
            panel.orderFrontRegardless()
            return panel
        }
    }

    private func panel(containing point: CGPoint) -> ScreenEffectsPanel? {
        panels.first { $0.frame.contains(point) } ?? panels.first
    }

    private func localPoint(_ point: CGPoint, in panel: ScreenEffectsPanel?) -> CGPoint {
        guard let panel else { return point }
        return CGPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY)
    }
}

private final class ScreenEffectsPanel: NSPanel {
    let targetScreen: NSScreen
    let effectView: ScreenEffectsView

    init(screen: NSScreen) {
        targetScreen = screen
        effectView = ScreenEffectsView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        contentView = effectView
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
    }
}

private final class ScreenEffectsView: NSView {
    private struct Tether {
        let start: CGPoint
        let end: CGPoint
        let bornAt: TimeInterval
        let duration: TimeInterval
    }

    private var timer: Timer?
    private var tether: Tether?
    private var guidance: [ScreenGuidanceMarker] = []
    private var guidanceBornAt: TimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { timer?.invalidate() }

    func addImpact(at point: CGPoint, strength: CGFloat) {
        guard let layer else { return }
        StickmanParticles.impact(in: layer, at: point, strength: strength)
    }

    func addLandingDust(at point: CGPoint, strength: CGFloat) {
        guard let layer else { return }
        StickmanParticles.landingDust(in: layer, at: point, strength: strength)
    }

    func addSlash(from start: CGPoint, to end: CGPoint) {
        guard let layer else { return }
        StickmanParticles.slash(in: layer, from: start, to: end)
    }

    func setTether(from start: CGPoint, to end: CGPoint, duration: TimeInterval) {
        tether = Tether(start: start, end: end, bornAt: now, duration: duration)
        needsDisplay = true
    }

    func addClickRipple(at point: CGPoint) {
        guard let layer else { return }
        for (offset, delay) in [(0, 0.0), (1, 0.12)] {
            let ring = CAShapeLayer()
            ring.path = CGPath(ellipseIn: CGRect(x: -14, y: -14, width: 28, height: 28), transform: nil)
            ring.position = point
            ring.fillColor = offset == 0 ? NSColor.systemOrange.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
            ring.strokeColor = NSColor.systemOrange.withAlphaComponent(0.9).cgColor
            ring.lineWidth = offset == 0 ? 2.5 : 1.5
            ring.opacity = 0
            layer.addSublayer(ring)

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.35
            scale.toValue = offset == 0 ? 1.25 : 1.9
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 0]
            fade.keyTimes = [0, 0.18, 1]
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 0.55
            group.beginTime = CACurrentMediaTime() + delay
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.fillMode = .both
            group.isRemovedOnCompletion = false
            ring.add(group, forKey: "ripple")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8 + delay) { ring.removeFromSuperlayer() }
        }
    }

    func addModeTransition(at point: CGPoint, enteringCombat: Bool) {
        guard let layer else { return }
        StickmanParticles.modeShift(in: layer, at: point, enteringCombat: enteringCombat)
    }

    func setGuidance(_ markers: [ScreenGuidanceMarker]) {
        guidance = markers
        guidanceBornAt = now
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        drawTether(context)
        drawGuidance(context)
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func tick() {
        let timestamp = now
        if let tether, timestamp - tether.bornAt > tether.duration { self.tether = nil }
        if tether != nil || !guidance.isEmpty {
            needsDisplay = true
        }
    }

    /// The lasso rope: sags a little, ripples while it pulls, and has a light highlight
    /// so it reads on dark backgrounds.
    private func drawTether(_ context: CGContext) {
        guard let tether else { return }
        let progress = CGFloat((now - tether.bornAt) / tether.duration)
        let alpha = max(0, min(1, 1 - progress))
        let distance = hypot(tether.end.x - tether.start.x, tether.end.y - tether.start.y)
        let segments = max(12, Int(distance / 8))
        let sag = min(40, distance * 0.12) * (1 - progress)

        let rope = CGMutablePath()
        rope.move(to: tether.start)
        for index in 1 ... segments {
            let t = CGFloat(index) / CGFloat(segments)
            let envelope = sin(t * .pi)
            let ripple = sin(t * .pi * 5 - CGFloat(now * 26)) * 3 * envelope
            let x = tether.start.x + (tether.end.x - tether.start.x) * t
            let y = tether.start.y + (tether.end.y - tether.start.y) * t - sag * envelope + ripple
            rope.addLine(to: CGPoint(x: x, y: y))
        }

        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(rope)
        context.setStrokeColor(NSColor(calibratedWhite: 0.08, alpha: alpha * 0.85).cgColor)
        context.setLineWidth(4.5)
        context.strokePath()
        context.translateBy(x: -0.8, y: 0.8)
        context.addPath(rope)
        context.setStrokeColor(NSColor.white.withAlphaComponent(alpha * 0.45).cgColor)
        context.setLineWidth(1.4)
        context.strokePath()
        context.restoreGState()
    }

    private func drawGuidance(_ context: CGContext) {
        let age = CGFloat(now - guidanceBornAt)
        let pulse = CGFloat((sin(Double(age) * 5) + 1) * 0.5)
        for (index, marker) in guidance.enumerated() {
            let point = CGPoint(
                x: marker.normalizedPoint.x * bounds.width,
                y: (1 - marker.normalizedPoint.y) * bounds.height
            )
            let radius = 22 + pulse * 5
            context.saveGState()
            context.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.82).cgColor)
            context.setLineWidth(3)
            context.strokeEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            context.setFillColor(NSColor.systemBlue.withAlphaComponent(0.92).cgColor)
            context.fillEllipse(in: CGRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22))

            let number = "\(index + 1)" as NSString
            number.draw(
                at: CGPoint(x: point.x - 3.5, y: point.y - 7),
                withAttributes: [
                    .foregroundColor: NSColor.white,
                    .font: NSFont.systemFont(ofSize: 12, weight: .bold)
                ]
            )

            let label = marker.label.isEmpty ? "Look here" : marker.label
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
            ]
            let size = (label as NSString).size(withAttributes: attributes)
            let bubble = CGRect(x: point.x + 30, y: point.y - 14, width: size.width + 20, height: 28)
            context.setFillColor(NSColor.black.withAlphaComponent(0.84).cgColor)
            context.addPath(CGPath(roundedRect: bubble, cornerWidth: 8, cornerHeight: 8, transform: nil))
            context.fillPath()
            (label as NSString).draw(at: CGPoint(x: bubble.minX + 10, y: bubble.minY + 6), withAttributes: attributes)
            context.restoreGState()
        }
    }
}
