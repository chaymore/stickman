import AppKit
import Dispatch

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var stickmanWindowController: StickmanWindowController?
    private var hotKeyManager: HotKeyManager?
    private var statusItem: NSStatusItem?
    private var agentStatusMenuItem: NSMenuItem?
    private var rightClickMonitors: [Any] = []
    private var isStickmanVisible = false
    private var screenShareObserver: NSObjectProtocol?
    private var shareStatusMenuItem: NSMenuItem?
    private var showMenuItem: NSMenuItem?
    private var stopFightingMenuItem: NSMenuItem?
    private var notchMenuItem: NSMenuItem?
    private var quitMenuItem: NSMenuItem?
    private var keepsRunningMenuItem: NSMenuItem?
    private var blockerStatusMenuItem: NSMenuItem?
    private var blockerScheduleMenuItem: NSMenuItem?
    private var blockerAllowanceMenuItems: [NSMenuItem] = []
    private var blockerInstallMenuItem: NSMenuItem?
    /// Set when the user summons Stickman during a share; cleared when the share ends.
    private var showsDuringCurrentShare = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handOffToRunningCopy() { return }
        LegacyMigrationService.runIfNeeded()
        NSApp.setActivationPolicy(.accessory)
        DesktopContextProvider.shared.start()
        WebsiteBlockerService.shared.start()
        ScreenEffectsOverlayController.shared.start()
        BackgroundAgentCoordinator.shared.start()
        CalendarNudgeService.shared.start()
        ProactiveStudyService.shared.start()

        StickmanBlockPage.prepare()
        showStickman()
        configureStatusItem()
        StickmanBlocker.shared.start()
        ComputerUseService.shared.start()

        let hotKeyManager = HotKeyManager(
            onToggle: { [weak self] in DispatchQueue.main.async { self?.toggleStickman() } },
            onQuickAssist: { [weak self] in DispatchQueue.main.async { self?.quickAssist() } },
            onToggleCombat: { [weak self] in DispatchQueue.main.async { self?.toggleCombat() } },
            onOpenMenu: { [weak self] in DispatchQueue.main.async { self?.openMenu() } },
            onStartVoice: { [weak self] in DispatchQueue.main.async { self?.startVoiceMode() } }
        )
        hotKeyManager.register()
        self.hotKeyManager = hotKeyManager
        installRightClickTracking()
        startScreenShareGuard()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        for monitor in rightClickMonitors {
            NSEvent.removeMonitor(monitor)
        }
        rightClickMonitors.removeAll()
        ScreenShareMonitor.shared.stop()
        StickmanBlocker.shared.stop()
        if let screenShareObserver { NotificationCenter.default.removeObserver(screenShareObserver) }
        WebsiteBlockerService.shared.stop()
        ScreenEffectsOverlayController.shared.stop()
        BackgroundAgentCoordinator.shared.stop()
        CalendarNudgeService.shared.stop()
        ProactiveStudyService.shared.stop()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    /// Option+B: Stickman ducks into the notch, and comes back out on the next press.
    private func toggleStickman() {
        guard let controller = stickmanWindowController, isStickmanVisible, !controller.isHiddenForScreenShare else {
            showStickman()
            return
        }
        controller.toggleNotchHide()
    }

    /// Keeps a single Stickman. The copy launchd keeps alive for Stickman Blocker wins;
    /// a copy opened from Finder or the Dock hands off to it and exits.
    private func handOffToRunningCopy() -> Bool {
        let identifier = Bundle.main.bundleIdentifier ?? "com.chaymore.Stickman"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return false }
        if StickmanBlocker.shared.launchedByAgent {
            others.forEach { $0.terminate() }
            return false
        }
        others.first?.activate(options: [])
        NSApp.terminate(nil)
        return true
    }

    private func showStickman() {
        let controller = stickmanWindowController ?? StickmanWindowController()
        stickmanWindowController = controller
        isStickmanVisible = true
        // Asking for Stickman while sharing means the user wants him on screen anyway.
        if ScreenShareMonitor.shared.isSharing { showsDuringCurrentShare = true }
        applyScreenShareState()
        controller.showStickman()
    }

    private func startScreenShareGuard() {
        screenShareObserver = NotificationCenter.default.addObserver(
            forName: .stickmanScreenShareDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !ScreenShareMonitor.shared.isSharing { self.showsDuringCurrentShare = false }
                self.applyScreenShareState()
            }
        }
        ScreenShareMonitor.shared.start()
    }

    private func applyScreenShareState() {
        let hide = ScreenShareMonitor.shared.isSharing
            && StickmanSettingsPanelView.hidesDuringScreenShare
            && !showsDuringCurrentShare
        stickmanWindowController?.setHiddenForScreenShare(hide)
    }

    private func installRightClickTracking() {
        let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard HotKeyManager.isWalkClick(flags: event.modifierFlags) else { return }
            self?.walkStickman(to: NSEvent.mouseLocation)
        }

        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            if HotKeyManager.isWalkClick(flags: event.modifierFlags) {
                self?.walkStickman(to: NSEvent.mouseLocation)
            }
            return event
        }

        rightClickMonitors = [globalMonitor, localMonitor].compactMap { $0 }
    }

    private func walkStickman(to screenPoint: NSPoint) {
        guard isStickmanVisible, stickmanWindowController?.isHiddenForScreenShare != true else { return }
        DispatchQueue.main.async { [weak self] in
            self?.stickmanWindowController?.walkStickman(to: screenPoint)
        }
    }

    private func quickAssist() {
        summonIfNeeded()
        stickmanWindowController?.quickAssist()
    }

    private func openMenu() {
        summonIfNeeded()
        stickmanWindowController?.openMenu()
    }

    private func startVoiceMode() {
        summonIfNeeded()
        stickmanWindowController?.startVoiceMode()
    }

    private func toggleCombat() {
        summonIfNeeded()
        stickmanWindowController?.toggleCombatMode()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.menuBarIcon()
        item.button?.toolTip = "Stickman"

        let menu = NSMenu(title: "Stickman")
        menu.delegate = self
        let shareItem = menu.addItem(withTitle: "Hidden while your screen is shared", action: nil, keyEquivalent: "")
        shareItem.isEnabled = false
        shareItem.isHidden = true
        shareStatusMenuItem = shareItem
        showMenuItem = menu.addItem(withTitle: "Show Stickman", action: #selector(showStickmanFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Talk to Stickman", action: #selector(openChatFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Start Voice", action: #selector(startVoiceFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Claude Code Sessions", action: #selector(showClaudeSessionsFromMenu), keyEquivalent: "")
        let agentItem = menu.addItem(withTitle: "Background Agents", action: #selector(showAgentsFromMenu), keyEquivalent: "")
        agentStatusMenuItem = agentItem
        menu.addItem(.separator())
        let blockerHeader = menu.addItem(withTitle: "Stickman Blocker", action: nil, keyEquivalent: "")
        blockerHeader.isEnabled = false
        blockerStatusMenuItem = disabledItem(in: menu, indent: true)
        blockerScheduleMenuItem = disabledItem(in: menu, indent: true)
        blockerAllowanceMenuItems = [disabledItem(in: menu, indent: true), disabledItem(in: menu, indent: true)]
        menu.addItem(withTitle: "Night Routine…", action: #selector(openRoutineFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Protected Settings…", action: #selector(openProtectedSettingsFromMenu), keyEquivalent: "")
        blockerInstallMenuItem = menu.addItem(withTitle: "Install Blocker Helper…", action: #selector(installBlockerFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        menu.addItem(withTitle: "Permissions…", action: #selector(openPermissionsFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Connections…", action: #selector(openConnectionsFromMenu), keyEquivalent: "")
        notchMenuItem = menu.addItem(withTitle: "Hide in Notch", action: #selector(toggleNotchFromMenu), keyEquivalent: "")
        let stopFighting = menu.addItem(withTitle: "Stop Fighting", action: #selector(stopFightingFromMenu), keyEquivalent: "")
        stopFighting.isHidden = true
        stopFightingMenuItem = stopFighting
        menu.addItem(.separator())
        keepsRunningMenuItem = disabledItem(in: menu, indent: false)
        keepsRunningMenuItem?.title = "Stickman Blocker keeps Stickman running."
        quitMenuItem = menu.addItem(withTitle: "Quit Stickman", action: #selector(quitFromMenu), keyEquivalent: "q")
        for menuItem in menu.items where menuItem.action != nil { menuItem.target = self }
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        let count = BackgroundAgentCoordinator.shared.activeCount
        agentStatusMenuItem?.title = count == 0 ? "Background Agents" : "Background Agents (\(count) working)"
        let hiddenForShare = isStickmanVisible && stickmanWindowController?.isHiddenForScreenShare == true
        shareStatusMenuItem?.isHidden = !hiddenForShare
        showMenuItem?.title = hiddenForShare ? "Show Stickman Anyway" : "Show Stickman"
        stopFightingMenuItem?.isHidden = StickmanModeController.shared.mode != .sparring
        notchMenuItem?.title = stickmanWindowController?.isTuckedInNotch == true ? "Come Out of the Notch" : "Hide in Notch"

        let blocker = StickmanBlocker.shared
        blockerStatusMenuItem?.title = blocker.statusTitle
        blockerScheduleMenuItem?.title = blocker.scheduleLine ?? ""
        blockerScheduleMenuItem?.isHidden = blocker.scheduleLine == nil
        let allowances = blocker.allowanceLines
        for (index, item) in blockerAllowanceMenuItems.enumerated() {
            item.isHidden = !allowances.indices.contains(index)
            item.title = allowances.indices.contains(index) ? allowances[index] : ""
        }
        blockerInstallMenuItem?.title = blocker.needsMove ? "Move Blocker into Stickman…"
            : (blocker.isInstalled ? "Repair Blocker Helper…" : "Install Blocker Helper…")
        quitMenuItem?.isHidden = blocker.keepsStickmanRunning
        keepsRunningMenuItem?.isHidden = !blocker.keepsStickmanRunning
    }

    private func disabledItem(in menu: NSMenu, indent: Bool) -> NSMenuItem {
        let item = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = indent ? 1 : 0
        return item
    }

    @objc private func openRoutineFromMenu() { StickmanBlocker.shared.showRoutine() }

    @objc private func openProtectedSettingsFromMenu() { StickmanBlocker.shared.showProtectedSettings() }

    @objc private func installBlockerFromMenu() { StickmanBlocker.shared.installHelper() }

    @objc private func toggleNotchFromMenu() { toggleStickman() }

    @objc private func stopFightingFromMenu() {
        StickmanModeController.shared.setMode(.peaceful, reason: "menu")
    }

    @objc private func showStickmanFromMenu() {
        summonIfNeeded()
    }

    /// Shows Stickman if he is hidden by the user, by a screen share, or in the notch.
    private func summonIfNeeded() {
        if !isStickmanVisible || stickmanWindowController?.isHiddenForScreenShare == true
            || stickmanWindowController?.isTuckedInNotch == true {
            showStickman()
        }
    }

    @objc private func openChatFromMenu() { openMenu() }

    @objc private func startVoiceFromMenu() { startVoiceMode() }

    @objc private func showClaudeSessionsFromMenu() {
        summonIfNeeded()
        stickmanWindowController?.showClaudeSessions()
    }

    @objc private func showAgentsFromMenu() {
        summonIfNeeded()
        stickmanWindowController?.showAgentStatus()
    }

    @objc private func openSettingsFromMenu() {
        summonIfNeeded()
        stickmanWindowController?.openSettings()
    }

    @objc private func openPermissionsFromMenu() {
        summonIfNeeded()
        stickmanWindowController?.openPermissions()
    }

    @objc private func openConnectionsFromMenu() {
        summonIfNeeded()
        stickmanWindowController?.openConnections()
    }

    @objc private func quitFromMenu() { NSApp.terminate(nil) }

    private static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setStroke()
            let head = NSBezierPath(ovalIn: NSRect(x: 6, y: 11, width: 6, height: 6))
            head.lineWidth = 1.8
            head.stroke()
            let body = NSBezierPath()
            body.lineWidth = 1.8
            body.lineCapStyle = .round
            body.move(to: NSPoint(x: 9, y: 11))
            body.line(to: NSPoint(x: 9, y: 5.5))
            body.move(to: NSPoint(x: 9, y: 9))
            body.line(to: NSPoint(x: 5.5, y: 7))
            body.move(to: NSPoint(x: 9, y: 9))
            body.line(to: NSPoint(x: 12.5, y: 7))
            body.move(to: NSPoint(x: 9, y: 5.5))
            body.line(to: NSPoint(x: 6.5, y: 1.5))
            body.move(to: NSPoint(x: 9, y: 5.5))
            body.line(to: NSPoint(x: 11.5, y: 1.5))
            body.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
