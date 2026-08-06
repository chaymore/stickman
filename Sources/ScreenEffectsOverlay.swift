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
    private struct Impact {
        let point: CGPoint
        let bornAt: TimeInterval
        let strength: CGFloat
    }

    private struct Slash {
        let start: CGPoint
        let end: CGPoint
        let bornAt: TimeInterval
    }

    private struct Tether {
        let start: CGPoint
        let end: CGPoint
        let bornAt: TimeInterval
        let duration: TimeInterval
    }

    private struct Transition {
        let point: CGPoint
        let bornAt: TimeInterval
        let enteringCombat: Bool
    }

    private var timer: Timer?
    private var impacts: [Impact] = []
    private var slashes: [Slash] = []
    private var tether: Tether?
    private var transition: Transition?
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
        impacts.append(Impact(point: point, bornAt: now, strength: max(0.4, min(2, strength))))
        needsDisplay = true
    }

    func addSlash(from start: CGPoint, to end: CGPoint) {
        slashes.append(Slash(start: start, end: end, bornAt: now))
        needsDisplay = true
    }

    func setTether(from start: CGPoint, to end: CGPoint, duration: TimeInterval) {
        tether = Tether(start: start, end: end, bornAt: now, duration: duration)
        needsDisplay = true
    }

    func addModeTransition(at point: CGPoint, enteringCombat: Bool) {
        transition = Transition(point: point, bornAt: now, enteringCombat: enteringCombat)
        needsDisplay = true
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

        drawImpacts(context)
        drawSlashes(context)
        drawTether(context)
        drawTransition(context)
        drawGuidance(context)
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func tick() {
        let timestamp = now
        impacts.removeAll { timestamp - $0.bornAt > 0.72 }
        slashes.removeAll { timestamp - $0.bornAt > 0.32 }
        if let tether, timestamp - tether.bornAt > tether.duration { self.tether = nil }
        if let transition, timestamp - transition.bornAt > 0.9 { self.transition = nil }
        if !impacts.isEmpty || !slashes.isEmpty || tether != nil || transition != nil || !guidance.isEmpty {
            needsDisplay = true
        }
    }

    private func drawImpacts(_ context: CGContext) {
        for impact in impacts {
            let progress = CGFloat((now - impact.bornAt) / 0.72)
            let alpha = max(0, 1 - progress)
            let radius = (14 + progress * 92) * impact.strength

            context.saveGState()
            context.setStrokeColor(NSColor.black.withAlphaComponent(alpha * 0.72).cgColor)
            context.setLineWidth(max(1.2, 5 * (1 - progress)))
            context.strokeEllipse(in: CGRect(
                x: impact.point.x - radius,
                y: impact.point.y - radius,
                width: radius * 2,
                height: radius * 2
            ))

            for index in 0 ..< 18 {
                let angle = CGFloat(index) / 18 * .pi * 2 + impact.point.x.truncatingRemainder(dividingBy: 1.7)
                let inner = radius * 0.25
                let outer = radius * (0.6 + CGFloat((index * 37) % 31) / 60)
                context.move(to: CGPoint(
                    x: impact.point.x + cos(angle) * inner,
                    y: impact.point.y + sin(angle) * inner
                ))
                context.addLine(to: CGPoint(
                    x: impact.point.x + cos(angle) * outer,
                    y: impact.point.y + sin(angle) * outer
                ))
            }
            context.setLineWidth(2.4 * impact.strength)
            context.strokePath()
            context.restoreGState()
        }
    }

    private func drawSlashes(_ context: CGContext) {
        for slash in slashes {
            let progress = CGFloat((now - slash.bornAt) / 0.32)
            let alpha = max(0, 1 - progress)
            let vector = CGVector(dx: slash.end.x - slash.start.x, dy: slash.end.y - slash.start.y)
            let length = max(1, hypot(vector.dx, vector.dy))
            let normal = CGVector(dx: -vector.dy / length, dy: vector.dx / length)

            context.saveGState()
            context.setLineCap(.round)
            for offset in [-5.0, 0.0, 5.0] {
                context.move(to: CGPoint(x: slash.start.x + normal.dx * offset, y: slash.start.y + normal.dy * offset))
                context.addLine(to: CGPoint(x: slash.end.x + normal.dx * offset, y: slash.end.y + normal.dy * offset))
                context.setStrokeColor(NSColor.black.withAlphaComponent(alpha * (offset == 0 ? 0.86 : 0.28)).cgColor)
                context.setLineWidth(offset == 0 ? 5 : 1.5)
                context.strokePath()
            }
            context.restoreGState()
        }
    }

    private func drawTether(_ context: CGContext) {
        guard let tether else { return }
        let progress = CGFloat((now - tether.bornAt) / tether.duration)
        let alpha = max(0, min(1, 1 - progress))
        let distance = hypot(tether.end.x - tether.start.x, tether.end.y - tether.start.y)
        let segments = max(5, Int(distance / 18))

        context.saveGState()
        context.setStrokeColor(NSColor.black.withAlphaComponent(alpha * 0.72).cgColor)
        context.setLineWidth(3)
        context.setLineCap(.round)
        context.move(to: tether.start)
        for index in 1 ... segments {
            let t = CGFloat(index) / CGFloat(segments)
            let wave = sin(t * .pi * 8 + CGFloat(now * 22)) * 5 * (1 - abs(t - 0.5))
            let x = tether.start.x + (tether.end.x - tether.start.x) * t
            let y = tether.start.y + (tether.end.y - tether.start.y) * t + wave
            context.addLine(to: CGPoint(x: x, y: y))
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawTransition(_ context: CGContext) {
        guard let transition else { return }
        let progress = CGFloat((now - transition.bornAt) / 0.9)
        let alpha = max(0, 1 - progress)
        let radius = 30 + progress * 180

        context.saveGState()
        context.setStrokeColor(NSColor.black.withAlphaComponent(alpha * 0.45).cgColor)
        context.setLineWidth(transition.enteringCombat ? 6 : 2)
        let dash: [CGFloat] = transition.enteringCombat ? [14, 9] : [3, 12]
        context.setLineDash(phase: progress * 40, lengths: dash)
        context.strokeEllipse(in: CGRect(
            x: transition.point.x - radius,
            y: transition.point.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
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
