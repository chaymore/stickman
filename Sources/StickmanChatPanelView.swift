import AppKit

final class StickmanChatPanelView: NSView, RealtimeVoiceClientDelegate {
    enum StatusTone {
        case ready
        case busy
        case listening
        case speaking
        case problem

        var color: NSColor {
            switch self {
            case .ready: return .systemGreen
            case .busy: return .systemOrange
            case .listening: return .systemRed
            case .speaking: return .systemBlue
            case .problem: return .systemRed
            }
        }
    }

    var onOpenSettings: (() -> Void)?
    var onClose: (() -> Void)?
    var onActivityChanged: ((StickmanView.Activity) -> Void)?
    var onSuccessMoment: (() -> Void)?
    var onErrorMoment: (() -> Void)?
    var onScreenGuidance: (([ScreenGuidanceMarker]) -> Void)?

    private let avatar = StickmanAvatarBadgeView()
    private let titleLabel = NSTextField(labelWithString: "Stickman")
    private let statusDot = StatusDotView()
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let agentsButton = StickmanIconButton(symbol: "sparkles", label: "Background agents")
    private let claudeButton = StickmanIconButton(symbol: "terminal", label: "Claude Code sessions")
    private let claudeSessionsView = ClaudeSessionsView()
    private let settingsButton = StickmanIconButton(symbol: "gearshape", label: "Settings")
    private let closeButton = StickmanIconButton(symbol: "xmark", label: "Close", pointSize: 11, weight: .bold)
    private let separator = HairlineView()
    private let scrollView = NSScrollView()
    private let transcript = TranscriptDocumentView()
    private var bubbleViews: [MessageBubbleView] = []
    private var suggestionChips: [StickmanChipButton] = []
    private let composer = ComposerContainerView()
    private let composerScroll = NSScrollView()
    private let composerText = ComposerTextView()
    private let attachmentChip = AttachmentChipView()
    private let screenshotButton = StickmanIconButton(symbol: "camera.viewfinder", label: "Attach a screenshot")
    private let voiceButton = StickmanIconButton(symbol: "mic", label: "Start voice mode")
    private let sendButton = StickmanIconButton(symbol: "arrow.up", label: "Send", pointSize: 12, weight: .bold)

    private let aiClient: AIClient = AIClientFactory.make()
    private var realtimeVoiceClient: RealtimeVoiceClient?
    private var responseTask: Task<Void, Never>?
    private var voiceTask: Task<Void, Never>?
    private var responseTimeoutTimer: Timer?
    private var isThinking = false
    private var isVoiceModeActive = false
    private var voiceAssistantMessageIndex: Int?
    private var pendingScreenshot: ScreenshotAttachment? { didSet { attachmentChip.isHidden = pendingScreenshot == nil; needsLayout = true } }
    private var agentObservers: [NSObjectProtocol] = []

    private var messages: [ChatMessage] = [
        ChatMessage(role: .assistant, content: StickmanChatPanelView.randomWelcomeMessage())
    ]

    private static let suggestions = ["What's on my screen?", "Help me focus", "What's on my calendar?"]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHeader()
        configureTranscript()
        configureComposer()
        installAgentObservers()
        refreshAgentButton()
        setStatus("Ready", tone: .ready)
        renderMessages()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        responseTimeoutTimer?.invalidate()
        responseTask?.cancel()
        voiceTask?.cancel()
        realtimeVoiceClient?.stop()
        agentObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override var isFlipped: Bool { true }

    // MARK: Layout

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height

        avatar.frame = NSRect(x: 16, y: 14, width: 30, height: 30)
        titleLabel.frame = NSRect(x: 56, y: 12, width: width - 180, height: 18)
        statusDot.frame = NSRect(x: 57, y: 35, width: 7, height: 7)
        statusLabel.frame = NSRect(x: 69, y: 30, width: width - 190, height: 16)
        closeButton.frame = NSRect(x: width - 14 - 26, y: 16, width: 26, height: 26)
        settingsButton.frame = NSRect(x: closeButton.frame.minX - 30, y: 16, width: 26, height: 26)
        agentsButton.frame = NSRect(x: settingsButton.frame.minX - 30, y: 16, width: 26, height: 26)
        claudeButton.frame = NSRect(x: agentsButton.frame.minX - 30, y: 16, width: 26, height: 26)
        separator.frame = NSRect(x: 0, y: 57, width: width, height: 1)

        let composerHeight = min(132, max(44, composerText.contentHeight + 20))
        composer.frame = NSRect(x: 12, y: height - 12 - composerHeight, width: width - 24, height: composerHeight)
        let buttonSize: CGFloat = 28
        let buttonY = composerHeight - 8 - buttonSize
        sendButton.frame = NSRect(x: composer.bounds.width - 8 - buttonSize, y: buttonY, width: buttonSize, height: buttonSize)
        voiceButton.frame = NSRect(x: sendButton.frame.minX - 4 - buttonSize, y: buttonY, width: buttonSize, height: buttonSize)
        screenshotButton.frame = NSRect(x: voiceButton.frame.minX - 2 - buttonSize, y: buttonY, width: buttonSize, height: buttonSize)
        composerScroll.frame = NSRect(x: 12, y: 10, width: screenshotButton.frame.minX - 18, height: composerHeight - 20)

        var transcriptBottom = composer.frame.minY - 6
        if !attachmentChip.isHidden {
            let chipWidth = attachmentChip.preferredWidth
            attachmentChip.frame = NSRect(x: 16, y: composer.frame.minY - 32, width: chipWidth, height: 26)
            transcriptBottom = attachmentChip.frame.minY - 6
        }
        scrollView.frame = NSRect(x: 0, y: 58, width: width, height: max(40, transcriptBottom - 58))
        claudeSessionsView.frame = scrollView.frame
        layoutTranscript()
    }

    private func layoutTranscript() {
        let width = scrollView.contentSize.width
        let side: CGFloat = 14
        var y: CGFloat = 14
        var previousRole: ChatRole?
        for (index, bubble) in bubbleViews.enumerated() where messages.indices.contains(index) {
            let role = messages[index].role
            if let previousRole { y += previousRole == role ? 4 : 10 }
            let maxWidth = floor((width - side * 2) * (role == .user ? 0.8 : 0.9))
            let size = bubble.fittingSize(maxWidth: maxWidth)
            let x = role == .user ? width - side - size.width : side
            bubble.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            y += size.height
            previousRole = role
        }

        let showsChips = messages.count == 1 && !isThinking
        suggestionChips.forEach { $0.isHidden = !showsChips }
        if showsChips {
            y += 12
            var x = side
            for chip in suggestionChips {
                let chipWidth = chip.preferredWidth
                if x + chipWidth > width - side {
                    x = side
                    y += 36
                }
                chip.frame = NSRect(x: x, y: y, width: chipWidth, height: 28)
                x += chipWidth + 8
            }
            y += 28
        }
        y += 14
        transcript.frame = NSRect(x: 0, y: 0, width: width, height: max(y, scrollView.contentSize.height))
    }

    private func scrollToBottom() {
        layoutSubtreeIfNeeded()
        let maxY = max(0, transcript.frame.height - scrollView.contentSize.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Configuration

    private func configureHeader() {
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = StickmanStyle.primaryText
        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.textColor = StickmanStyle.secondaryText
        statusLabel.lineBreakMode = .byTruncatingTail

        agentsButton.target = self
        agentsButton.action = #selector(agentsButtonPressed)
        claudeButton.target = self
        claudeButton.action = #selector(claudeButtonPressed)
        settingsButton.target = self
        settingsButton.action = #selector(settingsButtonPressed)
        closeButton.target = self
        closeButton.action = #selector(closeButtonPressed)

        [avatar, titleLabel, statusDot, statusLabel, claudeButton, agentsButton, settingsButton, closeButton, separator].forEach(addSubview)
    }

    private func configureTranscript() {
        scrollView.documentView = transcript
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        addSubview(scrollView)
        claudeSessionsView.isHidden = true
        claudeSessionsView.onClose = { [weak self] in self?.hideClaudeSessions() }
        claudeSessionsView.onOpen = { session in ClaudeCodeService.shared.open(session) }
        claudeSessionsView.onShowOutput = { [weak self] session in self?.showOutput(of: session) }
        claudeSessionsView.onStop = { [weak self] session in self?.stop(session) }
        addSubview(claudeSessionsView)

        suggestionChips = Self.suggestions.map { title in
            let chip = StickmanChipButton(title: title)
            chip.target = self
            chip.action = #selector(suggestionPressed(_:))
            transcript.addSubview(chip)
            return chip
        }
    }

    private func configureComposer() {
        composerText.onSubmit = { [weak self] in self?.sendCurrentMessage() }
        composerText.onTextChange = { [weak self] in
            self?.refreshSendButton()
            self?.needsLayout = true
        }
        composerText.onFocusChange = { [weak self] focused in self?.composer.isFocused = focused }

        composerScroll.documentView = composerText
        composerScroll.drawsBackground = false
        composerScroll.hasVerticalScroller = true
        composerScroll.autohidesScrollers = true
        composerScroll.scrollerStyle = .overlay
        composerScroll.borderType = .noBorder
        composerText.minSize = NSSize(width: 0, height: 0)
        composerText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        composerText.isVerticallyResizable = true
        composerText.isHorizontallyResizable = false
        composerText.autoresizingMask = [.width]
        composerText.textContainer?.widthTracksTextView = true

        screenshotButton.target = self
        screenshotButton.action = #selector(screenshotButtonPressed)
        voiceButton.target = self
        voiceButton.action = #selector(voiceButtonPressed)
        sendButton.target = self
        sendButton.action = #selector(sendButtonPressed)
        sendButton.fill = .accent

        attachmentChip.isHidden = true
        attachmentChip.onRemove = { [weak self] in
            self?.pendingScreenshot = nil
            self?.setStatus("Ready", tone: .ready)
        }

        [composerScroll, screenshotButton, voiceButton, sendButton].forEach(composer.addSubview)
        addSubview(composer)
        addSubview(attachmentChip)
        refreshSendButton()
    }

    private func refreshSendButton() {
        sendButton.isEnabled = !composerText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isThinking
    }

    private func setStatus(_ text: String, tone: StatusTone) {
        statusLabel.stringValue = text
        statusDot.color = tone.color
        statusDot.isPulsing = tone == .busy || tone == .listening
    }

    // MARK: Public API

    func focusInput() {
        guard !isHidden, let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(composerText)
        composerText.setSelectedRange(NSRange(location: (composerText.string as NSString).length, length: 0))
    }

    func prepareScreenContext() {
        do {
            pendingScreenshot = try captureScreenWithoutStickman()
            setStatus("I can see your screen for the next question", tone: .ready)
        } catch {
            setStatus("Screen context needs permission", tone: .problem)
        }
    }

    func showAgentStatus() {
        messages.append(ChatMessage(role: .assistant, content: BackgroundAgentCoordinator.shared.compactSummary))
        renderMessages()
    }

    // MARK: Claude Code

    func showClaudeSessions() {
        claudeSessionsView.isHidden = false
        scrollView.isHidden = true
        claudeButton.isToggled = true
    }

    private func hideClaudeSessions() {
        guard !claudeSessionsView.isHidden else { return }
        claudeSessionsView.isHidden = true
        scrollView.isHidden = false
        claudeButton.isToggled = false
        scrollToBottom()
    }

    @objc private func claudeButtonPressed() {
        claudeSessionsView.isHidden ? showClaudeSessions() : hideClaudeSessions()
    }

    private func refreshClaudeButton() {
        let active = ClaudeCodeService.shared.activeCount
        claudeButton.badgeCount = active
        claudeButton.toolTip = active == 0 ? "Claude Code sessions" : "Claude Code sessions · \(active) working"
    }

    /// Hands a task to Claude Code on the personal profile, in the background or in the cloud.
    func startClaudeCode(_ request: ClaudeCodeRequest) {
        messages.append(ChatMessage(role: .assistant, content: ""))
        let index = messages.count - 1
        isThinking = true
        setStatus(request.runsInCloud ? "Starting a cloud session…" : request.usesComputer ? "Starting Claude with computer use…" : "Starting Claude Code…", tone: .busy)
        renderMessages()
        let windowTitle = DesktopContextProvider.shared.currentContext().windowTitle

        Task { @MainActor in
            let service = ClaudeCodeService.shared
            var reply: String
            var failed = false
            do {
                let (project, task) = try service.resolve(request, windowTitle: windowTitle)
                let name = ClaudeCodeCommandParser.sessionName(for: task)
                if request.runsInCloud {
                    let url = try await service.startCloud(task: task, in: project)
                    reply = "Started a cloud session for **\(name)** in `\(project.name)`."
                    reply += url.map { " [Open it on claude.ai](\($0.absoluteString))" } ?? " You'll find it at claude.ai/code."
                } else {
                    _ = try await service.startBackground(task: task, in: project, usesComputer: request.usesComputer)
                    if request.usesComputer {
                        reply = "Started **\(name)** on Opus with computer use. I'll ask before Claude touches a new app, and you can press esc anytime to stop it."
                    } else {
                        reply = "Started **\(name)** in `\(project.name)`. I'll tell you when it's done."
                    }
                    StickmanTaskAnimationController.play(.spawnAgent)
                }
            } catch {
                reply = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                failed = true
            }
            if self.messages.indices.contains(index) { self.messages[index].content = reply }
            self.isThinking = false
            self.setStatus(failed ? "Claude Code couldn't start" : "Ready", tone: failed ? .problem : .ready)
            if failed { self.onErrorMoment?() }
            self.renderMessages()
            self.refreshClaudeButton()
        }
    }

    private func presentClaudeUpdate(_ session: ClaudeCodeSession, needsAttention: Bool) {
        let text: String
        if needsAttention {
            let reason = session.waitingFor.map { " (\($0))" } ?? ""
            text = "**\(session.name)** needs you in `\(session.projectName)`\(reason). Open it from the terminal icon above."
        } else if session.state == "failed" {
            text = "**\(session.name)** hit a problem in `\(session.projectName)`. Open it to see what happened."
        } else {
            text = "Claude finished **\(session.name)** in `\(session.projectName)`."
        }
        messages.append(ChatMessage(role: .assistant, content: text))
        renderMessages()
        refreshClaudeButton()
    }

    private func showOutput(of session: ClaudeCodeSession) {
        Task { @MainActor in
            let text: String
            do {
                let output = Self.cleanTerminalOutput(try await ClaudeCodeService.shared.logs(for: session))
                text = output.isEmpty ? "**\(session.name)** hasn't printed anything yet." : "Latest from **\(session.name)**:\n\n\(output)"
            } catch {
                text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            self.hideClaudeSessions()
            self.messages.append(ChatMessage(role: .assistant, content: text))
            self.renderMessages()
        }
    }

    private func stop(_ session: ClaudeCodeSession) {
        Task { @MainActor in
            do {
                try await ClaudeCodeService.shared.stop(session)
            } catch {
                self.hideClaudeSessions()
                self.messages.append(ChatMessage(role: .assistant, content: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
                self.renderMessages()
            }
        }
    }

    /// Strips terminal escape codes and keeps the last few lines.
    nonisolated static func cleanTerminalOutput(_ raw: String) -> String {
        let withoutEscapes = raw
            .replacingOccurrences(of: #"\x{1B}\][^\x{07}\x{1B}]*(?:\x{07}|\x{1B}\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x{1B}[@-_]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = withoutEscapes.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let tail = lines.suffix(24).joined(separator: "\n")
        return tail.count > 2000 ? "…" + String(tail.suffix(2000)) : tail
    }

    /// Sample conversation for the offscreen panel preview.
    func loadPreviewConversation() {
        messages = [
            ChatMessage(role: .assistant, content: "Hey! What are we working on?"),
            ChatMessage(role: .user, content: "Can you check what's due this week?"),
            ChatMessage(role: .assistant, content: "Three things on your plate:\n\n- **Finance 401** problem set, due *Thursday*\n- Reading for Law & Society\n- Mandarin vocab quiz on Friday\n\nWant me to block time for the problem set?"),
            ChatMessage(role: .user, content: "Yes, tomorrow at 3"),
            ChatMessage(role: .assistant, content: "")
        ]
        isThinking = true
        pendingScreenshot = ScreenshotAttachment(dataURL: "", capturedAt: Date())
        composerText.string = ""
        setStatus("Thinking…", tone: .busy)
        renderMessages()
    }

    // MARK: Actions

    @objc private func sendButtonPressed() { sendCurrentMessage() }

    @objc private func closeButtonPressed() { onClose?() }

    @objc private func settingsButtonPressed() { onOpenSettings?() }

    @objc private func agentsButtonPressed() { showAgentStatus() }

    @objc private func suggestionPressed(_ sender: StickmanChipButton) {
        composerText.string = sender.title
        sendCurrentMessage()
    }

    @objc private func voiceButtonPressed() {
        if isVoiceModeActive {
            stopVoiceMode()
        } else {
            startVoiceMode()
        }
    }

    @objc private func screenshotButtonPressed() {
        if pendingScreenshot != nil {
            pendingScreenshot = nil
            setStatus("Ready", tone: .ready)
            return
        }
        do {
            pendingScreenshot = try captureScreenWithoutStickman()
            setStatus("Screenshot attached to your next message", tone: .ready)
            onSuccessMoment?()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            messages.append(ChatMessage(role: .assistant, content: message))
            setStatus("Screenshot failed", tone: .problem)
            onErrorMoment?()
            renderMessages()
        }
    }

    private func sendCurrentMessage() {
        guard !isThinking else { return }

        let text = composerText.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if ["/claude", "/code", "/sessions"].contains(text.lowercased()) {
            composerText.string = ""
            composerText.onTextChange?()
            showClaudeSessions()
            return
        }

        messages.append(ChatMessage(role: .user, content: text))
        composerText.string = ""
        composerText.onTextChange?()
        hideClaudeSessions()
        renderMessages()

        if let claudeRequest = ClaudeCodeCommandParser.parse(text) {
            startClaudeCode(claudeRequest)
            return
        }

        if let actionResult = ActionRunner.shared.handleIfAction(text) {
            messages.append(ChatMessage(role: .assistant, content: ""))
            onActivityChanged?(.working)
            setAssistantReply(actionResult.userVisibleMessage)
            finishStreaming()
            return
        }

        if isVoiceModeActive {
            messages.append(ChatMessage(role: .assistant, content: ""))
            voiceAssistantMessageIndex = messages.count - 1
            renderMessages()
            onActivityChanged?(.speaking)
            realtimeVoiceClient?.sendText(text)
            return
        }

        messages.append(ChatMessage(role: .assistant, content: ""))
        fetchAssistantReply()
    }

    func startVoiceMode() {
        guard !isVoiceModeActive else { return }

        isVoiceModeActive = true
        voiceButton.fill = .destructive
        voiceButton.setSymbol("waveform", label: "Stop voice mode")
        setStatus("Starting voice…", tone: .listening)
        onActivityChanged?(.listening)

        let realtimeVoiceClient = realtimeVoiceClient ?? RealtimeVoiceClient()
        realtimeVoiceClient.delegate = self
        self.realtimeVoiceClient = realtimeVoiceClient

        voiceTask?.cancel()
        voiceTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await realtimeVoiceClient.start()
            } catch {
                await MainActor.run {
                    self.handleVoiceError(error)
                    self.stopVoiceMode()
                }
            }
        }
    }

    private func stopVoiceMode() {
        isVoiceModeActive = false
        voiceAssistantMessageIndex = nil
        voiceTask?.cancel()
        voiceTask = nil
        realtimeVoiceClient?.stop()
        voiceButton.fill = .plain
        voiceButton.setSymbol("mic", label: "Start voice mode")
        setStatus("Ready", tone: .ready)
        onActivityChanged?(.quiet)
        renderMessages()
    }

    // MARK: Transcript

    private func renderMessages() {
        while bubbleViews.count < messages.count {
            let message = messages[bubbleViews.count]
            let bubble = MessageBubbleView(isUser: message.role == .user)
            transcript.addSubview(bubble)
            bubbleViews.append(bubble)
        }
        while bubbleViews.count > messages.count {
            bubbleViews.removeLast().removeFromSuperview()
        }
        for (index, message) in messages.enumerated() {
            let awaitingVoice = isVoiceModeActive && index == voiceAssistantMessageIndex
            let pending = message.role == .assistant && message.content.isEmpty && (isThinking || awaitingVoice)
            bubbleViews[index].update(text: message.content, pending: pending)
        }
        refreshSendButton()
        needsLayout = true
        scrollToBottom()
    }

    private func installAgentObservers() {
        let changeObserver = NotificationCenter.default.addObserver(
            forName: .stickmanAgentTasksDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAgentButton()
        }
        let completionObserver = NotificationCenter.default.addObserver(
            forName: .stickmanAgentTaskDidComplete,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let task = notification.userInfo?["task"] as? StickmanAgentTask else { return }
            self?.presentCompletedAgent(task)
        }
        let claudeChange = NotificationCenter.default.addObserver(
            forName: .stickmanClaudeSessionsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshClaudeButton()
        }
        let claudeFinish = NotificationCenter.default.addObserver(
            forName: .stickmanClaudeSessionDidFinish,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let session = notification.userInfo?["session"] as? ClaudeCodeSession else { return }
            self?.presentClaudeUpdate(session, needsAttention: notification.userInfo?["needsAttention"] as? Bool ?? false)
        }
        agentObservers = [changeObserver, completionObserver, claudeChange, claudeFinish]
    }

    private func refreshAgentButton() {
        let activeCount = BackgroundAgentCoordinator.shared.activeCount
        agentsButton.badgeCount = activeCount
        agentsButton.toolTip = activeCount == 0 ? "Background agents" : "Background agents · \(activeCount) working"
    }

    private func presentCompletedAgent(_ task: StickmanAgentTask) {
        let result = task.result ?? task.errorMessage ?? "The agent finished without a result."
        let boundedResult = result.count > 1800 ? String(result.prefix(1797)) + "…" : result
        let browserNote = task.openedURLs.isEmpty ? "" : "\n\nOpened \(task.openedURLs.count) useful Chrome tab\(task.openedURLs.count == 1 ? "" : "s")."
        messages.append(ChatMessage(
            role: .assistant,
            content: "**Agent \(task.id) finished.**\n\n\(boundedResult)\(browserNote)"
        ))
        onSuccessMoment?()
        renderMessages()
    }

    // MARK: AI replies

    private func fetchAssistantReply() {
        if pendingScreenshot == nil, automaticallySharesScreenForQuestions {
            pendingScreenshot = try? captureScreenWithoutStickman()
        }
        isThinking = true
        setStatus("Thinking…", tone: .busy)
        onActivityChanged?(.thinking)
        scheduleResponseTimeout()
        renderMessages()

        let conversation = messages.dropLast().filter { !$0.content.isEmpty }
        responseTask?.cancel()
        responseTask = Task { [weak self] in
            guard let self else { return }

            do {
                let desktopContext = DesktopContextProvider.shared.currentContext()
                let screenshot = self.pendingScreenshot
                let reply = try await aiClient.reply(
                    messages: Array(conversation),
                    desktopContext: desktopContext,
                    screenshot: screenshot
                )

                await MainActor.run {
                    self.pendingScreenshot = nil
                    self.setAssistantReply(reply)
                    self.finishStreaming()
                }
            } catch {
                await MainActor.run {
                    self.finishStreaming(error: error)
                }
            }
        }
    }

    private func setAssistantReply(_ reply: String) {
        guard messages.indices.contains(messages.count - 1) else { return }
        let parsed = parseGuidance(in: reply)
        messages[messages.count - 1].content = sanitizeAssistantReply(parsed.text)
        onScreenGuidance?(parsed.markers)
        renderMessages()
    }

    private func setVoiceAssistantReply(_ reply: String, isFinal: Bool = false) {
        let sanitized = sanitizeAssistantReply(reply)

        if let index = voiceAssistantMessageIndex, messages.indices.contains(index) {
            messages[index].content = sanitized
        } else {
            messages.append(ChatMessage(role: .assistant, content: sanitized))
            voiceAssistantMessageIndex = messages.count - 1
        }

        if isFinal {
            voiceAssistantMessageIndex = nil
        }

        renderMessages()
    }

    private func finishStreaming(error: Error? = nil) {
        responseTimeoutTimer?.invalidate()
        responseTimeoutTimer = nil

        var tone = StatusTone.ready
        if let error {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if messages.last?.role == .assistant, messages.last?.content.isEmpty == true {
                messages[messages.count - 1].content = message
            } else {
                messages.append(ChatMessage(role: .assistant, content: message))
            }
            tone = .problem
            onErrorMoment?()
        } else if messages.last?.role == .assistant, messages.last?.content.isEmpty == true {
            messages[messages.count - 1].content = "I finished the request, but the model did not return any text."
        } else {
            onSuccessMoment?()
        }

        isThinking = false
        setStatus(tone == .problem ? "Something went wrong" : "Ready", tone: tone)
        onActivityChanged?(.quiet)
        renderMessages()
    }

    private func scheduleResponseTimeout() {
        responseTimeoutTimer?.invalidate()
        responseTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            guard let self, self.isThinking else { return }
            self.responseTask?.cancel()
            self.finishStreaming(error: AIClientError.timedOut)
        }

        if let responseTimeoutTimer {
            RunLoop.main.add(responseTimeoutTimer, forMode: .common)
        }
    }

    private static func randomWelcomeMessage() -> String {
        [
            "Hey! How can I help?",
            "Hey, I'm here. What are we working on?",
            "Hi! What can I help with?",
            "Ready when you are.",
            "Hey! Want me to take a look at something?"
        ].randomElement() ?? "Hey! How can I help?"
    }

    private func sanitizeAssistantReply(_ reply: String) -> String {
        reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var automaticallySharesScreenForQuestions: Bool {
        if UserDefaults.standard.object(forKey: "StickmanAutoScreenContext") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "StickmanAutoScreenContext")
    }

    /// Hides every Stickman window while the screen is captured, so he never photobombs it.
    private func captureScreenWithoutStickman() throws -> ScreenshotAttachment {
        let visibleWindows = NSApp.windows.filter { $0.isVisible && $0.alphaValue > 0 }
        let previousAlphas = visibleWindows.map(\.alphaValue)
        visibleWindows.forEach { $0.alphaValue = 0 }
        CATransaction.flush()
        defer { zip(visibleWindows, previousAlphas).forEach { $0.alphaValue = $1 } }
        return try ScreenshotCaptureService.shared.captureMainDisplay()
    }

    private func parseGuidance(in reply: String) -> (text: String, markers: [ScreenGuidanceMarker]) {
        let pattern = #"<stickman-guide\s+x=[\"']([0-9.]+)[\"']\s+y=[\"']([0-9.]+)[\"']\s+label=[\"']([^\"']{0,80})[\"']\s*/?>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (reply, [])
        }
        let range = NSRange(reply.startIndex ..< reply.endIndex, in: reply)
        let matches = regex.matches(in: reply, range: range)
        let markers = matches.compactMap { match -> ScreenGuidanceMarker? in
            guard match.numberOfRanges == 4,
                  let xRange = Range(match.range(at: 1), in: reply),
                  let yRange = Range(match.range(at: 2), in: reply),
                  let labelRange = Range(match.range(at: 3), in: reply),
                  let x = Double(reply[xRange]),
                  let y = Double(reply[yRange])
            else { return nil }
            return ScreenGuidanceMarker(
                normalizedPoint: CGPoint(x: max(0, min(1, x)), y: max(0, min(1, y))),
                label: String(reply[labelRange])
            )
        }
        let cleaned = regex.stringByReplacingMatches(in: reply, range: range, withTemplate: "")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, markers)
    }

    // MARK: Voice delegate

    func realtimeVoiceClient(_ client: RealtimeVoiceClient, didChangeStatus status: String) {
        guard isVoiceModeActive else { return }
        setStatus(status, tone: .listening)
    }

    func realtimeVoiceClientDidDetectUserSpeech(_ client: RealtimeVoiceClient) {
        guard isVoiceModeActive else { return }
        messages.append(ChatMessage(role: .user, content: "🎙 Voice message"))
        messages.append(ChatMessage(role: .assistant, content: ""))
        voiceAssistantMessageIndex = messages.count - 1
        setStatus("Listening…", tone: .listening)
        onActivityChanged?(.listening)
        renderMessages()
    }

    func realtimeVoiceClient(_ client: RealtimeVoiceClient, didReceiveAssistantTranscriptDelta delta: String) {
        guard isVoiceModeActive else { return }
        let current = voiceAssistantMessageIndex.flatMap { messages.indices.contains($0) ? messages[$0].content : nil } ?? ""
        setVoiceAssistantReply(current + delta)
        setStatus("Talking…", tone: .speaking)
        onActivityChanged?(.speaking)
    }

    func realtimeVoiceClient(_ client: RealtimeVoiceClient, didFinishAssistantTranscript transcript: String?) {
        guard isVoiceModeActive else { return }

        if let transcript, !transcript.isEmpty {
            setVoiceAssistantReply(transcript, isFinal: true)
        } else if let index = voiceAssistantMessageIndex,
                  messages.indices.contains(index),
                  messages[index].content.isEmpty {
            messages[index].content = "I answered out loud."
            voiceAssistantMessageIndex = nil
            renderMessages()
        }

        setStatus("Voice on. Talk to Stickman.", tone: .listening)
        onActivityChanged?(.listening)
    }

    func realtimeVoiceClient(_ client: RealtimeVoiceClient, didFailWithError error: Error) {
        handleVoiceError(error)
        stopVoiceMode()
    }

    @MainActor
    func realtimeVoiceClient(_ client: RealtimeVoiceClient, executeFunction name: String, arguments: [String: Any]) -> String {
        switch name {
        case "spawn_background_agent":
            guard let prompt = arguments["task"] as? String, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return #"{"error":"A task is required."}"#
            }
            let opensLinks = arguments["open_browser_links"] as? Bool ?? false
            let task = BackgroundAgentCoordinator.shared.spawn(prompt: prompt, opensBrowserLinks: opensLinks)
            StickmanTaskAnimationController.play(.spawnAgent)
            return #"{"status":"started","agent_id":"\#(task.id)","message":"The background agent is working."}"#

        case "open_chrome_tab":
            guard let destination = arguments["destination"] as? String else {
                return #"{"error":"A destination is required."}"#
            }
            do {
                if let url = BrowserControlService.resolvedURL(from: destination) {
                    _ = try BrowserControlService.shared.openChromeTab(url)
                    StickmanTaskAnimationController.play(.openBrowserTab)
                    return #"{"status":"opened","url":"\#(url.absoluteString)"}"#
                }
                _ = try BrowserControlService.shared.searchGoogle(for: destination)
                StickmanTaskAnimationController.play(.openBrowserTab)
                return #"{"status":"opened_search","query":"\#(Self.jsonEscaped(destination))"}"#
            } catch {
                return #"{"error":"\#(Self.jsonEscaped((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))"}"#
            }

        case "start_claude_code":
            guard let task = arguments["task"] as? String, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return #"{"error":"A task is required."}"#
            }
            let project = (arguments["project"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let request = ClaudeCodeRequest(
                task: task,
                explicitProject: project.isEmpty ? nil : project,
                trailingProject: nil,
                taskWithoutTrailingProject: nil,
                runsInCloud: arguments["cloud"] as? Bool ?? false,
                usesComputer: arguments["computer_use"] as? Bool ?? false
            )
            if !project.isEmpty, ClaudeCodeService.shared.project(named: project) == nil {
                let known = ClaudeCodeService.shared.projects.map(\.name).joined(separator: ", ")
                return #"{"error":"Unknown project. Known projects: \#(Self.jsonEscaped(known))"}"#
            }
            startClaudeCode(request)
            return #"{"status":"starting","message":"Claude Code is starting. Stickman will report when it finishes."}"#

        case "list_claude_code_sessions":
            let summary = ClaudeCodeService.shared.sessions.prefix(8)
                .map { "\($0.name) in \($0.projectName): \($0.statusTitle)" }
                .joined(separator: "; ")
            return #"{"sessions":"\#(Self.jsonEscaped(summary.isEmpty ? "No Claude Code sessions." : summary))"}"#

        case "list_chrome_tabs":
            return #"{"tabs":"\#(Self.jsonEscaped(BrowserControlService.shared.summary()))"}"#

        case "activate_chrome_tab":
            guard let query = arguments["query"] as? String else { return #"{"error":"A tab query is required."}"# }
            do {
                let tab = try BrowserControlService.shared.activateTab(matching: query)
                StickmanTaskAnimationController.play(.openBrowserTab)
                return #"{"status":"activated","title":"\#(Self.jsonEscaped(tab.title))","url":"\#(Self.jsonEscaped(tab.url))"}"#
            } catch {
                return #"{"error":"\#(Self.jsonEscaped((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))"}"#
            }

        default:
            return #"{"error":"Unknown Stickman tool."}"#
        }
    }

    private func handleVoiceError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        messages.append(ChatMessage(role: .assistant, content: message))
        setStatus("Voice failed", tone: .problem)
        onErrorMoment?()
        renderMessages()
    }

    private static func jsonEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

// MARK: - Subviews

private final class TranscriptDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class HairlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        StickmanStyle.hairline.setFill()
        bounds.fill()
    }
}

private final class StatusDotView: NSView {
    var color: NSColor = .systemGreen { didSet { needsDisplay = true } }
    var isPulsing = false { didSet { updatePulse() } }
    private var timer: Timer?
    private var phase: CGFloat = 0

    deinit { timer?.invalidate() }

    override func draw(_ dirtyRect: NSRect) {
        let alpha = isPulsing ? 0.45 + 0.55 * (0.5 + 0.5 * sin(phase)) : 1
        color.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }

    private func updatePulse() {
        timer?.invalidate()
        timer = nil
        needsDisplay = true
        guard isPulsing else { return }
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.phase += 0.32
            self?.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

private final class MessageBubbleView: NSView {
    private static let horizontalPadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 8

    private let isUser: Bool
    private let label = NSTextField(wrappingLabelWithString: "")
    private let typing = TypingIndicatorView()
    private var isPending = false
    private var renderedText: String?

    init(isUser: Bool) {
        self.isUser = isUser
        super.init(frame: .zero)
        label.isSelectable = true
        label.allowsEditingTextAttributes = true
        label.drawsBackground = false
        label.isBezeled = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        addSubview(label)
        addSubview(typing)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func update(text: String, pending: Bool) {
        guard text != renderedText || pending != isPending else { return }
        renderedText = text
        isPending = pending
        label.isHidden = pending
        typing.isHidden = !pending
        typing.isAnimating = pending
        let font = NSFont.systemFont(ofSize: 13)
        if isUser {
            label.attributedStringValue = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        } else {
            label.attributedStringValue = StickmanMarkdown.render(text, font: font, color: .labelColor)
        }
        needsDisplay = true
    }

    func fittingSize(maxWidth: CGFloat) -> NSSize {
        if isPending { return NSSize(width: 58, height: 32) }
        let textWidth = max(20, maxWidth - Self.horizontalPadding * 2)
        let measured = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude)) ?? .zero
        return NSSize(
            width: ceil(min(textWidth, measured.width)) + Self.horizontalPadding * 2,
            height: ceil(measured.height) + Self.verticalPadding * 2
        )
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: Self.horizontalPadding, dy: Self.verticalPadding)
        typing.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(16, bounds.height / 2)
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        (isUser ? NSColor.controlAccentColor : StickmanStyle.assistantBubble).setFill()
        path.fill()
    }
}

private final class TypingIndicatorView: NSView {
    var isAnimating = false { didSet { updateTimer() } }
    private var timer: Timer?
    private var phase: CGFloat = 0

    deinit { timer?.invalidate() }

    override func draw(_ dirtyRect: NSRect) {
        let spacing: CGFloat = 9
        let start = bounds.midX - spacing
        for index in 0 ..< 3 {
            let wave = 0.5 + 0.5 * sin(phase - CGFloat(index) * 0.9)
            NSColor.secondaryLabelColor.withAlphaComponent(0.35 + 0.65 * wave).setFill()
            let size: CGFloat = 6
            let lift = wave * 2
            NSBezierPath(ovalIn: NSRect(x: start + CGFloat(index) * spacing - size / 2, y: bounds.midY - size / 2 - lift, width: size, height: size)).fill()
        }
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard isAnimating else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.phase += 0.28
            self?.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

private final class ComposerContainerView: NSView {
    var isFocused = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 20, yRadius: 20)
        StickmanStyle.fieldFill.setFill()
        path.fill()
        (isFocused ? NSColor.controlAccentColor.withAlphaComponent(0.55) : StickmanStyle.fieldStroke).setStroke()
        path.lineWidth = isFocused ? 1.5 : 1
        path.stroke()
    }
}

private final class ComposerTextView: NSTextView {
    var placeholder = "Ask Stickman anything"
    var onSubmit: (() -> Void)?
    var onTextChange: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    convenience init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        font = .systemFont(ofSize: 13)
        textColor = .labelColor
        insertionPointColor = .labelColor
        textContainerInset = NSSize(width: 0, height: 4)
        textContainer?.lineFragmentPadding = 2
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        typingAttributes = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
    }

    var contentHeight: CGFloat {
        guard let layoutManager, let textContainer else { return 18 }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        return max(18, used) + textContainerInset.height * 2
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        // While an input method is composing (Pinyin, Japanese), Return confirms the candidate.
        if isReturn, !hasMarkedText() {
            if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onSubmit?()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        onTextChange?()
        needsDisplay = true
    }

    /// NSTextView maps Escape to word completion; send it to the panel so it closes instead.
    override func cancelOperation(_ sender: Any?) {
        window?.cancelOperation(sender)
    }

    override var string: String {
        didSet { needsDisplay = true }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y)
        (placeholder as NSString).draw(at: origin, withAttributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.placeholderTextColor
        ])
    }
}

private final class AttachmentChipView: NSView {
    var onRemove: (() -> Void)?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "Screen attached")
    private let removeButton = StickmanIconButton(symbol: "xmark", label: "Remove screenshot", pointSize: 9, weight: .bold)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        icon.contentTintColor = .controlAccentColor
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = StickmanStyle.primaryText
        removeButton.target = self
        removeButton.action = #selector(removePressed)
        [icon, label, removeButton].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    var preferredWidth: CGFloat { 30 + label.intrinsicContentSize.width + 26 }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 9, y: 6, width: 14, height: 14)
        label.frame = NSRect(x: 28, y: 5, width: label.intrinsicContentSize.width + 2, height: 16)
        removeButton.frame = NSRect(x: bounds.width - 23, y: 3, width: 20, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.3).setStroke()
        path.stroke()
    }

    @objc private func removePressed() { onRemove?() }
}
