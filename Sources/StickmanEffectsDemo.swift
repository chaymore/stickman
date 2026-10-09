import AppKit

/// Developer preview: `Stickman --effects-demo` opens a small window, half light and half
/// dark, and replays the landing, hit, slash, and fight-start particles on a loop.
@MainActor
enum StickmanEffectsDemo {
    private static var window: NSWindow?
    private static var timer: Timer?

    static func run(seconds: TimeInterval) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let frame = NSRect(x: 40, y: 40, width: 960, height: 480)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Stickman effects demo"
        let view = DemoBackdropView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = view
        window.orderFrontRegardless()
        self.window = window
        print("DEMO_WINDOW_ID=\(window.windowNumber)")
        fflush(stdout)

        let host = view.layer!
        let fire = {
            StickmanParticles.landingDust(in: host, at: CGPoint(x: 150, y: 90), strength: 1.4)
            StickmanParticles.impact(in: host, at: CGPoint(x: 380, y: 260), strength: 1.2)
            StickmanParticles.slash(in: host, from: CGPoint(x: 560, y: 140), to: CGPoint(x: 760, y: 330))
            StickmanParticles.modeShift(in: host, at: CGPoint(x: 860, y: 260), enteringCombat: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { fire() }
        let timer = Timer(timeInterval: 2.0, repeats: true) { _ in MainActor.assumeIsolated { fire() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
        app.run()
    }

    private final class DemoBackdropView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func draw(_ dirtyRect: NSRect) {
            NSColor(calibratedRed: 0.93, green: 0.92, blue: 0.89, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: bounds.midX, height: bounds.height).fill()
            NSColor(calibratedRed: 0.1, green: 0.11, blue: 0.14, alpha: 1).setFill()
            NSRect(x: bounds.midX, y: 0, width: bounds.midX, height: bounds.height).fill()
            NSColor.black.withAlphaComponent(0.2).setFill()
            NSRect(x: 0, y: 88, width: bounds.midX, height: 2).fill()
        }
    }
}
