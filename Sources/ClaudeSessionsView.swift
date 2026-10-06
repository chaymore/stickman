import AppKit

/// Claude Code sessions on the personal profile, shown in place of the chat transcript.
final class ClaudeSessionsView: NSView {
    var onClose: (() -> Void)?
    var onOpen: ((ClaudeCodeSession) -> Void)?
    var onShowOutput: ((ClaudeCodeSession) -> Void)?
    var onStop: ((ClaudeCodeSession) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Claude Code")
    private let subtitleLabel = NSTextField(labelWithString: "Personal profile")
    private let refreshButton = StickmanIconButton(symbol: "arrow.clockwise", label: "Refresh", pointSize: 12)
    private let backButton = NSButton(title: "Back to Chat", target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let list = ClaudeSessionsListView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private var rows: [ClaudeSessionRow] = []
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = StickmanStyle.primaryText
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = StickmanStyle.secondaryText
        subtitleLabel.lineBreakMode = .byTruncatingTail
        refreshButton.target = self
        refreshButton.action = #selector(refreshPressed)
        backButton.target = self
        backButton.action = #selector(backPressed)
        backButton.controlSize = .small
        StickmanStyle.configureSecondaryButton(backButton)
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = StickmanStyle.secondaryText
        emptyLabel.alignment = .center
        emptyLabel.attributedStringValue = StickmanMarkdown.render(
            "No Claude sessions yet.\nTry `/claude @project fix the failing test`.",
            font: .systemFont(ofSize: 12),
            color: .secondaryLabelColor
        )
        scrollView.documentView = list
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        [titleLabel, subtitleLabel, refreshButton, backButton, scrollView, emptyLabel].forEach(addSubview)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionsChanged), name: .stickmanClaudeSessionsDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }

    override var isHidden: Bool {
        didSet { isHidden ? stopRefreshing() : startRefreshing() }
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        titleLabel.frame = NSRect(x: 18, y: 12, width: width - 170, height: 18)
        subtitleLabel.frame = NSRect(x: 18, y: 30, width: width - 170, height: 15)
        backButton.sizeToFit()
        backButton.frame.origin = NSPoint(x: width - 16 - backButton.frame.width, y: 15)
        refreshButton.frame = NSRect(x: backButton.frame.minX - 32, y: 13, width: 26, height: 26)
        scrollView.frame = NSRect(x: 0, y: 54, width: width, height: max(0, bounds.height - 54))
        emptyLabel.frame = NSRect(x: 24, y: 120, width: width - 48, height: 48)

        let rowWidth = scrollView.contentSize.width
        var y: CGFloat = 4
        for row in rows {
            row.frame = NSRect(x: 10, y: y, width: rowWidth - 20, height: 54)
            y += 58
        }
        list.frame = NSRect(x: 0, y: 0, width: rowWidth, height: max(y, scrollView.contentSize.height))
    }

    func reload() {
        let service = ClaudeCodeService.shared
        if let email = service.authStatus?.email {
            subtitleLabel.stringValue = "Personal profile · \(email)"
        } else {
            subtitleLabel.stringValue = "Personal profile · \(service.configDirectory)"
        }
        let sessions = service.sessions
        rows.forEach { $0.removeFromSuperview() }
        rows = sessions.map { session in
            let row = ClaudeSessionRow(session: session)
            row.onOpen = { [weak self] in self?.onOpen?(session) }
            row.onShowOutput = { [weak self] in self?.onShowOutput?(session) }
            row.onStop = { [weak self] in self?.onStop?(session) }
            list.addSubview(row)
            return row
        }
        emptyLabel.isHidden = !sessions.isEmpty
        needsLayout = true
    }

    private func startRefreshing() {
        reload()
        Task { @MainActor in await ClaudeCodeService.shared.refreshSessions() }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            Task { @MainActor in await ClaudeCodeService.shared.refreshSessions() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopRefreshing() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func sessionsChanged() {
        guard !isHidden else { return }
        reload()
    }

    @objc private func refreshPressed() {
        Task { @MainActor in await ClaudeCodeService.shared.refreshSessions() }
    }

    @objc private func backPressed() { onClose?() }
}

private final class ClaudeSessionsListView: NSView {
    override var isFlipped: Bool { true }
}

private final class ClaudeSessionRow: NSView {
    var onOpen: (() -> Void)?
    var onShowOutput: (() -> Void)?
    var onStop: (() -> Void)?

    private let session: ClaudeCodeSession
    private let nameLabel: NSTextField
    private let detailLabel: NSTextField
    private let openButton = StickmanIconButton(symbol: "arrow.up.forward.app", label: "Open in terminal", pointSize: 13)
    private let outputButton = StickmanIconButton(symbol: "text.alignleft", label: "Show latest output", pointSize: 12)
    private let stopButton = StickmanIconButton(symbol: "stop.circle", label: "Stop session", pointSize: 13)

    init(session: ClaudeCodeSession) {
        self.session = session
        nameLabel = NSTextField(labelWithString: session.name)
        detailLabel = NSTextField(labelWithString: Self.detail(for: session))
        super.init(frame: .zero)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = StickmanStyle.primaryText
        nameLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = session.needsAttention ? .systemOrange : StickmanStyle.secondaryText
        detailLabel.lineBreakMode = .byTruncatingTail
        openButton.target = self
        openButton.action = #selector(openPressed)
        outputButton.target = self
        outputButton.action = #selector(outputPressed)
        stopButton.target = self
        stopButton.action = #selector(stopPressed)
        outputButton.isHidden = !session.isBackground
        stopButton.isHidden = !(session.isBackground && (session.isWorking || session.needsAttention))
        [nameLabel, detailLabel, openButton, outputButton, stopButton].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let buttons = [stopButton, outputButton, openButton].filter { !$0.isHidden }
        var x = bounds.width - 10
        for button in buttons {
            x -= 28
            button.frame = NSRect(x: x, y: 14, width: 26, height: 26)
            x -= 2
        }
        nameLabel.frame = NSRect(x: 30, y: 9, width: x - 36, height: 18)
        detailLabel.frame = NSRect(x: 30, y: 28, width: x - 36, height: 15)
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        StickmanStyle.cardFill.setFill()
        card.fill()
        StickmanStyle.cardStroke.setStroke()
        card.stroke()

        let color: NSColor
        if session.needsAttention { color = .systemOrange }
        else if session.isWorking { color = .systemGreen }
        else if session.state == "failed" { color = .systemRed }
        else { color = .tertiaryLabelColor }
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 13, y: 15, width: 8, height: 8)).fill()
    }

    @objc private func openPressed() { onOpen?() }

    @objc private func outputPressed() { onShowOutput?() }

    @objc private func stopPressed() { onStop?() }

    private static func detail(for session: ClaudeCodeSession) -> String {
        var parts = [session.projectName, session.statusTitle]
        if !session.isBackground { parts.append("interactive") }
        if let startedAt = session.startedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            parts.append(formatter.localizedString(for: startedAt, relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }
}
