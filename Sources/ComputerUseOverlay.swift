import AppKit

/// The on-screen side of computer use: a "Claude is using <App> · esc to stop" banner while
/// Claude works, and a prompt the first time Claude wants a new app.
@MainActor
final class ComputerUseOverlay {
    enum Approval {
        case always
        case once
        case deny
    }

    var onStop: (() -> Void)?

    private var banner: BannerPanel?
    private var approvalPanel: ApprovalPanel?
    private var approvalContinuation: CheckedContinuation<Approval, Never>?
    private var keyMonitors: [Any] = []
    private var hideWork: DispatchWorkItem?
    private var lastSyntheticKeyAt = Date.distantPast

    /// Claude's own key presses must not count as the user pressing Esc.
    func noteSyntheticKey() {
        lastSyntheticKeyAt = Date()
    }

    // MARK: Banner

    func showBanner(appName: String) {
        hideWork?.cancel()
        let banner = self.banner ?? BannerPanel()
        self.banner = banner
        banner.show(text: "Claude is using \(appName)", stopped: false)
        installKeyMonitors()
    }

    func hideBanner() {
        removeKeyMonitors()
        banner?.fadeOut()
    }

    func showStopped() {
        removeKeyMonitors()
        banner?.show(text: "Stopped Claude", stopped: true)
        let work = DispatchWorkItem { [weak self] in self?.banner?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private func installKeyMonitors() {
        guard keyMonitors.isEmpty else { return }
        let handle: (UInt16, Bool) -> Bool = { [weak self] keyCode, synthetic in
            guard let self, keyCode == 53, !synthetic else { return false }
            if Date().timeIntervalSince(self.lastSyntheticKeyAt) < 0.4 { return false }
            self.onStop?()
            return true
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
            let keyCode = event.keyCode
            let synthetic = event.cgEvent?.isStickmanSynthetic == true
            MainActor.assumeIsolated { _ = handle(keyCode, synthetic) }
        }) {
            keyMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            let keyCode = event.keyCode
            let synthetic = event.cgEvent?.isStickmanSynthetic == true
            let stopped = MainActor.assumeIsolated { handle(keyCode, synthetic) }
            return stopped ? nil : event
        }) {
            keyMonitors.append(local)
        }
    }

    private func removeKeyMonitors() {
        keyMonitors.forEach(NSEvent.removeMonitor)
        keyMonitors.removeAll()
    }

    // MARK: Approval

    func askApproval(appName: String, icon: NSImage?) async -> Approval {
        await withCheckedContinuation { continuation in
            approvalContinuation = continuation
            let panel = ApprovalPanel(appName: appName, icon: icon) { [weak self] answer in
                self?.finishApproval(answer)
            }
            approvalPanel = panel
            panel.present()
            DispatchQueue.main.asyncAfter(deadline: .now() + 240) { [weak self, weak panel] in
                guard let self, let panel, self.approvalPanel === panel else { return }
                self.finishApproval(.deny)
            }
        }
    }

    private func finishApproval(_ answer: Approval) {
        approvalPanel?.dismiss()
        approvalPanel = nil
        approvalContinuation?.resume(returning: answer)
        approvalContinuation = nil
    }

    // MARK: Placement

    /// Just under the menu bar and notch on the screen with the pointer.
    fileprivate static func topCenter(for size: NSSize, offset: CGFloat) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: (visible.midX - size.width / 2).rounded(), y: (visible.maxY - offset - size.height).rounded())
    }
}

// MARK: - Banner

private final class BannerPanel: NSPanel {
    private let glass = StickmanGlassView()
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let keycap = NSTextField(labelWithString: "esc")
    private let hint = NSTextField(labelWithString: "to stop")

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 36), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        contentView = glass
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = StickmanStyle.primaryText
        keycap.font = .monospacedSystemFont(ofSize: 10.5, weight: .semibold)
        keycap.textColor = StickmanStyle.secondaryText
        keycap.alignment = .center
        keycap.wantsLayer = true
        keycap.layer?.cornerRadius = 5
        keycap.layer?.borderWidth = 1
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = StickmanStyle.secondaryText
        [dot, label, keycap, hint].forEach(glass.addContent)
    }

    func show(text: String, stopped: Bool) {
        label.stringValue = text
        keycap.isHidden = stopped
        hint.isHidden = stopped
        dot.layer?.backgroundColor = (stopped ? NSColor.systemGray : NSColor.systemOrange).cgColor
        keycap.layer?.borderColor = StickmanStyle.fieldStroke.cgColor
        keycap.layer?.backgroundColor = StickmanStyle.codeFill.cgColor
        layoutContent()
        pulse(!stopped)
        alphaValue = isVisible ? alphaValue : 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().alphaValue = 1
        }
    }

    func fadeOut() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue < 0.01 else { return }
                self.orderOut(nil)
            }
        })
    }

    private func layoutContent() {
        label.sizeToFit()
        hint.sizeToFit()
        let height: CGFloat = 36
        var x: CGFloat = 16
        dot.frame = NSRect(x: x, y: (height - 8) / 2, width: 8, height: 8)
        x += 8 + 9
        label.frame = NSRect(x: x, y: (height - label.frame.height) / 2, width: label.frame.width, height: label.frame.height)
        x += label.frame.width
        if !keycap.isHidden {
            x += 12
            keycap.frame = NSRect(x: x, y: (height - 18) / 2 - 1, width: 30, height: 18)
            x += 30 + 6
            hint.frame = NSRect(x: x, y: (height - hint.frame.height) / 2, width: hint.frame.width, height: hint.frame.height)
            x += hint.frame.width
        }
        x += 16
        let size = NSSize(width: x, height: height)
        setFrame(NSRect(origin: ComputerUseOverlay.topCenter(for: size, offset: 8), size: size), display: true)
    }

    private func pulse(_ on: Bool) {
        dot.layer?.removeAnimation(forKey: "pulse")
        guard on else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0.35
        animation.duration = 0.8
        animation.autoreverses = true
        animation.repeatCount = .infinity
        dot.layer?.add(animation, forKey: "pulse")
    }
}

// MARK: - Approval

private final class ApprovalPanel: NSPanel {
    private let onAnswer: (ComputerUseOverlay.Approval) -> Void

    init(appName: String, icon: NSImage?, onAnswer: @escaping (ComputerUseOverlay.Approval) -> Void) {
        self.onAnswer = onAnswer
        let size = NSSize(width: 380, height: 150)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let glass = StickmanGlassView(frame: NSRect(origin: .zero, size: size))
        contentView = glass

        let iconView = NSImageView(frame: NSRect(x: 18, y: size.height - 18 - 40, width: 40, height: 40))
        iconView.image = icon ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        iconView.imageScaling = .scaleProportionallyUpOrDown

        let title = NSTextField(labelWithString: "Let Claude use \(appName)?")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = StickmanStyle.primaryText
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 72, y: size.height - 40, width: size.width - 90, height: 20)

        let body = NSTextField(wrappingLabelWithString: "Claude Code wants to see and control \(appName) for a task you started. You can press esc anytime to stop it.")
        body.font = .systemFont(ofSize: 12)
        body.textColor = StickmanStyle.secondaryText
        body.frame = NSRect(x: 72, y: size.height - 92, width: size.width - 90, height: 48)

        let deny = NSButton(title: "Don't Allow", target: nil, action: nil)
        let once = NSButton(title: "Allow Once", target: nil, action: nil)
        let always = NSButton(title: "Always Allow", target: nil, action: nil)
        StickmanStyle.configureSecondaryButton(deny)
        StickmanStyle.configureSecondaryButton(once)
        StickmanStyle.configurePrimaryButton(always)
        var x = size.width - 16
        for (button, answer) in [(always, ComputerUseOverlay.Approval.always), (once, .once), (deny, .deny)] {
            button.sizeToFit()
            let width = max(button.frame.width + 8, 92)
            x -= width
            button.frame = NSRect(x: x, y: 14, width: width, height: 28)
            x -= 8
            button.target = self
            button.action = #selector(answered(_:))
            button.tag = [ComputerUseOverlay.Approval.always, .once, .deny].firstIndex(of: answer) ?? 2
        }
        [iconView, title, body, deny, once, always].forEach(glass.addContent)
    }

    override var canBecomeKey: Bool { true }

    func present() {
        setFrameOrigin(ComputerUseOverlay.topCenter(for: frame.size, offset: 52))
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            animator().alphaValue = 1
        }
        NSSound(named: "Tink")?.play()
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.orderOut(nil) }
        })
    }

    @objc private func answered(_ sender: NSButton) {
        let answers: [ComputerUseOverlay.Approval] = [.always, .once, .deny]
        onAnswer(answers[max(0, min(2, sender.tag))])
    }
}
