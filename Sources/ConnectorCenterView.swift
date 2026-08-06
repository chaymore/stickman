import AppKit

final class ConnectorCenterView: NSView {
    private let introLabel = NSTextField(labelWithString: "Account access stays separate. Tokens live in Keychain; write actions will require confirmation.")
    private let proactiveButton = NSButton(checkboxWithTitle: "Prepare study blocks 20 minutes before they start", target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let listView = ConnectorFlippedView()
    private var rows: [StickmanConnectorRowView] = []
    private var observers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        introLabel.font = NSFont.systemFont(ofSize: 12)
        introLabel.textColor = AnthropicStyle.mutedInk
        introLabel.maximumNumberOfLines = 2
        introLabel.lineBreakMode = .byWordWrapping

        scrollView.documentView = listView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        addSubview(introLabel)
        addSubview(proactiveButton)
        addSubview(scrollView)

        proactiveButton.target = self
        proactiveButton.action = #selector(proactiveSettingChanged)
        proactiveButton.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        proactiveButton.contentTintColor = AnthropicStyle.ink
        proactiveButton.state = ProactiveStudyService.shared.isEnabled ? .on : .off

        for name in [Notification.Name.stickmanConnectorsDidChange, .stickmanPermissionsDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        introLabel.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 38)
        proactiveButton.frame = NSRect(x: 0, y: 39, width: bounds.width, height: 24)
        scrollView.frame = NSRect(x: 0, y: 68, width: bounds.width, height: max(1, bounds.height - 68))
        let rowHeight: CGFloat = 66
        let gap: CGFloat = 7
        let contentHeight = max(scrollView.bounds.height, CGFloat(rows.count) * (rowHeight + gap))
        listView.frame = NSRect(x: 0, y: 0, width: scrollView.bounds.width, height: contentHeight)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(index) * (rowHeight + gap), width: listView.bounds.width - 4, height: rowHeight)
        }
    }

    func refresh() {
        rows.forEach { $0.removeFromSuperview() }
        rows = ConnectorRegistryService.shared.snapshots.map { snapshot in
            let row = StickmanConnectorRowView(snapshot: snapshot)
            row.actionButton.target = self
            row.actionButton.action = #selector(connectorButtonPressed(_:))
            listView.addSubview(row)
            return row
        }
        needsLayout = true
    }

    @objc private func connectorButtonPressed(_ sender: StickmanConnectorButton) {
        let status = ConnectorRegistryService.shared.status(for: sender.kind)
        if (status == .connected || status == .tokenSaved), sender.kind.credentialService != nil {
            let alert = NSAlert()
            alert.messageText = "Disconnect \(sender.kind.title)?"
            alert.informativeText = "This removes Stickman’s token from macOS Keychain."
            alert.addButton(withTitle: "Disconnect")
            alert.addButton(withTitle: "Cancel")
            let handle: (NSApplication.ModalResponse) -> Void = { response in
                if response == .alertFirstButtonReturn {
                    ConnectorRegistryService.shared.disconnect(sender.kind)
                }
            }
            if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
        } else {
            ConnectorRegistryService.shared.configure(sender.kind, presenting: window)
        }
    }

    @objc private func proactiveSettingChanged() {
        ProactiveStudyService.shared.isEnabled = proactiveButton.state == .on
    }
}

private final class StickmanConnectorRowView: NSView {
    let actionButton: StickmanConnectorButton
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private let statusLabel: NSTextField

    init(snapshot: StickmanConnectorSnapshot) {
        actionButton = StickmanConnectorButton(kind: snapshot.kind)
        titleLabel = NSTextField(labelWithString: snapshot.kind.title)
        detailLabel = NSTextField(labelWithString: snapshot.kind.detail)
        statusLabel = NSTextField(labelWithString: snapshot.status.title)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.52).cgColor
        layer?.cornerRadius = 9
        layer?.borderColor = AnthropicStyle.line.cgColor
        layer?.borderWidth = 1

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = AnthropicStyle.ink
        detailLabel.font = NSFont.systemFont(ofSize: 10.5)
        detailLabel.textColor = AnthropicStyle.mutedInk
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        statusLabel.textColor = snapshot.status == .connected ? AnthropicStyle.clayDark : AnthropicStyle.mutedInk

        switch snapshot.status {
        case .connected, .tokenSaved:
            actionButton.title = snapshot.kind.credentialService == nil ? "Manage" : "Remove"
            AnthropicStyle.configureSecondaryButton(actionButton)
        case .ready:
            actionButton.title = "Connect"
            AnthropicStyle.configurePrimaryButton(actionButton)
        case .setupRequired:
            actionButton.title = "Set up"
            AnthropicStyle.configureSecondaryButton(actionButton)
        case .browserOnly:
            actionButton.title = "Open"
            AnthropicStyle.configureSecondaryButton(actionButton)
        }

        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(statusLabel)
        addSubview(actionButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let buttonWidth: CGFloat = 70
        titleLabel.frame = NSRect(x: 11, y: 7, width: bounds.width - buttonWidth - 28, height: 17)
        detailLabel.frame = NSRect(x: 11, y: 25, width: bounds.width - buttonWidth - 28, height: 29)
        statusLabel.frame = NSRect(x: 11, y: 52, width: 140, height: 14)
        actionButton.frame = NSRect(x: bounds.width - buttonWidth - 10, y: 20, width: buttonWidth, height: 27)
    }
}

private final class StickmanConnectorButton: NSButton {
    let kind: StickmanConnectorKind

    init(kind: StickmanConnectorKind) {
        self.kind = kind
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class ConnectorFlippedView: NSView {
    override var isFlipped: Bool { true }
}
