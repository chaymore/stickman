import AppKit

/// Settings for running Claude Code from Stickman on the personal profile.
final class ClaudeCodeSettingsView: NSView {
    private let scrollView = NSScrollView()
    private let content = ClaudeSettingsFlippedView()

    private let accountHeader = ClaudeSettingsHeader("Personal account")
    private let accountCard = ClaudeDividedCardView(dividers: [54, 98])
    private let accountIcon = NSImageView()
    private let accountTitle = NSTextField(labelWithString: "Checking…")
    private let accountDetail = NSTextField(labelWithString: "")
    private let signInButton = NSButton(title: "Sign In…", target: nil, action: nil)
    private let refreshButton = StickmanIconButton(symbol: "arrow.clockwise", label: "Check sign-in again", pointSize: 12)
    private let terminalLabel = NSTextField(labelWithString: "Open sessions in")
    private let terminalPopup = NSPopUpButton()
    private let permissionLabel = NSTextField(labelWithString: "Background session permissions")
    private let permissionPopup = NSPopUpButton()
    private let permissionDetail = NSTextField(wrappingLabelWithString: "A session that needs your approval waits until you open it.")

    private let projectsHeader = ClaudeSettingsHeader("Projects")
    private let projectsCard = StickmanCardView()
    private let addButton = NSButton(title: "Add Folder…", target: nil, action: nil)
    private let importButton = NSButton(title: "Import from Claude Code", target: nil, action: nil)
    private var projectRows: [NSView] = []

    private let usageLabel = NSTextField(wrappingLabelWithString: "")
    private var observers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
        observers.append(NotificationCenter.default.addObserver(forName: .stickmanClaudeProjectsDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildProjects()
        })
        rebuildProjects()
        showAccount(ClaudeCodeService.shared.authStatus)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override var isFlipped: Bool { true }

    /// Checks sign-in when the tab is shown. Never polled, since repeated checks can expire the login.
    func refresh() {
        terminalPopup.selectItem(at: ClaudeCodeService.Terminal.allCases.firstIndex(of: ClaudeCodeService.shared.terminal) ?? 0)
        permissionPopup.selectItem(at: ClaudeCodeService.PermissionMode.allCases.firstIndex(of: ClaudeCodeService.shared.permissionMode) ?? 0)
        if let status = ClaudeCodeService.shared.authStatus {
            showAccount(status)
        } else {
            checkAccount()
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let side: CGFloat = 20
        let width = bounds.width - side * 2
        var y: CGFloat = 14

        accountHeader.frame = NSRect(x: side + 4, y: y, width: width, height: 16)
        y += 22
        accountIcon.frame = NSRect(x: 14, y: 14, width: 26, height: 26)
        accountTitle.frame = NSRect(x: 50, y: 11, width: width - 200, height: 18)
        accountDetail.frame = NSRect(x: 50, y: 30, width: width - 200, height: 16)
        refreshButton.frame = NSRect(x: width - 14 - 26, y: 14, width: 26, height: 26)
        signInButton.frame = NSRect(x: refreshButton.frame.minX - 8 - 96, y: 13, width: 96, height: 28)
        terminalLabel.frame = NSRect(x: 14, y: 70, width: 220, height: 18)
        terminalPopup.frame = NSRect(x: width - 14 - 190, y: 65, width: 190, height: 26)
        permissionLabel.frame = NSRect(x: 14, y: 112, width: 220, height: 18)
        permissionPopup.frame = NSRect(x: width - 14 - 190, y: 107, width: 190, height: 26)
        permissionDetail.frame = NSRect(x: 14, y: 132, width: width - 230, height: 30)
        accountCard.frame = NSRect(x: side, y: y, width: width, height: 168)
        y = accountCard.frame.maxY + 18

        projectsHeader.frame = NSRect(x: side + 4, y: y, width: width, height: 16)
        y += 22
        addButton.frame = NSRect(x: 12, y: 11, width: 112, height: 28)
        importButton.frame = NSRect(x: addButton.frame.maxX + 6, y: 11, width: 180, height: 28)
        var rowY: CGFloat = 50
        for row in projectRows {
            row.frame = NSRect(x: 0, y: rowY, width: width, height: 44)
            rowY += 44
        }
        projectsCard.frame = NSRect(x: side, y: y, width: width, height: rowY + 4)
        y = projectsCard.frame.maxY + 14

        let usageHeight = usageLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 8, height: 300)).height ?? 40
        usageLabel.frame = NSRect(x: side + 4, y: y, width: width - 8, height: ceil(usageHeight))
        y = usageLabel.frame.maxY + 20

        content.frame = NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: max(y, scrollView.contentSize.height))
    }

    // MARK: Configuration

    private func configure() {
        scrollView.documentView = content
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        accountTitle.font = .systemFont(ofSize: 13, weight: .medium)
        accountTitle.textColor = StickmanStyle.primaryText
        accountTitle.lineBreakMode = .byTruncatingTail
        accountDetail.font = .systemFont(ofSize: 11.5)
        accountDetail.textColor = StickmanStyle.secondaryText
        accountDetail.lineBreakMode = .byTruncatingMiddle
        accountIcon.contentTintColor = StickmanStyle.secondaryText
        signInButton.target = self
        signInButton.action = #selector(signIn)
        refreshButton.target = self
        refreshButton.action = #selector(checkAccount)

        for label in [terminalLabel, permissionLabel] {
            label.font = .systemFont(ofSize: 13)
            label.textColor = StickmanStyle.primaryText
        }
        permissionDetail.font = .systemFont(ofSize: 11.5)
        permissionDetail.textColor = StickmanStyle.secondaryText
        terminalPopup.addItems(withTitles: ClaudeCodeService.Terminal.allCases.filter(\.isInstalled).map(\.title))
        terminalPopup.target = self
        terminalPopup.action = #selector(terminalChanged)
        permissionPopup.addItems(withTitles: ClaudeCodeService.PermissionMode.allCases.map(\.title))
        permissionPopup.target = self
        permissionPopup.action = #selector(permissionChanged)
        [accountIcon, accountTitle, accountDetail, signInButton, refreshButton, terminalLabel, terminalPopup,
         permissionLabel, permissionPopup, permissionDetail].forEach(accountCard.addSubview)

        addButton.target = self
        addButton.action = #selector(addFolder)
        StickmanStyle.configureSecondaryButton(addButton)
        importButton.target = self
        importButton.action = #selector(importProjects)
        importButton.toolTip = "Adds git repos you've already opened with your personal Claude profile"
        StickmanStyle.configureSecondaryButton(importButton)
        projectsCard.addSubview(addButton)
        projectsCard.addSubview(importButton)

        usageLabel.font = .systemFont(ofSize: 11.5)
        usageLabel.textColor = StickmanStyle.secondaryText
        usageLabel.attributedStringValue = StickmanMarkdown.render(
            "Ask from chat with `/claude @project task`, or say \"have Claude fix the login bug in project.\" Use `/cloud` to run it on Anthropic's servers instead. Without a project name, Stickman uses the project in the window you're looking at, then your default.",
            font: .systemFont(ofSize: 11.5),
            color: .secondaryLabelColor
        )

        [accountHeader, accountCard, projectsHeader, projectsCard, usageLabel].forEach(content.addSubview)
    }

    // MARK: Account

    @objc private func checkAccount() {
        accountTitle.stringValue = "Checking…"
        Task { @MainActor in
            let status = await ClaudeCodeService.shared.refreshAuthStatus()
            self.showAccount(status)
        }
    }

    private func showAccount(_ status: ClaudeAuthStatus?) {
        let service = ClaudeCodeService.shared
        let folder = service.configDirectory
        guard service.cliURL != nil else {
            accountTitle.stringValue = "Claude Code isn't installed"
            accountDetail.stringValue = "Install it with npm install -g @anthropic-ai/claude-code"
            setIcon("exclamationmark.triangle", color: .systemOrange)
            signInButton.isEnabled = false
            return
        }
        signInButton.isEnabled = true
        guard let status else {
            accountTitle.stringValue = "Personal profile"
            accountDetail.stringValue = "Profile folder: \(folder)"
            setIcon("person.crop.circle", color: StickmanStyle.secondaryText)
            return
        }
        if status.isSignedIn {
            accountTitle.stringValue = status.email.map { "Signed in as \($0)" } ?? "Signed in"
            accountDetail.stringValue = [status.plan, "Profile folder: \(folder)"].compactMap { $0 }.joined(separator: " · ")
            setIcon("checkmark.circle.fill", color: .systemGreen)
            signInButton.title = "Switch…"
            StickmanStyle.configureSecondaryButton(signInButton)
        } else {
            accountTitle.stringValue = "Not signed in"
            accountDetail.stringValue = "Sign in with your personal Claude account. Profile folder: \(folder)"
            setIcon("person.crop.circle.badge.exclamationmark", color: .systemOrange)
            signInButton.title = "Sign In…"
            StickmanStyle.configurePrimaryButton(signInButton)
        }
    }

    private func setIcon(_ symbol: String, color: NSColor) {
        accountIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
        accountIcon.contentTintColor = color
    }

    @objc private func signIn() {
        ClaudeCodeService.shared.openSignIn()
        accountTitle.stringValue = "Finish signing in, then press refresh"
    }

    @objc private func terminalChanged() {
        let installed = ClaudeCodeService.Terminal.allCases.filter(\.isInstalled)
        guard installed.indices.contains(terminalPopup.indexOfSelectedItem) else { return }
        ClaudeCodeService.shared.terminal = installed[terminalPopup.indexOfSelectedItem]
    }

    @objc private func permissionChanged() {
        let modes = ClaudeCodeService.PermissionMode.allCases
        guard modes.indices.contains(permissionPopup.indexOfSelectedItem) else { return }
        ClaudeCodeService.shared.permissionMode = modes[permissionPopup.indexOfSelectedItem]
    }

    // MARK: Projects

    @objc private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose project folders for Claude Code"
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            panel.urls.forEach { ClaudeCodeService.shared.addProject(at: $0) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    @objc private func importProjects() {
        let added = ClaudeCodeService.shared.importKnownProjects()
        importButton.title = added == 0 ? "Nothing new to import" : "Imported \(added)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.importButton.title = "Import from Claude Code"
        }
    }

    @objc private func removeProject(_ sender: ClaudeProjectButton) {
        ClaudeCodeService.shared.removeProject(named: sender.projectName)
    }

    @objc private func makeDefault(_ sender: ClaudeProjectButton) {
        ClaudeCodeService.shared.defaultProjectName = sender.projectName
        rebuildProjects()
    }

    private func rebuildProjects() {
        projectRows.forEach { $0.removeFromSuperview() }
        let service = ClaudeCodeService.shared
        if service.projects.isEmpty {
            let empty = ClaudeSettingsEmptyRow(text: "No projects yet. Add a folder, or import the ones Claude Code already knows.")
            projectsCard.addSubview(empty)
            projectRows = [empty]
        } else {
            projectRows = service.projects.map { project in
                let row = ClaudeProjectRow(project: project, isDefault: project.name == service.defaultProjectName)
                row.removeButton.target = self
                row.removeButton.action = #selector(removeProject(_:))
                row.defaultButton.target = self
                row.defaultButton.action = #selector(makeDefault(_:))
                projectsCard.addSubview(row)
                return row
            }
        }
        needsLayout = true
    }
}

// MARK: - Rows

private final class ClaudeSettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class ClaudeSettingsHeader: NSTextField {
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

/// A grouped card with hairlines between its rows.
private final class ClaudeDividedCardView: StickmanCardView {
    private let dividers: [CGFloat]

    init(dividers: [CGFloat]) {
        self.dividers = dividers
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        StickmanStyle.hairline.setFill()
        for y in dividers { NSRect(x: 14, y: y, width: bounds.width - 14, height: 1).fill() }
    }
}

private final class ClaudeSettingsEmptyRow: NSView {
    private let label: NSTextField

    init(text: String) {
        label = NSTextField(wrappingLabelWithString: text)
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
        label.frame = NSRect(x: 14, y: 8, width: bounds.width - 28, height: bounds.height - 12)
    }

    override func draw(_ dirtyRect: NSRect) {
        StickmanStyle.hairline.setFill()
        NSRect(x: 14, y: 0, width: bounds.width - 14, height: 1).fill()
    }
}

final class ClaudeProjectButton: StickmanIconButton {
    var projectName = ""
}

private final class ClaudeProjectRow: NSView {
    let removeButton = ClaudeProjectButton(symbol: "minus.circle", label: "Remove project", pointSize: 13, weight: .regular)
    let defaultButton = ClaudeProjectButton(symbol: "star", label: "Make default project", pointSize: 12, weight: .regular)
    private let icon = NSImageView()
    private let nameLabel: NSTextField
    private let pathLabel: NSTextField

    init(project: ClaudeProject, isDefault: Bool) {
        nameLabel = NSTextField(labelWithString: project.name)
        pathLabel = NSTextField(labelWithString: (project.path as NSString).abbreviatingWithTildeInPath)
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        icon.contentTintColor = .controlAccentColor
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = StickmanStyle.primaryText
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = StickmanStyle.secondaryText
        pathLabel.lineBreakMode = .byTruncatingMiddle
        removeButton.projectName = project.name
        defaultButton.projectName = project.name
        if isDefault {
            defaultButton.setSymbol("star.fill", label: "Default project", pointSize: 12, weight: .regular)
            defaultButton.isToggled = true
        }
        [icon, nameLabel, pathLabel, defaultButton, removeButton].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 14, y: 13, width: 18, height: 18)
        nameLabel.frame = NSRect(x: 40, y: 5, width: bounds.width - 120, height: 18)
        pathLabel.frame = NSRect(x: 40, y: 23, width: bounds.width - 120, height: 15)
        removeButton.frame = NSRect(x: bounds.width - 38, y: 9, width: 26, height: 26)
        defaultButton.frame = NSRect(x: removeButton.frame.minX - 30, y: 9, width: 26, height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        StickmanStyle.hairline.setFill()
        NSRect(x: 14, y: 0, width: bounds.width - 14, height: 1).fill()
    }
}
