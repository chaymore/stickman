import AppKit

final class StickmanSettingsPanelView: NSView, NSTextFieldDelegate {
    private enum Section {
        case websites
        case permissions
        case connections
    }

    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Settings")
    private let subtitleLabel = NSTextField(labelWithString: "Control Stickman's focus tools.")
    private let closeButton = NSButton(title: "Done", target: nil, action: nil)
    private let websitesTab = NSButton(title: "Websites", target: nil, action: nil)
    private let permissionsTab = NSButton(title: "Permissions", target: nil, action: nil)
    private let connectionsTab = NSButton(title: "Connections", target: nil, action: nil)
    private let enabledButton = NSButton(checkboxWithTitle: "Website blocker", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let nightLockLabel = NSTextField(labelWithString: "")
    private let autoScreenButton = NSButton(checkboxWithTitle: "See my screen when I ask", target: nil, action: nil)
    private let focusButton = NSButton(title: "Focus 25", target: nil, action: nil)
    private let endFocusButton = NSButton(title: "End", target: nil, action: nil)
    private let addField = NSTextField()
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let domainListView = FlippedView()
    private let permissionCenterView = PermissionCenterView()
    private let connectorCenterView = ConnectorCenterView()
    private var rowViews: [NSView] = []
    private var selectedSection: Section = .websites

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        AnthropicStyle.configurePanelLayer(layer)

        configureLabels()
        configureControls()

        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(closeButton)
        addSubview(websitesTab)
        addSubview(permissionsTab)
        addSubview(connectionsTab)
        addSubview(enabledButton)
        addSubview(statusLabel)
        addSubview(nightLockLabel)
        addSubview(autoScreenButton)
        addSubview(focusButton)
        addSubview(endFocusButton)
        addSubview(addField)
        addSubview(addButton)
        addSubview(scrollView)
        addSubview(permissionCenterView)
        addSubview(connectorCenterView)

        selectSection(.websites)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()

        titleLabel.frame = NSRect(x: 18, y: 14, width: bounds.width - 104, height: 24)
        closeButton.frame = NSRect(x: bounds.width - 76, y: 14, width: 58, height: 24)
        subtitleLabel.frame = NSRect(x: 18, y: 40, width: bounds.width - 36, height: 18)

        let sidebarWidth: CGFloat = 112
        websitesTab.frame = NSRect(x: 18, y: 78, width: sidebarWidth, height: 30)
        permissionsTab.frame = NSRect(x: 18, y: 114, width: sidebarWidth, height: 30)
        connectionsTab.frame = NSRect(x: 18, y: 150, width: sidebarWidth, height: 30)

        let contentX = sidebarWidth + 34
        let contentWidth = max(1, bounds.width - contentX - 18)
        let contentTop: CGFloat = 78
        let contentHeight = max(1, bounds.height - contentTop - 18)
        permissionCenterView.frame = NSRect(x: contentX, y: contentTop, width: contentWidth, height: contentHeight)
        connectorCenterView.frame = permissionCenterView.frame
        enabledButton.frame = NSRect(x: contentX, y: 78, width: contentWidth, height: 24)
        statusLabel.frame = NSRect(x: contentX, y: 106, width: contentWidth, height: 20)
        nightLockLabel.frame = NSRect(x: contentX, y: 127, width: contentWidth, height: 32)
        autoScreenButton.frame = NSRect(x: contentX, y: 160, width: contentWidth, height: 24)
        focusButton.frame = NSRect(x: contentX, y: 190, width: 86, height: 28)
        endFocusButton.frame = NSRect(x: contentX + 92, y: 190, width: 58, height: 28)
        addField.frame = NSRect(x: contentX, y: 228, width: contentWidth - 70, height: 30)
        addButton.frame = NSRect(x: bounds.width - 76, y: 228, width: 58, height: 30)
        scrollView.frame = NSRect(x: contentX, y: 270, width: contentWidth, height: max(80, bounds.height - 288))

        layoutRows(width: contentWidth)
    }

    func focusFirstControl() {
        guard !isHidden, let window else { return }

        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(addField)
    }

    func refresh() {
        let settings = WebsiteBlockerService.shared.settingsSnapshot()
        enabledButton.state = settings.enabled ? .on : .off
        statusLabel.stringValue = WebsiteBlockerService.shared.statusSummary
        nightLockLabel.stringValue = NightLockBridge.shared.shortStatus
        autoScreenButton.state = automaticallySharesScreen ? .on : .off
        rebuildRows(domains: settings.blockedDomains)
        permissionCenterView.refresh()
        connectorCenterView.refresh()
    }

    func showPermissionsForPreview() {
        selectSection(.permissions)
    }

    func showConnectionsForPreview() {
        selectSection(.connections)
    }

    func showPermissions() {
        selectSection(.permissions)
        refresh()
    }

    func showConnections() {
        selectSection(.connections)
        refresh()
    }

    private func configureLabels() {
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = AnthropicStyle.ink
        titleLabel.backgroundColor = .clear

        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = AnthropicStyle.mutedInk
        subtitleLabel.backgroundColor = .clear

        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = AnthropicStyle.mutedInk
        statusLabel.backgroundColor = .clear
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2

        nightLockLabel.font = NSFont.systemFont(ofSize: 11)
        nightLockLabel.textColor = AnthropicStyle.mutedInk
        nightLockLabel.backgroundColor = .clear
        nightLockLabel.lineBreakMode = .byWordWrapping
        nightLockLabel.maximumNumberOfLines = 2
    }

    private func configureControls() {
        closeButton.target = self
        closeButton.action = #selector(closeButtonPressed)
        AnthropicStyle.configureSecondaryButton(closeButton)

        websitesTab.target = self
        websitesTab.action = #selector(websitesTabPressed)
        permissionsTab.target = self
        permissionsTab.action = #selector(permissionsTabPressed)
        connectionsTab.target = self
        connectionsTab.action = #selector(connectionsTabPressed)

        enabledButton.target = self
        enabledButton.action = #selector(enabledChanged)
        enabledButton.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        enabledButton.contentTintColor = AnthropicStyle.ink

        autoScreenButton.target = self
        autoScreenButton.action = #selector(autoScreenChanged)
        autoScreenButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        autoScreenButton.contentTintColor = AnthropicStyle.ink

        focusButton.target = self
        focusButton.action = #selector(startFocus)
        AnthropicStyle.configurePrimaryButton(focusButton)

        endFocusButton.target = self
        endFocusButton.action = #selector(endFocus)
        AnthropicStyle.configureSecondaryButton(endFocusButton)

        addField.placeholderString = "Add a site, like youtube.com"
        addField.delegate = self
        addField.target = self
        addField.action = #selector(addButtonPressed)
        addField.font = NSFont.systemFont(ofSize: 13)
        AnthropicStyle.configureInputField(addField)

        addButton.target = self
        addButton.action = #selector(addButtonPressed)
        AnthropicStyle.configurePrimaryButton(addButton)

        scrollView.documentView = domainListView
        scrollView.drawsBackground = true
        scrollView.backgroundColor = AnthropicStyle.inset
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 10
        scrollView.layer?.borderColor = AnthropicStyle.line.cgColor
        scrollView.layer?.borderWidth = 1
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let event = NSApp.currentEvent, event.keyCode == 36 else { return }
        addBlockedDomain()
    }

    @objc private func closeButtonPressed() {
        onClose?()
    }

    @objc private func websitesTabPressed() {
        selectSection(.websites)
    }

    @objc private func permissionsTabPressed() {
        selectSection(.permissions)
    }

    @objc private func connectionsTabPressed() {
        selectSection(.connections)
    }

    @objc private func enabledChanged() {
        WebsiteBlockerService.shared.setBlockerEnabled(enabledButton.state == .on)
        refresh()
    }

    @objc private func addButtonPressed() {
        addBlockedDomain()
    }

    @objc private func removeButtonPressed(_ sender: DomainRemoveButton) {
        WebsiteBlockerService.shared.removeBlockedDomain(sender.domain)
        refresh()
    }

    @objc private func autoScreenChanged() {
        UserDefaults.standard.set(autoScreenButton.state == .on, forKey: "StickmanAutoScreenContext")
    }

    @objc private func startFocus() {
        _ = WebsiteBlockerService.shared.startFocusSession(minutes: 25)
        refresh()
    }

    @objc private func endFocus() {
        _ = WebsiteBlockerService.shared.endFocusSession()
        refresh()
    }

    private var automaticallySharesScreen: Bool {
        if UserDefaults.standard.object(forKey: "StickmanAutoScreenContext") == nil { return true }
        return UserDefaults.standard.bool(forKey: "StickmanAutoScreenContext")
    }

    private func selectSection(_ section: Section) {
        selectedSection = section
        let websiteViews: [NSView] = [
            enabledButton, statusLabel, nightLockLabel, autoScreenButton, focusButton,
            endFocusButton, addField, addButton, scrollView
        ]
        websiteViews.forEach { $0.isHidden = section != .websites }
        permissionCenterView.isHidden = section != .permissions
        connectorCenterView.isHidden = section != .connections

        subtitleLabel.stringValue = {
            switch section {
            case .websites: return "Control Stickman's focus tools."
            case .permissions: return "Choose exactly what Stickman may access."
            case .connections: return "Connect accounts one at a time."
            }
        }()

        let tabs: [(NSButton, Section)] = [
            (websitesTab, .websites),
            (permissionsTab, .permissions),
            (connectionsTab, .connections)
        ]
        for (button, buttonSection) in tabs {
            if buttonSection == section {
                AnthropicStyle.configurePrimaryButton(button)
            } else {
                AnthropicStyle.configureSecondaryButton(button)
            }
        }
        needsLayout = true
    }

    private func addBlockedDomain() {
        let text = addField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WebsiteBlockerService.shared.addBlockedDomain(text) != nil else { return }

        addField.stringValue = ""
        refresh()
    }

    private func rebuildRows(domains: [String]) {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()

        if domains.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "No blocked sites yet.")
            emptyLabel.font = NSFont.systemFont(ofSize: 13)
            emptyLabel.textColor = AnthropicStyle.mutedInk
            emptyLabel.backgroundColor = .clear
            domainListView.addSubview(emptyLabel)
            rowViews.append(emptyLabel)
        } else {
            for domain in domains {
                let row = DomainRowView(domain: domain)
                row.removeButton.target = self
                row.removeButton.action = #selector(removeButtonPressed(_:))
                domainListView.addSubview(row)
                rowViews.append(row)
            }
        }

        needsLayout = true
    }

    private func layoutRows(width: CGFloat) {
        let rowHeight: CGFloat = 38
        let gap: CGFloat = 8
        let contentHeight = max(scrollView.bounds.height, CGFloat(rowViews.count) * (rowHeight + gap) + 8)
        domainListView.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)

        for (index, row) in rowViews.enumerated() {
            row.frame = NSRect(
                x: 8,
                y: 8 + CGFloat(index) * (rowHeight + gap),
                width: max(1, width - 16),
                height: rowHeight
            )
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}

private final class DomainRowView: NSView {
    let removeButton: DomainRemoveButton
    private let domainLabel: NSTextField

    init(domain: String) {
        domainLabel = NSTextField(labelWithString: domain)
        removeButton = DomainRemoveButton(domain: domain)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.62).cgColor
        layer?.cornerRadius = 8
        layer?.borderColor = AnthropicStyle.line.cgColor
        layer?.borderWidth = 1

        domainLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        domainLabel.textColor = AnthropicStyle.ink
        domainLabel.backgroundColor = .clear

        removeButton.title = "Remove"
        AnthropicStyle.configureDangerButton(removeButton)
        removeButton.toolTip = "Remove \(domain)"

        addSubview(domainLabel)
        addSubview(removeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()

        removeButton.frame = NSRect(x: bounds.width - 78, y: 7, width: 68, height: 24)
        domainLabel.frame = NSRect(x: 12, y: 10, width: max(1, bounds.width - 102), height: 18)
    }
}

private final class DomainRemoveButton: NSButton {
    let domain: String

    init(domain: String) {
        self.domain = domain
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
