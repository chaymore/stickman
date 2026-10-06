import AppKit

final class StickmanSettingsPanelView: NSView, NSTextFieldDelegate {
    private enum Section: Int {
        case general
        case claudeCode
        case permissions
        case connections
    }

    static let wanderingDefaultsKey = "StickmanWanders"

    static var allowsWandering: Bool {
        UserDefaults.standard.object(forKey: wanderingDefaultsKey) == nil || UserDefaults.standard.bool(forKey: wanderingDefaultsKey)
    }

    static let screenShareDefaultsKey = "StickmanHidesDuringScreenShare"

    static var hidesDuringScreenShare: Bool {
        UserDefaults.standard.object(forKey: screenShareDefaultsKey) == nil || UserDefaults.standard.bool(forKey: screenShareDefaultsKey)
    }

    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Settings")
    private let closeButton = NSButton(title: "Done", target: nil, action: nil)
    private let sectionControl = NSSegmentedControl(labels: ["General", "Claude Code", "Permissions", "Connections"], trackingMode: .selectOne, target: nil, action: nil)
    private let separator = SettingsHairline()
    private let generalScroll = NSScrollView()
    private let generalContent = SettingsFlippedView()

    private let behaviorHeader = SettingsSectionHeader("Stickman")
    private let behaviorCard = StickmanCardView()
    private let wanderRow = SettingsToggleRow(title: "Wander around", detail: "Strolls along your windows, hops between them, and sits down when he gets bored.")
    private let screenRow = SettingsToggleRow(title: "See my screen when I ask", detail: "Captures one screenshot per question and deletes it after the reply.")
    private let shareRow = SettingsToggleRow(
        title: "Hide while sharing my screen",
        detail: ScreenShareMonitor.isSupported
            ? "Disappears while Zoom, Meet, Teams, or a screen recorder is capturing your screen."
            : "Not available on this version of macOS."
    )

    private let focusHeader = SettingsSectionHeader("Focus")
    private let focusCard = StickmanCardView()
    private let focusTitle = NSTextField(labelWithString: "Focus session")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let focusButton = NSButton(title: "Start 25 min", target: nil, action: nil)
    private let endFocusButton = NSButton(title: "End", target: nil, action: nil)
    private let blockerRow = SettingsToggleRow(title: "Bedtime guard", detail: "")

    private let sitesHeader = SettingsSectionHeader("Blocked sites")
    private let sitesCard = StickmanCardView()
    private let addField = NSTextField()
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private var domainRows: [NSView] = []

    private let claudeCodeView = ClaudeCodeSettingsView()
    private let permissionCenterView = PermissionCenterView()
    private let connectorCenterView = ConnectorCenterView()
    private var selectedSection: Section = .general

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHeader()
        configureGeneral()
        addSubview(claudeCodeView)
        addSubview(permissionCenterView)
        addSubview(connectorCenterView)
        selectSection(.general)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    // MARK: Layout

    override func layout() {
        super.layout()
        let width = bounds.width
        titleLabel.frame = NSRect(x: 22, y: 18, width: width - 140, height: 22)
        closeButton.frame = NSRect(x: width - 22 - 72, y: 15, width: 72, height: 28)
        sectionControl.sizeToFit()
        let controlWidth = max(sectionControl.frame.width, 400)
        sectionControl.frame = NSRect(x: (width - controlWidth) / 2, y: 54, width: controlWidth, height: 24)
        separator.frame = NSRect(x: 0, y: 92, width: width, height: 1)

        let contentFrame = NSRect(x: 0, y: 93, width: width, height: max(1, bounds.height - 93))
        generalScroll.frame = contentFrame
        claudeCodeView.frame = contentFrame
        permissionCenterView.frame = contentFrame.insetBy(dx: 20, dy: 14)
        connectorCenterView.frame = permissionCenterView.frame
        layoutGeneral(width: width)
    }

    private func layoutGeneral(width: CGFloat) {
        let side: CGFloat = 20
        let cardWidth = width - side * 2
        var y: CGFloat = 14

        behaviorHeader.frame = NSRect(x: side + 4, y: y, width: cardWidth, height: 16)
        y += 22
        let wanderHeight = wanderRow.height(forWidth: cardWidth)
        let shareHeight = shareRow.height(forWidth: cardWidth)
        let screenHeight = screenRow.height(forWidth: cardWidth)
        behaviorCard.frame = NSRect(x: side, y: y, width: cardWidth, height: wanderHeight + shareHeight + screenHeight + 2)
        wanderRow.frame = NSRect(x: 0, y: 0, width: cardWidth, height: wanderHeight)
        shareRow.frame = NSRect(x: 0, y: wanderHeight + 1, width: cardWidth, height: shareHeight)
        screenRow.frame = NSRect(x: 0, y: wanderHeight + shareHeight + 2, width: cardWidth, height: screenHeight)
        y = behaviorCard.frame.maxY + 18

        focusHeader.frame = NSRect(x: side + 4, y: y, width: cardWidth, height: 16)
        y += 22
        let statusHeight = ceil(statusLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: cardWidth - 220, height: 200)).height ?? 16)
        let focusTop = max(52, 30 + statusHeight + 10)
        focusTitle.frame = NSRect(x: 14, y: 12, width: cardWidth - 220, height: 18)
        statusLabel.frame = NSRect(x: 14, y: 32, width: cardWidth - 220, height: statusHeight)
        endFocusButton.frame = NSRect(x: cardWidth - 14 - 60, y: 13, width: 60, height: 28)
        focusButton.frame = NSRect(x: endFocusButton.frame.minX - 6 - 112, y: 13, width: 112, height: 28)
        let blockerHeight = blockerRow.height(forWidth: cardWidth)
        blockerRow.frame = NSRect(x: 0, y: focusTop + 1, width: cardWidth, height: blockerHeight)
        focusCard.frame = NSRect(x: side, y: y, width: cardWidth, height: focusTop + 1 + blockerHeight)
        y = focusCard.frame.maxY + 18

        sitesHeader.frame = NSRect(x: side + 4, y: y, width: cardWidth, height: 16)
        y += 22
        addField.frame = NSRect(x: 12, y: 12, width: cardWidth - 24 - 70, height: 26)
        addButton.frame = NSRect(x: cardWidth - 12 - 64, y: 11, width: 64, height: 28)
        var rowY: CGFloat = 50
        for row in domainRows {
            row.frame = NSRect(x: 0, y: rowY, width: cardWidth, height: 36)
            rowY += 36
        }
        sitesCard.frame = NSRect(x: side, y: y, width: cardWidth, height: rowY + 6)
        y = sitesCard.frame.maxY + 20

        generalContent.frame = NSRect(x: 0, y: 0, width: generalScroll.contentSize.width, height: max(y, generalScroll.contentSize.height))
    }

    // MARK: Configuration

    private func configureHeader() {
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = StickmanStyle.primaryText

        closeButton.target = self
        closeButton.action = #selector(closeButtonPressed)
        StickmanStyle.configurePrimaryButton(closeButton)

        sectionControl.target = self
        sectionControl.action = #selector(sectionChanged)
        sectionControl.segmentStyle = .automatic
        sectionControl.selectedSegment = 0

        [titleLabel, closeButton, sectionControl, separator].forEach(addSubview)
    }

    private func configureGeneral() {
        generalScroll.documentView = generalContent
        generalScroll.drawsBackground = false
        generalScroll.hasVerticalScroller = true
        generalScroll.autohidesScrollers = true
        generalScroll.scrollerStyle = .overlay
        generalScroll.borderType = .noBorder
        addSubview(generalScroll)

        wanderRow.toggle.target = self
        wanderRow.toggle.action = #selector(wanderChanged)
        shareRow.toggle.target = self
        shareRow.toggle.action = #selector(screenShareChanged)
        shareRow.toggle.isEnabled = ScreenShareMonitor.isSupported
        shareRow.showsTopSeparator = true
        screenRow.toggle.target = self
        screenRow.toggle.action = #selector(autoScreenChanged)
        screenRow.showsTopSeparator = true
        behaviorCard.addSubview(wanderRow)
        behaviorCard.addSubview(shareRow)
        behaviorCard.addSubview(screenRow)

        focusTitle.font = .systemFont(ofSize: 13, weight: .medium)
        focusTitle.textColor = StickmanStyle.primaryText
        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.textColor = StickmanStyle.secondaryText
        focusButton.target = self
        focusButton.action = #selector(startFocus)
        StickmanStyle.configurePrimaryButton(focusButton)
        endFocusButton.target = self
        endFocusButton.action = #selector(endFocus)
        StickmanStyle.configureSecondaryButton(endFocusButton)
        blockerRow.toggle.target = self
        blockerRow.toggle.action = #selector(enabledChanged)
        blockerRow.showsTopSeparator = true
        [focusTitle, statusLabel, focusButton, endFocusButton, blockerRow].forEach(focusCard.addSubview)

        addField.placeholderString = "Add a site, like youtube.com"
        addField.delegate = self
        addField.target = self
        addField.action = #selector(addButtonPressed)
        StickmanStyle.configureInputField(addField)
        addButton.target = self
        addButton.action = #selector(addButtonPressed)
        StickmanStyle.configureSecondaryButton(addButton)
        sitesCard.addSubview(addField)
        sitesCard.addSubview(addButton)

        [behaviorHeader, behaviorCard, focusHeader, focusCard, sitesHeader, sitesCard].forEach(generalContent.addSubview)
    }

    // MARK: Public API

    func focusFirstControl() {
        guard !isHidden, let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKey()
        if selectedSection == .general { window.makeFirstResponder(addField) }
    }

    func refresh() {
        let settings = WebsiteBlockerService.shared.settingsSnapshot()
        blockerRow.toggle.state = settings.enabled ? .on : .off
        blockerRow.detail = "Blocks your list below at bedtime. \(StickmanBlocker.statusSummary)"
        statusLabel.stringValue = WebsiteBlockerService.shared.statusSummary
        screenRow.toggle.state = automaticallySharesScreen ? .on : .off
        wanderRow.toggle.state = Self.allowsWandering ? .on : .off
        shareRow.toggle.state = Self.hidesDuringScreenShare && ScreenShareMonitor.isSupported ? .on : .off
        rebuildRows(domains: settings.blockedDomains)
        permissionCenterView.refresh()
        connectorCenterView.refresh()
        needsLayout = true
    }

    func showPermissionsForPreview() { selectSection(.permissions) }

    func showConnectionsForPreview() { selectSection(.connections) }

    func showClaudeCodeForPreview() {
        selectedSection = .claudeCode
        sectionControl.selectedSegment = Section.claudeCode.rawValue
        generalScroll.isHidden = true
        claudeCodeView.isHidden = false
        permissionCenterView.isHidden = true
        connectorCenterView.isHidden = true
        needsLayout = true
    }

    func showGeneral() {
        selectSection(.general)
        refresh()
    }

    func showClaudeCode() {
        selectSection(.claudeCode)
        refresh()
    }

    func showPermissions() {
        selectSection(.permissions)
        refresh()
    }

    func showConnections() {
        selectSection(.connections)
        refresh()
    }

    // MARK: Actions

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let event = NSApp.currentEvent, event.keyCode == 36 else { return }
        addBlockedDomain()
    }

    @objc private func closeButtonPressed() { onClose?() }

    @objc private func sectionChanged() {
        selectSection(Section(rawValue: sectionControl.selectedSegment) ?? .general)
    }

    @objc private func enabledChanged() {
        WebsiteBlockerService.shared.setBlockerEnabled(blockerRow.toggle.state == .on)
        refresh()
    }

    @objc private func wanderChanged() {
        UserDefaults.standard.set(wanderRow.toggle.state == .on, forKey: Self.wanderingDefaultsKey)
    }

    @objc private func screenShareChanged() {
        UserDefaults.standard.set(shareRow.toggle.state == .on, forKey: Self.screenShareDefaultsKey)
        NotificationCenter.default.post(name: .stickmanScreenShareDidChange, object: nil)
    }

    @objc private func addButtonPressed() { addBlockedDomain() }

    @objc private func removeButtonPressed(_ sender: DomainRemoveButton) {
        WebsiteBlockerService.shared.removeBlockedDomain(sender.domain)
        refresh()
    }

    @objc private func autoScreenChanged() {
        UserDefaults.standard.set(screenRow.toggle.state == .on, forKey: "StickmanAutoScreenContext")
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
        sectionControl.selectedSegment = section.rawValue
        generalScroll.isHidden = section != .general
        claudeCodeView.isHidden = section != .claudeCode
        if section == .claudeCode { claudeCodeView.refresh() }
        permissionCenterView.isHidden = section != .permissions
        connectorCenterView.isHidden = section != .connections
        needsLayout = true
    }

    private func addBlockedDomain() {
        let text = addField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WebsiteBlockerService.shared.addBlockedDomain(text) != nil else { return }
        addField.stringValue = ""
        refresh()
    }

    private func rebuildRows(domains: [String]) {
        domainRows.forEach { $0.removeFromSuperview() }
        if domains.isEmpty {
            let empty = SettingsEmptyRow(text: "No blocked sites yet.")
            sitesCard.addSubview(empty)
            domainRows = [empty]
        } else {
            domainRows = domains.map { domain in
                let row = DomainRowView(domain: domain)
                row.removeButton.target = self
                row.removeButton.action = #selector(removeButtonPressed(_:))
                sitesCard.addSubview(row)
                return row
            }
        }
        needsLayout = true
    }
}

// MARK: - Rows

private final class SettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class SettingsHairline: NSView {
    override func draw(_ dirtyRect: NSRect) {
        StickmanStyle.hairline.setFill()
        bounds.fill()
    }
}

private final class SettingsSectionHeader: NSTextField {
    init(_ title: String) {
        super.init(frame: .zero)
        stringValue = title.uppercased()
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        font = .systemFont(ofSize: 10.5, weight: .semibold)
        textColor = StickmanStyle.secondaryText
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Title, optional detail, and a switch, inside a grouped card.
private final class SettingsToggleRow: NSView {
    let toggle = NSSwitch()
    var showsTopSeparator = false { didSet { needsDisplay = true } }
    var detail: String {
        get { detailLabel.stringValue }
        set { detailLabel.stringValue = newValue; detailLabel.isHidden = newValue.isEmpty; superview?.superview?.needsLayout = true }
    }
    private let titleLabel: NSTextField
    private let detailLabel = NSTextField(wrappingLabelWithString: "")

    init(title: String, detail: String) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = StickmanStyle.primaryText
        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.textColor = StickmanStyle.secondaryText
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
        toggle.controlSize = .small
        [titleLabel, detailLabel, toggle].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard !detailLabel.isHidden else { return 42 }
        let detailHeight = detailLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 90, height: 200)).height ?? 16
        return 34 + ceil(detailHeight) + 10
    }

    override func layout() {
        super.layout()
        let textWidth = bounds.width - 90
        if detailLabel.isHidden {
            titleLabel.frame = NSRect(x: 14, y: 12, width: textWidth, height: 18)
        } else {
            titleLabel.frame = NSRect(x: 14, y: 11, width: textWidth, height: 18)
            detailLabel.frame = NSRect(x: 14, y: 31, width: textWidth, height: bounds.height - 40)
        }
        toggle.sizeToFit()
        toggle.frame.origin = NSPoint(x: bounds.width - 14 - toggle.frame.width, y: 12)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showsTopSeparator else { return }
        StickmanStyle.hairline.setFill()
        NSRect(x: 14, y: 0, width: bounds.width - 14, height: 1).fill()
    }
}

private final class SettingsEmptyRow: NSView {
    private let label: NSTextField

    init(text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 12)
        label.textColor = StickmanStyle.tertiaryText
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 14, y: 10, width: bounds.width - 28, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        StickmanStyle.hairline.setFill()
        NSRect(x: 14, y: 0, width: bounds.width - 14, height: 1).fill()
    }
}

private final class DomainRowView: NSView {
    let removeButton: DomainRemoveButton
    private let icon = NSImageView()
    private let domainLabel: NSTextField

    init(domain: String) {
        domainLabel = NSTextField(labelWithString: domain)
        removeButton = DomainRemoveButton(domain: domain)
        super.init(frame: .zero)

        icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        icon.contentTintColor = StickmanStyle.secondaryText
        domainLabel.font = .systemFont(ofSize: 13)
        domainLabel.textColor = StickmanStyle.primaryText
        domainLabel.lineBreakMode = .byTruncatingMiddle
        [icon, domainLabel, removeButton].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 14, y: 10, width: 16, height: 16)
        domainLabel.frame = NSRect(x: 38, y: 9, width: max(1, bounds.width - 84), height: 18)
        removeButton.frame = NSRect(x: bounds.width - 38, y: 5, width: 26, height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        StickmanStyle.hairline.setFill()
        NSRect(x: 14, y: 0, width: bounds.width - 14, height: 1).fill()
    }
}

private final class DomainRemoveButton: StickmanIconButton {
    let domain: String

    init(domain: String) {
        self.domain = domain
        super.init(symbol: "minus.circle", label: "Remove \(domain)", pointSize: 13, weight: .regular)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
