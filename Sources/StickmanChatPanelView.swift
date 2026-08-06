import AppKit

final class StickmanChatPanelView: NSView, NSTextFieldDelegate, RealtimeVoiceClientDelegate {
    var onOpenSettings: (() -> Void)?
    var onActivityChanged: ((StickmanView.Activity) -> Void)?
    var onSuccessMoment: (() -> Void)?
    var onErrorMoment: (() -> Void)?
    var onScreenGuidance: (([ScreenGuidanceMarker]) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Stickman")
    private let subtitleLabel = NSTextField(labelWithString: "Ready when you are.")
    private let settingsButton = NSButton(title: "Settings", target: nil, action: nil)
    private let agentsButton = NSButton(title: "Agents", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let transcriptView = NSTextView()
    private let inputField = NSTextField()
    private let voiceButton = NSButton(title: "Voice", target: nil, action: nil)
    private let screenshotButton = NSButton(title: "Shot", target: nil, action: nil)
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let aiClient: AIClient = AIClientFactory.make()
    private var realtimeVoiceClient: RealtimeVoiceClient?
    private var responseTask: Task<Void, Never>?
    private var voiceTask: Task<Void, Never>?
    private var responseTimeoutTimer: Timer?
    private var isThinking = false
    private var isVoiceModeActive = false
    private var voiceAssistantMessageIndex: Int?
    private var pendingScreenshot: ScreenshotAttachment?
    private var agentObservers: [NSObjectProtocol] = []

    private var messages: [ChatMessage] = [
        ChatMessage(role: .assistant, content: StickmanChatPanelView.randomWelcomeMessage())
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        configureLabels()
        configureTranscript()
        configureInput()

        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(settingsButton)
        addSubview(agentsButton)
        addSubview(quitButton)
        addSubview(scrollView)
        addSubview(inputField)
        addSubview(voiceButton)
        addSubview(screenshotButton)
        addSubview(sendButton)
        installAgentObservers()
        refreshAgentButton()
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

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bubbleRect = speechBubbleRect
        let bubble = NSBezierPath(roundedRect: bubbleRect, xRadius: 18, yRadius: 18)
        let tailCenterY = min(bubbleRect.maxY - 40, max(bubbleRect.minY + 40, 98))
        bubble.move(to: NSPoint(x: bubbleRect.minX + 2, y: tailCenterY - 14))
        bubble.line(to: NSPoint(x: 0, y: tailCenterY))
        bubble.line(to: NSPoint(x: bubbleRect.minX + 2, y: tailCenterY + 13))
        bubble.close()

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: 4)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        AnthropicStyle.panel.setFill()
        bubble.fill()
        NSGraphicsContext.restoreGraphicsState()

        AnthropicStyle.line.setStroke()
        bubble.lineWidth = 1
        bubble.stroke()
    }

    override func layout() {
        super.layout()

        let bubble = speechBubbleRect
        let contentLeft = bubble.minX + 16
        let contentRight = bubble.maxX - 14
        let inputY = bubble.maxY - 44

        titleLabel.frame = NSRect(x: contentLeft, y: 14, width: bubble.width - 92, height: 22)
        quitButton.frame = NSRect(x: contentRight - 44, y: 13, width: 44, height: 24)
        subtitleLabel.frame = NSRect(x: contentLeft, y: 37, width: bubble.width - 32, height: 18)
        inputField.frame = NSRect(x: contentLeft, y: inputY, width: max(70, bubble.width - 224), height: 30)
        voiceButton.frame = NSRect(x: contentRight - 188, y: inputY, width: 56, height: 30)
        screenshotButton.frame = NSRect(x: contentRight - 128, y: inputY, width: 56, height: 30)
        sendButton.frame = NSRect(x: contentRight - 68, y: inputY, width: 68, height: 30)
        scrollView.frame = NSRect(
            x: contentLeft,
            y: 64,
            width: contentRight - contentLeft,
            height: max(40, inputY - 72)
        )
        settingsButton.frame = NSRect(x: bubble.minX + 4, y: bubble.maxY + 7, width: 74, height: 25)
        agentsButton.frame = NSRect(x: bubble.minX + 84, y: bubble.maxY + 7, width: 98, height: 25)
        transcriptView.frame = scrollView.bounds
        transcriptView.textContainer?.containerSize = NSSize(
            width: max(1, scrollView.bounds.width - 16),
            height: CGFloat.greatestFiniteMagnitude
        )
        transcriptView.textContainer?.widthTracksTextView = true
    }

    func focusInput() {
        guard !isHidden, let window else { return }

        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(inputField)
        inputField.currentEditor()?.selectedRange = NSRange(location: inputField.stringValue.count, length: 0)
    }

    func prepareScreenContext() {
        do {
            pendingScreenshot = try captureScreenWithoutStickman()
            subtitleLabel.stringValue = "I can see the screen for your next question."
        } catch {
            subtitleLabel.stringValue = "Screen context needs permission."
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let event = NSApp.currentEvent,
              event.type == .keyDown,
              event.keyCode == 36
        else { return }
        sendCurrentMessage()
    }

    private func configureLabels() {
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = AnthropicStyle.ink
        titleLabel.backgroundColor = .clear

        subtitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = AnthropicStyle.mutedInk
        subtitleLabel.backgroundColor = .clear

        quitButton.target = self
        quitButton.action = #selector(quitButtonPressed)
        AnthropicStyle.configureDangerButton(quitButton)
        quitButton.toolTip = "Quit Stickman"

        settingsButton.target = self
        settingsButton.action = #selector(settingsButtonPressed)
        AnthropicStyle.configureSecondaryButton(settingsButton)
        settingsButton.toolTip = "Open Stickman settings"

        agentsButton.target = self
        agentsButton.action = #selector(agentsButtonPressed)
        AnthropicStyle.configureSecondaryButton(agentsButton)
        agentsButton.toolTip = "Show background agents"
    }

    private func configureTranscript() {
        transcriptView.isEditable = false
        transcriptView.isSelectable = true
        transcriptView.drawsBackground = true
        transcriptView.backgroundColor = AnthropicStyle.inset
        transcriptView.textColor = AnthropicStyle.ink
        transcriptView.font = NSFont.systemFont(ofSize: 13)
        transcriptView.textContainerInset = NSSize(width: 10, height: 10)
        transcriptView.isVerticallyResizable = true
        transcriptView.isHorizontallyResizable = false
        transcriptView.autoresizingMask = [.width]

        scrollView.documentView = transcriptView
        scrollView.drawsBackground = true
        scrollView.backgroundColor = AnthropicStyle.inset
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 10
        scrollView.layer?.borderColor = AnthropicStyle.line.cgColor
        scrollView.layer?.borderWidth = 1
    }

    private func configureInput() {
        inputField.placeholderString = "Message Stickman"
        inputField.delegate = self
        inputField.target = self
        inputField.action = #selector(sendButtonPressed)
        inputField.font = NSFont.systemFont(ofSize: 13)
        AnthropicStyle.configureInputField(inputField)
        inputField.placeholderAttributedString = NSAttributedString(
            string: "Message Stickman",
            attributes: [
                .foregroundColor: AnthropicStyle.mutedInk,
                .font: NSFont.systemFont(ofSize: 13)
            ]
        )
        inputField.attributedStringValue = NSAttributedString(
            string: "",
            attributes: [
                .foregroundColor: AnthropicStyle.ink,
                .font: NSFont.systemFont(ofSize: 13)
            ]
        )

        screenshotButton.target = self
        screenshotButton.action = #selector(screenshotButtonPressed)
        AnthropicStyle.configureSecondaryButton(screenshotButton)
        screenshotButton.toolTip = "Attach a screenshot to Stickman's next reply"

        voiceButton.target = self
        voiceButton.action = #selector(voiceButtonPressed)
        AnthropicStyle.configureSecondaryButton(voiceButton)
        voiceButton.toolTip = "Start or stop live voice mode"

        sendButton.target = self
        sendButton.action = #selector(sendButtonPressed)
        AnthropicStyle.configurePrimaryButton(sendButton)
    }

    @objc private func sendButtonPressed() {
        sendCurrentMessage()
    }

    @objc private func voiceButtonPressed() {
        if isVoiceModeActive {
            stopVoiceMode()
        } else {
            startVoiceMode()
        }
    }

    @objc private func quitButtonPressed() {
        NSApp.terminate(nil)
    }

    @objc private func settingsButtonPressed() {
        onOpenSettings?()
    }

    @objc private func agentsButtonPressed() {
        showAgentStatus()
    }

    @objc private func screenshotButtonPressed() {
        do {
            pendingScreenshot = try captureScreenWithoutStickman()
            messages.append(ChatMessage(role: .assistant, content: "Screenshot attached. Ask me what you want me to look at."))
            subtitleLabel.stringValue = "Screenshot ready."
            onSuccessMoment?()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            messages.append(ChatMessage(role: .assistant, content: message))
            subtitleLabel.stringValue = "Screenshot failed."
            onErrorMoment?()
        }

        renderMessages()
    }

    private func sendCurrentMessage() {
        guard !isThinking else { return }

        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        messages.append(ChatMessage(role: .user, content: text))
        inputField.stringValue = ""
        renderMessages()

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
        renderMessages()
        fetchAssistantReply()
    }

    func startVoiceMode() {
        guard !isVoiceModeActive else { return }

        isVoiceModeActive = true
        voiceButton.title = "Stop"
        voiceButton.state = .on
        AnthropicStyle.configureDangerButton(voiceButton)
        subtitleLabel.stringValue = "Starting voice..."
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
        voiceButton.title = "Voice"
        voiceButton.state = .off
        AnthropicStyle.configureSecondaryButton(voiceButton)
        subtitleLabel.stringValue = "Ready when you are."
        onActivityChanged?(.quiet)
        renderMessages()
    }

    private func renderMessages() {
        let rendered = NSMutableAttributedString()
        for (index, message) in messages.enumerated() {
            let speaker = message.role == .user ? "You" : "Stickman"
            let content = message.role == .assistant && message.content.isEmpty && isThinking ? "..." : message.content
            let speakerColor = message.role == .user ? AnthropicStyle.clayDark : AnthropicStyle.ink
            let speakerAttributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: speakerColor,
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
            ]
            let bodyAttributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: AnthropicStyle.ink,
                .font: NSFont.systemFont(ofSize: 13, weight: .regular)
            ]

            rendered.append(NSAttributedString(string: "\(speaker)\n", attributes: speakerAttributes))
            rendered.append(NSAttributedString(string: content, attributes: bodyAttributes))
            if index < messages.count - 1 {
                rendered.append(NSAttributedString(string: "\n\n"))
            }
        }

        transcriptView.textStorage?.setAttributedString(rendered)
        transcriptView.scrollToEndOfDocument(nil)
    }

    func showAgentStatus() {
        messages.append(ChatMessage(role: .assistant, content: BackgroundAgentCoordinator.shared.compactSummary))
        renderMessages()
    }

    private var speechBubbleRect: NSRect {
        NSRect(x: 14, y: 2, width: max(0, bounds.width - 20), height: max(0, bounds.height - 42))
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
        agentObservers = [changeObserver, completionObserver]
    }

    private func refreshAgentButton() {
        let activeCount = BackgroundAgentCoordinator.shared.activeCount
        agentsButton.title = activeCount == 0 ? "Agents" : "Agents · \(activeCount)"
        AnthropicStyle.setButtonTitle(agentsButton, color: AnthropicStyle.mutedInk, weight: .medium)
    }

    private func presentCompletedAgent(_ task: StickmanAgentTask) {
        let result = task.result ?? task.errorMessage ?? "The agent finished without a result."
        let boundedResult = result.count > 1800 ? String(result.prefix(1797)) + "…" : result
        let browserNote = task.openedURLs.isEmpty ? "" : "\n\nOpened \(task.openedURLs.count) useful Chrome tab\(task.openedURLs.count == 1 ? "" : "s")."
        messages.append(ChatMessage(
            role: .assistant,
            content: "Agent \(task.id) finished.\n\n\(boundedResult)\(browserNote)"
        ))
        onSuccessMoment?()
        renderMessages()
    }

    private func fetchAssistantReply() {
        if pendingScreenshot == nil, automaticallySharesScreenForQuestions {
            pendingScreenshot = try? captureScreenWithoutStickman()
        }
        isThinking = true
        sendButton.isEnabled = false
        inputField.isEnabled = false
        subtitleLabel.stringValue = "Thinking..."
        onActivityChanged?(.thinking)
        scheduleResponseTimeout()

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

        if let error {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if messages.last?.role == .assistant, messages.last?.content.isEmpty == true {
                messages[messages.count - 1].content = message
            } else {
                messages.append(ChatMessage(role: .assistant, content: message))
            }
            onErrorMoment?()
        } else if messages.last?.role == .assistant, messages.last?.content.isEmpty == true {
            messages[messages.count - 1].content = "I finished the request, but the model did not return any text."
        } else {
            onSuccessMoment?()
        }

        isThinking = false
        sendButton.isEnabled = true
        inputField.isEnabled = true
        subtitleLabel.stringValue = "Ready when you are."
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
            "Hey, I am here. What are we working on?",
            "Hi! What can I help with?",
            "Ready when you are.",
            "Hey! Want me to take a look at something?"
        ].randomElement() ?? "Hey! How can I help?"
    }

    private func sanitizeAssistantReply(_ reply: String) -> String {
        reply
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var automaticallySharesScreenForQuestions: Bool {
        if UserDefaults.standard.object(forKey: "StickmanAutoScreenContext") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "StickmanAutoScreenContext")
    }

    private func captureScreenWithoutStickman() throws -> ScreenshotAttachment {
        let previousAlpha = window?.alphaValue ?? 1
        window?.alphaValue = 0
        defer { window?.alphaValue = previousAlpha }
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

    func realtimeVoiceClient(_ client: RealtimeVoiceClient, didChangeStatus status: String) {
        guard isVoiceModeActive else { return }
        subtitleLabel.stringValue = status
    }

    func realtimeVoiceClientDidDetectUserSpeech(_ client: RealtimeVoiceClient) {
        guard isVoiceModeActive else { return }
        messages.append(ChatMessage(role: .user, content: "Voice message"))
        messages.append(ChatMessage(role: .assistant, content: ""))
        voiceAssistantMessageIndex = messages.count - 1
        subtitleLabel.stringValue = "Listening..."
        onActivityChanged?(.listening)
        renderMessages()
    }

    func realtimeVoiceClient(_ client: RealtimeVoiceClient, didReceiveAssistantTranscriptDelta delta: String) {
        guard isVoiceModeActive else { return }
        let current = voiceAssistantMessageIndex.flatMap { messages.indices.contains($0) ? messages[$0].content : nil } ?? ""
        setVoiceAssistantReply(current + delta)
        subtitleLabel.stringValue = "Stickman is talking..."
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

        subtitleLabel.stringValue = "Voice on. Talk to Stickman."
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
        subtitleLabel.stringValue = "Voice failed."
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
