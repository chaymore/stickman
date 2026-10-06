import AppKit

/// Floating glass panel for chat and settings. It sits beside Stickman with a tail
/// pointing at him and follows him if he moves while it is open.
final class StickmanCompanionPanelController {
    enum Content {
        case chat
        case settings
    }

    static let chatSize = NSSize(width: 380, height: 500)
    static let settingsSize = NSSize(width: 560, height: 520)

    let chatView = StickmanChatPanelView(frame: NSRect(origin: .zero, size: StickmanCompanionPanelController.chatSize))
    let settingsView = StickmanSettingsPanelView(frame: NSRect(origin: .zero, size: StickmanCompanionPanelController.settingsSize))
    var onEscape: (() -> Void)?

    private(set) var content: Content?
    private(set) var isOnRight = true
    private let window: StickmanPanelWindow
    private let glass = StickmanGlassView(frame: .zero)
    private let contentHost = NSView()
    private var isHiding = false

    var isVisible: Bool { content != nil }

    init() {
        window = StickmanPanelWindow(contentRect: NSRect(origin: .zero, size: Self.chatSize))
        glass.frame = NSRect(origin: .zero, size: Self.chatSize)
        glass.autoresizingMask = [.width, .height]
        window.contentView = glass
        glass.addContent(contentHost)
        contentHost.addSubview(chatView)
        contentHost.addSubview(settingsView)
        window.onEscape = { [weak self] in self?.onEscape?() }
    }

    func present(_ content: Content, beside character: NSRect) {
        let wasVisible = isVisible && !isHiding
        isHiding = false
        self.content = content
        chatView.isHidden = content != .chat
        settingsView.isHidden = content != .settings
        if content == .settings { settingsView.refresh() }

        let frame = targetFrame(for: content, beside: character, keepSide: wasVisible)
        applyLayout(frame: frame, character: character)

        if wasVisible {
            window.setFrame(frame, display: true, animate: true)
        } else {
            window.alphaValue = 0
            window.setFrame(frame.offsetBy(dx: isOnRight ? -8 : 8, dy: 0), display: false)
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
                window.animator().setFrame(frame, display: true)
            }
        }
    }

    func hide() {
        guard isVisible else { return }
        content = nil
        isHiding = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.isHiding else { return }
            self.window.orderOut(nil)
            self.isHiding = false
        })
    }

    /// Keeps the panel beside Stickman as he moves.
    func follow(_ character: NSRect) {
        guard let content, !isHiding else { return }
        let frame = targetFrame(for: content, beside: character, keepSide: true)
        guard abs(frame.minX - window.frame.minX) > 0.5 || abs(frame.minY - window.frame.minY) > 0.5 else { return }
        window.setFrame(frame, display: true)
        applyLayout(frame: frame, character: character)
    }

    func makeKey() {
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKey()
    }

    func makeFirstResponder(_ responder: NSResponder?) {
        window.makeFirstResponder(responder)
    }

    func setHiddenForCapture(_ hidden: Bool) {
        window.alphaValue = hidden ? 0 : (isVisible ? 1 : 0)
    }

    private func targetFrame(for content: Content, beside character: NSRect, keepSide: Bool) -> NSRect {
        let body = content == .chat ? Self.chatSize : Self.settingsSize
        let size = NSSize(width: body.width + StickmanPanelShape.tailWidth, height: body.height)
        let screen = (NSScreen.screens.first { $0.frame.intersects(character) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // The figure fills only the middle of its square window.
        let figureHalfWidth: CGFloat = 22
        let rightX = character.midX + figureHalfWidth
        let leftX = character.midX - figureHalfWidth - size.width
        let fitsRight = rightX + size.width <= screen.maxX - 8
        let fitsLeft = leftX >= screen.minX + 8
        if keepSide {
            if isOnRight, !fitsRight, fitsLeft { isOnRight = false }
            if !isOnRight, !fitsLeft, fitsRight { isOnRight = true }
        } else {
            isOnRight = fitsRight || !fitsLeft
        }

        var x = isOnRight ? rightX : leftX
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        let feetY = character.minY + StickmanMetrics.footInset
        let y = min(max(feetY - 4, screen.minY + 8), screen.maxY - size.height - 8)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func applyLayout(frame: NSRect, character: NSRect) {
        let tailWidth = StickmanPanelShape.tailWidth
        let chestY = (character.minY + character.height * 0.6 - frame.minY).rounded()
        glass.tail = isOnRight ? .left(y: chestY) : .right(y: chestY)
        let bodyWidth = frame.width - tailWidth
        contentHost.frame = NSRect(x: isOnRight ? tailWidth : 0, y: 0, width: bodyWidth, height: frame.height)
        let bounds = NSRect(origin: .zero, size: contentHost.frame.size)
        chatView.frame = bounds
        settingsView.frame = bounds
    }
}

final class StickmanPanelWindow: NSPanel {
    var onEscape: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        worksWhenModal = true
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
