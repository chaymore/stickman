import AppKit
import NightLockCore

/// Stickman Blocker, the protected website blocker formerly called NightLock. A root daemon
/// enforces it through /etc/hosts. Stickman shows its status, redirects blocked browser
/// tabs, hosts Protected Settings and the Night Routine window, and installs the helper.
@MainActor
final class StickmanBlocker {
    static let shared = StickmanBlocker()

    /// Bundle identifier of the standalone app the blocker used to ship as.
    private static let legacyBundleIdentifier = "com.chaymore.NightLock"

    private let browserBlocker = BrowserBlockerService()
    private var browserBlockerRunning = false
    private var settingsController: BlockerSettingsWindowController?
    private var routineController: RoutineWindowController?
    private var refreshTimer: Timer?
    private var promptedForMove = false

    private init() {}

    /// The protected configuration exists, so the daemon has been installed at some point.
    nonisolated var isInstalled: Bool { FileManager.default.fileExists(atPath: NightLockPaths.config) }

    /// launchd started this copy of Stickman and will restart it if it exits.
    var launchedByAgent: Bool {
        ProcessInfo.processInfo.environment[NightLockPaths.agentEnvironmentKey] == "1"
    }

    /// True while the login agent still launches the old standalone app instead of Stickman.
    var needsMove: Bool {
        guard isInstalled else { return false }
        guard let plist = NSDictionary(contentsOfFile: NightLockPaths.agentPlist),
              let arguments = plist["ProgramArguments"] as? [String]
        else { return true }
        return arguments.first != NightLockPaths.appLauncher
    }

    /// Once moved, the agent keeps Stickman running, so the app has no Quit command.
    var keepsStickmanRunning: Bool { isInstalled && !needsMove }

    private var legacyAppRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.legacyBundleIdentifier).isEmpty
    }

    func start() {
        refresh()
        let timer = Timer(timeInterval: 3, repeats: true) { _ in
            Task { @MainActor in StickmanBlocker.shared.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        if needsMove {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.promptToFinishMove() }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if browserBlockerRunning { browserBlocker.stop() }
        browserBlockerRunning = false
    }

    /// Runs browser redirects only once the blocker is installed and the old app has stopped,
    /// since both would serve the block page on the same port.
    func refresh() {
        let shouldRun = isInstalled && !legacyAppRunning
        if shouldRun, !browserBlockerRunning {
            browserBlocker.start()
            browserBlockerRunning = true
        } else if !shouldRun, browserBlockerRunning {
            browserBlocker.stop()
            browserBlockerRunning = false
        }
    }

    // MARK: Status

    nonisolated var status: NightLockStatus? { try? NightLockFiles.loadStatus() }

    var statusTitle: String {
        guard isInstalled else { return "Not installed" }
        guard let status else { return "Helper isn't responding" }
        if status.active { return "Blocking is active" }
        return status.enabled ? "Waiting for protected hours" : "Enforcement disabled"
    }

    /// One line, for chat and settings. Readable from any thread.
    nonisolated static var statusSummary: String {
        let isInstalled = FileManager.default.fileExists(atPath: NightLockPaths.config)
        return describe(installed: isInstalled, status: try? NightLockFiles.loadStatus())
    }

    nonisolated var shortStatus: String { Self.statusSummary }

    private nonisolated static func describe(installed isInstalled: Bool, status: NightLockStatus?) -> String {
        guard isInstalled else { return "Stickman Blocker isn't installed." }
        guard let status else { return "Stickman Blocker is installed, but its helper isn't responding." }
        if status.active { return "Stickman Blocker is enforcing \(status.schedule)." }
        if status.enabled { return "Stickman Blocker is armed for \(status.schedule)." }
        return "Stickman Blocker is installed but disabled."
    }

    var scheduleLine: String? { status?.schedule }

    var allowanceLines: [String] {
        guard let status else { return [] }
        let remaining = status.allowanceRemainingSeconds ?? [:]
        let bypasses = Set(status.dailyBypassDomains ?? [])
        let modes = status.siteAccessModes ?? [:]
        return [("Instagram", "instagram.com", 30 * 60), ("X", "x.com", 10 * 60)].map { name, domain, defaultSeconds in
            if bypasses.contains(domain) { return "\(name): unlimited today" }
            switch modes[domain] ?? .allowance {
            case .unrestricted: return "\(name): open now"
            case .blocked: return "\(name): blocked until its window"
            case .allowance:
                let seconds = max(0, remaining[domain] ?? defaultSeconds)
                return String(format: "%@: %d:%02d left today", name, seconds / 60, seconds % 60)
            }
        }
    }

    // MARK: Windows

    func showRoutine() {
        let controller = routineController ?? RoutineWindowController { [weak self] in self?.showProtectedSettings() }
        routineController = controller
        controller.present()
    }

    func showProtectedSettings() {
        let controller = settingsController ?? BlockerSettingsWindowController()
        settingsController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Install

    /// Installs or repairs the root helper. macOS asks for an administrator password.
    /// Reinstalling keeps the existing recovery key and protected schedule.
    func installHelper() {
        guard Bundle.main.bundlePath == NightLockPaths.installedApp else {
            showAlert(
                title: "Install Stickman first",
                message: "Stickman Blocker installs from /Applications/Stickman.app. Install that copy, open it, and try again."
            )
            return
        }
        let installer = NightLockPaths.bundledInstaller
        guard FileManager.default.isExecutableFile(atPath: installer) else {
            showAlert(title: "Installer missing", message: "Rebuild or reinstall Stickman.app and try again.")
            return
        }

        let escaped = installer.replacingOccurrences(of: "'", with: "'\\''")
        guard let script = NSAppleScript(source: "do shell script \"'\(escaped)'\" with administrator privileges") else { return }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            let cancelled = (error[NSAppleScript.errorNumber] as? Int) == -128
            if !cancelled { showAlert(title: "Installation failed", message: error.description) }
        } else {
            refresh()
            showAlert(
                title: "Stickman Blocker is installed",
                message: "The protected helper is running, and Stickman now starts at login and keeps running."
            )
        }
    }

    private func promptToFinishMove() {
        guard needsMove, !promptedForMove else { return }
        promptedForMove = true
        let alert = NSAlert()
        alert.messageText = "Move your blocker into Stickman"
        alert.informativeText = "NightLock is now Stickman Blocker, built into Stickman. One administrator approval moves the protected helper over and retires Night Routine.app. Your schedule and recovery key stay the same."
        alert.addButton(withTitle: "Move Now")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { installHelper() }
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
