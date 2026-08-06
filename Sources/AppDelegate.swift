import AppKit
import Dispatch

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var stickmanWindowController: StickmanWindowController?
    private var hotKeyManager: HotKeyManager?
    private var statusItem: NSStatusItem?
    private var agentStatusMenuItem: NSMenuItem?
    private var rightClickMonitors: [Any] = []
    private var isStickmanVisible = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        LegacyMigrationService.runIfNeeded()
        NSApp.setActivationPolicy(.accessory)
        DesktopContextProvider.shared.start()
        WebsiteBlockerService.shared.start()
        ScreenEffectsOverlayController.shared.start()
        BackgroundAgentCoordinator.shared.start()
        CalendarNudgeService.shared.start()
        ProactiveStudyService.shared.start()

        showStickman()
        configureStatusItem()

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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        for monitor in rightClickMonitors {
            NSEvent.removeMonitor(monitor)
        }
        rightClickMonitors.removeAll()
        WebsiteBlockerService.shared.stop()
        ScreenEffectsOverlayController.shared.stop()
        BackgroundAgentCoordinator.shared.stop()
        CalendarNudgeService.shared.stop()
        ProactiveStudyService.shared.stop()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    private func toggleStickman() {
        if isStickmanVisible {
            hideStickman()
        } else {
            showStickman()
        }
    }

    private func showStickman() {
        let controller = stickmanWindowController ?? StickmanWindowController()
        controller.showStickman()
        stickmanWindowController = controller
        isStickmanVisible = true
    }

    private func hideStickman() {
        stickmanWindowController?.hideStickman()
        isStickmanVisible = false
    }

    private func installRightClickTracking() {
        let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown) { [weak self] _ in
            self?.walkStickman(to: NSEvent.mouseLocation)
        }

        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            self?.walkStickman(to: NSEvent.mouseLocation)
            return event
        }

        rightClickMonitors = [globalMonitor, localMonitor].compactMap { $0 }
    }

    private func walkStickman(to screenPoint: NSPoint) {
        guard isStickmanVisible else { return }
        DispatchQueue.main.async { [weak self] in
            self?.stickmanWindowController?.walkStickman(to: screenPoint)
        }
    }

    private func quickAssist() {
        if !isStickmanVisible { showStickman() }
        stickmanWindowController?.quickAssist()
    }

    private func openMenu() {
        if !isStickmanVisible { showStickman() }
        stickmanWindowController?.openMenu()
    }

    private func startVoiceMode() {
        if !isStickmanVisible { showStickman() }
        stickmanWindowController?.startVoiceMode()
    }

    private func toggleCombat() {
        if !isStickmanVisible { showStickman() }
        stickmanWindowController?.toggleCombatMode()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.menuBarIcon()
        item.button?.toolTip = "Stickman"

        let menu = NSMenu(title: "Stickman")
        menu.delegate = self
        menu.addItem(withTitle: "Show Stickman", action: #selector(showStickmanFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Talk to Stickman", action: #selector(openChatFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Start Voice", action: #selector(startVoiceFromMenu), keyEquivalent: "")
        let agentItem = menu.addItem(withTitle: "Background Agents", action: #selector(showAgentsFromMenu), keyEquivalent: "")
        agentStatusMenuItem = agentItem
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        menu.addItem(withTitle: "Permissions…", action: #selector(openPermissionsFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Connections…", action: #selector(openConnectionsFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Hide Stickman", action: #selector(hideStickmanFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Stickman", action: #selector(quitFromMenu), keyEquivalent: "q")
        for menuItem in menu.items { menuItem.target = self }
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        let count = BackgroundAgentCoordinator.shared.activeCount
        agentStatusMenuItem?.title = count == 0 ? "Background Agents" : "Background Agents (\(count) working)"
    }

    @objc private func showStickmanFromMenu() {
        if !isStickmanVisible { showStickman() }
    }

    @objc private func openChatFromMenu() { openMenu() }

    @objc private func startVoiceFromMenu() { startVoiceMode() }

    @objc private func showAgentsFromMenu() {
        if !isStickmanVisible { showStickman() }
        stickmanWindowController?.showAgentStatus()
    }

    @objc private func openSettingsFromMenu() {
        if !isStickmanVisible { showStickman() }
        stickmanWindowController?.openSettings()
    }

    @objc private func openPermissionsFromMenu() {
        if !isStickmanVisible { showStickman() }
        stickmanWindowController?.openPermissions()
    }

    @objc private func openConnectionsFromMenu() {
        if !isStickmanVisible { showStickman() }
        stickmanWindowController?.openConnections()
    }

    @objc private func hideStickmanFromMenu() { hideStickman() }

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
