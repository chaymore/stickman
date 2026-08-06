import AppKit

final class StickmanRootView: NSView {
    enum AmbientPersonality {
        case thoughtfulGlance
        case screenCuriosity
        case cursorReach(screenPoint: NSPoint)
        case tinyCelebrate
    }

    var onToggleChat: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onCloseSettings: (() -> Void)?
    var onCursorStrike: ((CGPoint) -> Void)?
    var onScreenGuidance: (([ScreenGuidanceMarker]) -> Void)?

    private let stickmanView = StickmanView(frame: NSRect(x: 0, y: 0, width: StickmanMetrics.characterSize, height: StickmanMetrics.characterSize))
    private let chatPanel = StickmanChatPanelView(frame: NSRect(x: StickmanMetrics.characterSize, y: 14, width: 368, height: 322))
    private let settingsPanel = StickmanSettingsPanelView(frame: NSRect(x: StickmanMetrics.characterSize, y: 14, width: 388, height: 392))
    private var ambientResetWorkItem: DispatchWorkItem?
    private var taskAnimationObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        stickmanView.onToggleChat = { [weak self] in
            self?.onToggleChat?()
        }
        stickmanView.onCursorStrike = { [weak self] point in
            self?.onCursorStrike?(point)
        }
        chatPanel.onOpenSettings = { [weak self] in
            self?.onOpenSettings?()
        }
        chatPanel.onActivityChanged = { [weak self] activity in
            self?.stickmanView.setActivity(activity)
        }
        chatPanel.onSuccessMoment = { [weak self] in
            self?.stickmanView.showSuccessMoment()
        }
        chatPanel.onErrorMoment = { [weak self] in
            self?.stickmanView.showErrorMoment()
        }
        chatPanel.onScreenGuidance = { [weak self] markers in
            self?.onScreenGuidance?(markers)
        }
        settingsPanel.onClose = { [weak self] in
            self?.onCloseSettings?()
        }
        addSubview(settingsPanel)
        addSubview(chatPanel)
        addSubview(stickmanView)
        taskAnimationObserver = NotificationCenter.default.addObserver(
            forName: .stickmanTaskAnimationRequested,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?["animation"] as? String,
                  let animation = StickmanTaskAnimation(rawValue: raw)
            else { return }
            self?.stickmanView.performTaskAnimation(animation)
        }
        setChatVisible(false)
        setSettingsVisible(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let taskAnimationObserver { NotificationCenter.default.removeObserver(taskAnimationObserver) }
    }

    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()

        let size = StickmanMetrics.characterSize
        stickmanView.frame = NSRect(x: 0, y: max(0, bounds.midY - size / 2), width: size, height: size)
        chatPanel.frame = NSRect(
            x: size - 6,
            y: 14,
            width: max(0, bounds.width - size - 14),
            height: max(0, bounds.height - 28)
        )
        settingsPanel.frame = chatPanel.frame
    }

    func setChatVisible(_ isVisible: Bool) {
        cancelAmbientPersonality()
        chatPanel.isHidden = !isVisible
        if isVisible {
            settingsPanel.isHidden = true
        } else {
            stickmanView.setActivity(.quiet)
        }
        stickmanView.setChatVisible(isVisible)
        needsLayout = true
    }

    func setSettingsVisible(_ isVisible: Bool) {
        cancelAmbientPersonality()
        settingsPanel.isHidden = !isVisible
        if isVisible {
            chatPanel.isHidden = true
            settingsPanel.refresh()
            stickmanView.setActivity(.working)
        } else {
            stickmanView.setActivity(.quiet)
        }
        stickmanView.setChatVisible(isVisible)
        needsLayout = true
    }

    func setLocomotion(intensity: CGFloat, facingDirection: CGFloat) {
        stickmanView.setLocomotion(intensity: intensity, facingDirection: facingDirection)
    }

    func setNavigationGrip(screenPoint: NSPoint?) {
        guard let screenPoint, let window else {
            stickmanView.setNavigationGrip(nil)
            return
        }

        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let rootPoint = convert(windowPoint, from: nil)
        stickmanView.setNavigationGrip(stickmanView.convert(rootPoint, from: self))
    }

    func setPerched(_ perched: Bool) {
        cancelAmbientPersonality()
        stickmanView.setPerched(perched)
    }

    func showAmbientPersonality(_ personality: AmbientPersonality) {
        cancelAmbientPersonality()

        switch personality {
        case .thoughtfulGlance:
            stickmanView.setActivity(.thinking)
            scheduleAmbientReset(after: 1.4)
        case .screenCuriosity:
            stickmanView.setActivity(.listening)
            scheduleAmbientReset(after: 1.1)
        case .cursorReach(let screenPoint):
            stickmanView.setActivity(.listening)
            setNavigationGrip(screenPoint: screenPoint)
            scheduleAmbientReset(after: 1.15)
        case .tinyCelebrate:
            stickmanView.showSuccessMoment()
            scheduleAmbientReset(after: 1.1)
        }
    }

    func cancelAmbientPersonality() {
        ambientResetWorkItem?.cancel()
        ambientResetWorkItem = nil
        stickmanView.setNavigationGrip(nil)
        stickmanView.setActivity(.quiet)
    }

    func focusChatInput() {
        chatPanel.focusInput()
    }

    func prepareQuickAssist() {
        chatPanel.prepareScreenContext()
    }

    func startVoiceMode() {
        chatPanel.startVoiceMode()
    }

    func showAgentStatus() {
        chatPanel.showAgentStatus()
    }

    func setMode(_ mode: StickmanMode) {
        stickmanView.setMode(mode)
    }

    func performCombatMove(_ move: StickmanCombatMove) {
        stickmanView.performCombatMove(move)
    }

    func focusSettingsInput() {
        settingsPanel.focusFirstControl()
    }

    func showPermissionSettings() {
        settingsPanel.showPermissions()
    }

    func showConnectionSettings() {
        settingsPanel.showConnections()
    }

    private func scheduleAmbientReset(after delay: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.stickmanView.setNavigationGrip(nil)
            self?.stickmanView.setActivity(.quiet)
            self?.ambientResetWorkItem = nil
        }
        ambientResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}
