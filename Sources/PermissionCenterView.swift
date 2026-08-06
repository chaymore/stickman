import AppKit

final class PermissionCenterView: NSView {
    private let introLabel = NSTextField(labelWithString: "Nothing is bundled together. Grant only what you want Stickman to use.")
    private let scrollView = NSScrollView()
    private let listView = PermissionFlippedView()
    private var rows: [StickmanPermissionRowView] = []
    private var observer: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        introLabel.font = NSFont.systemFont(ofSize: 12)
        introLabel.textColor = AnthropicStyle.mutedInk
        introLabel.maximumNumberOfLines = 2
        introLabel.lineBreakMode = .byWordWrapping

        scrollView.documentView = listView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        addSubview(introLabel)
        addSubview(scrollView)

        observer = NotificationCenter.default.addObserver(
            forName: .stickmanPermissionsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refresh() }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        introLabel.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 38)
        scrollView.frame = NSRect(x: 0, y: 42, width: bounds.width, height: max(1, bounds.height - 42))
        let rowHeight: CGFloat = 61
        let gap: CGFloat = 7
        let contentHeight = max(scrollView.bounds.height, CGFloat(rows.count) * (rowHeight + gap))
        listView.frame = NSRect(x: 0, y: 0, width: scrollView.bounds.width, height: contentHeight)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(index) * (rowHeight + gap), width: listView.bounds.width - 4, height: rowHeight)
        }
    }

    func refresh() {
        rows.forEach { $0.removeFromSuperview() }
        rows = PermissionCenterService.shared.snapshots.map { snapshot in
            let row = StickmanPermissionRowView(snapshot: snapshot)
            row.actionButton.target = self
            row.actionButton.action = #selector(permissionButtonPressed(_:))
            listView.addSubview(row)
            return row
        }
        needsLayout = true
    }

    @objc private func permissionButtonPressed(_ sender: StickmanPermissionButton) {
        let status = PermissionCenterService.shared.status(for: sender.kind)
        if status == .denied || status == .granted || status == .limited {
            PermissionCenterService.shared.openSystemSettings(for: sender.kind)
        } else {
            PermissionCenterService.shared.request(sender.kind)
        }
    }
}

private final class StickmanPermissionRowView: NSView {
    let actionButton: StickmanPermissionButton
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private let statusLabel: NSTextField

    init(snapshot: StickmanPermissionSnapshot) {
        actionButton = StickmanPermissionButton(kind: snapshot.kind)
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
        detailLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        statusLabel.textColor = snapshot.status == .granted ? AnthropicStyle.clayDark : AnthropicStyle.mutedInk

        actionButton.title = {
            switch snapshot.status {
            case .notRequested: return "Grant"
            case .denied: return "Settings"
            case .granted, .limited: return "Manage"
            case .unavailable: return "—"
            }
        }()
        actionButton.isEnabled = snapshot.status != .unavailable
        if snapshot.status == .notRequested {
            AnthropicStyle.configurePrimaryButton(actionButton)
        } else {
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
        let buttonWidth: CGFloat = 68
        titleLabel.frame = NSRect(x: 11, y: 8, width: bounds.width - buttonWidth - 28, height: 17)
        detailLabel.frame = NSRect(x: 11, y: 27, width: bounds.width - buttonWidth - 28, height: 16)
        statusLabel.frame = NSRect(x: 11, y: 44, width: 130, height: 14)
        actionButton.frame = NSRect(x: bounds.width - buttonWidth - 10, y: 17, width: buttonWidth, height: 27)
    }
}

private final class StickmanPermissionButton: NSButton {
    let kind: StickmanPermissionKind

    init(kind: StickmanPermissionKind) {
        self.kind = kind
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class PermissionFlippedView: NSView {
    override var isFlipped: Bool { true }
}
