import AppKit
import Foundation
import NightLockCore

final class NightLockAppDelegate: NSObject, NSApplicationDelegate {
    private let browserBlocker = BrowserBlockerService()
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var scheduleMenuItem: NSMenuItem?
    private var refreshTimer: Timer?
    private var settingsController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        browserBlocker.start()
        refreshStatus()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        if let refreshTimer { RunLoop.main.add(refreshTimer, forMode: .common) }

        if !FileManager.default.fileExists(atPath: NightLockPaths.config) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showInstallPrompt()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        browserBlocker.stop()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: "NightLock")
        item.button?.toolTip = "NightLock"

        let menu = NSMenu()
        let title = NSMenuItem(title: "NightLock", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let status = NSMenuItem(title: "Status unavailable", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusMenuItem = status

        let schedule = NSMenuItem(title: "10:00 PM to 5:00 AM", action: nil, keyEquivalent: "")
        schedule.isEnabled = false
        menu.addItem(schedule)
        scheduleMenuItem = schedule

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Protected Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Install or Repair System Helper...", action: #selector(installSystemHelper), keyEquivalent: ""))
        menu.items.suffix(2).forEach { $0.target = self }

        let note = NSMenuItem(title: "Quitting the UI does not stop enforcement.", action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(note)

        item.menu = menu
        statusItem = item
    }

    private func refreshStatus() {
        if let status = try? NightLockFiles.loadStatus() {
            statusMenuItem?.title = status.active ? "Blocking is active" : (status.enabled ? "Waiting for bedtime" : "Enforcement disabled")
            scheduleMenuItem?.title = status.schedule
            statusItem?.button?.image = NSImage(
                systemSymbolName: status.active ? "lock.shield.fill" : "lock.shield",
                accessibilityDescription: "NightLock"
            )
        } else if FileManager.default.fileExists(atPath: NightLockPaths.config) {
            statusMenuItem?.title = "System helper is not responding"
        } else {
            statusMenuItem?.title = "Installation required"
        }
    }

    @objc private func showSettings() {
        let controller = settingsController ?? SettingsWindowController()
        settingsController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func installSystemHelper() {
        let installer = Bundle.main.bundlePath + "/Contents/MacOS/NightLockInstaller"
        guard FileManager.default.fileExists(atPath: installer) else {
            showAlert(title: "Installer missing", message: "Rebuild or reinstall NightLock.app and try again.")
            return
        }

        let escaped = installer.replacingOccurrences(of: "'", with: "'\\''")
        let script = "do shell script \"'\(escaped)'\" with administrator privileges"
        guard let appleScript = NSAppleScript(source: script) else { return }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)

        if let error {
            showAlert(title: "Installation failed", message: error.description)
        } else {
            showAlert(title: "NightLock installed", message: "The protected daemon and login agent are now registered.")
            refreshStatus()
        }
    }

    private func showInstallPrompt() {
        let alert = NSAlert()
        alert.messageText = "NightLock needs its system helper"
        alert.informativeText = "One administrator approval installs the always-running protected daemon and login agent."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { installSystemHelper() }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
