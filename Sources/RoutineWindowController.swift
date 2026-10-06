// Night Routine window: Stickman Blocker's live site status plus controls for the nightly Journal Time job.
// Site rules are read-only here. Changing them still goes through Protected Settings and the recovery key.
import AppKit
import NightLockCore
import SwiftUI

// MARK: - Stickman Blocker status

struct SiteRow: Identifiable {
    let id: String
    let name: String
    let state: String
    let open: Bool
    let schedule: String
}

private let siteNames = [
    "instagram.com": "Instagram", "x.com": "X", "youtube.com": "YouTube", "linkedin.com": "LinkedIn",
    "reddit.com": "Reddit", "netflix.com": "Netflix", "messenger.com": "Messenger",
]

private func clockText(_ minute: Int) -> String {
    let m = minute % 1440
    let h = m / 60, mm = m % 60
    let h12 = h % 12 == 0 ? 12 : h % 12
    let suffix = h < 12 ? "AM" : "PM"
    return mm == 0 ? "\(h12) \(suffix)" : String(format: "%d:%02d %@", h12, mm, suffix)
}

private func scheduleText(_ policy: SiteAccessPolicy) -> String {
    var parts: [String] = []
    if let open = policy.unrestrictedWindow {
        parts.append("Open \(clockText(open.startMinute))–\(clockText(open.endMinute))")
    }
    if let minutes = policy.allowanceMinutes, minutes > 0 {
        if let window = policy.allowanceWindow {
            parts.append("\(minutes) min \(clockText(window.startMinute))–\(clockText(window.endMinute))")
        } else {
            parts.append("\(minutes) min a day")
        }
    }
    parts.append("otherwise locked")
    return parts.joined(separator: " · ")
}

private func loadSites() -> (rows: [SiteRow], note: String) {
    guard let config = try? NightLockFiles.loadConfig() else {
        return ([], "The system helper isn't installed.")
    }
    let status = try? NightLockFiles.loadStatus()
    let policies = config.siteAccessPolicies ?? [:]

    // One row per canonical site; aliases like twitter.com fold into x.com.
    var seen = Set<String>()
    let domains = config.blockedDomains.compactMap { domain -> String? in
        let key = NightLockFiles.allowanceKey(for: domain) ?? NightLockFiles.normalizedDomain(domain)
        return seen.insert(key).inserted ? key : nil
    }

    let rows = domains.map { domain -> SiteRow in
        let name = siteNames[domain] ?? domain
        guard let policy = policies[domain] else {
            return SiteRow(id: domain, name: name, state: "Locked", open: false, schedule: "Always locked")
        }
        let bypassed = status?.dailyBypassDomains?.contains(domain) == true
        let mode = bypassed ? .unrestricted : (status?.siteAccessModes?[domain] ?? .blocked)
        let left = status?.allowanceRemainingSeconds?[domain] ?? 0
        let state: String
        let open: Bool
        switch mode {
        case .unrestricted:
            state = bypassed ? "Open today" : "Open"; open = true
        case .allowance where left > 0:
            state = String(format: "%d:%02d left", left / 60, left % 60); open = true
        case .allowance:
            state = "Used up today"; open = false
        case .blocked:
            state = "Locked"; open = false
        }
        return SiteRow(id: domain, name: name, state: state, open: open, schedule: scheduleText(policy))
    }
    .sorted { ($0.open ? 0 : 1, $0.name) < ($1.open ? 0 : 1, $1.name) }

    let note: String
    if !config.enabled {
        note = "Enforcement disabled"
    } else if let status, Date().timeIntervalSince(status.updatedAt) < 30 {
        note = "Enforcing"
    } else {
        note = "System helper isn't responding"
    }
    return (rows, note)
}

// MARK: - Journal Time job

private let home = FileManager.default.homeDirectoryForCurrentUser.path
private let journalLabel = "com.calebhaymore.journal-time"
private let journalPlist = home + "/Library/LaunchAgents/\(journalLabel).plist"
private let keepListPath = home + "/Library/Application Support/JournalTime/keep.txt"
private let journalApp = home + "/Applications/Journal Time.app"
private let userDomain = "gui/\(getuid())"

@discardableResult
private func launchctl(_ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}

private func journalLoaded() -> Bool { launchctl(["print", "\(userDomain)/\(journalLabel)"]) == 0 }

private func setJournal(_ on: Bool) {
    if on {
        launchctl(["bootstrap", userDomain, journalPlist])
    } else {
        launchctl(["bootout", "\(userDomain)/\(journalLabel)"])
    }
}

private func readJournalTime() -> Date {
    var hour = 22, minute = 0
    if let plist = NSDictionary(contentsOfFile: journalPlist),
       let interval = plist["StartCalendarInterval"] as? [String: Int] {
        hour = interval["Hour"] ?? 22
        minute = interval["Minute"] ?? 0
    }
    return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
}

private func writeJournalTime(_ date: Date) {
    guard let plist = NSMutableDictionary(contentsOfFile: journalPlist) else { return }
    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
    plist["StartCalendarInterval"] = ["Hour": parts.hour ?? 22, "Minute": parts.minute ?? 0]
    plist.write(toFile: journalPlist, atomically: true)
    // launchd only rereads the schedule on load.
    if journalLoaded() {
        setJournal(false)
        setJournal(true)
    }
}

struct KeptApp: Identifiable, Hashable {
    let id: String
    let name: String
}

private func appName(_ bundleID: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
    return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
}

private func readKeepList() -> [KeptApp] {
    let text = (try? String(contentsOfFile: keepListPath, encoding: .utf8)) ?? ""
    return text.split(whereSeparator: \.isNewline)
        .map(String.init)
        .filter { !$0.isEmpty }
        .map { KeptApp(id: $0, name: appName($0)) }
}

private func writeKeepList(_ apps: [KeptApp]) {
    let directory = (keepListPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try? (apps.map(\.id).joined(separator: "\n") + "\n").write(toFile: keepListPath, atomically: true, encoding: .utf8)
}

// MARK: - Model

final class RoutineModel: ObservableObject {
    @Published var sites: [SiteRow] = []
    @Published var lockNote = ""
    @Published var journalOn = false
    @Published var journalTime = readJournalTime()
    @Published var kept = readKeepList()
    let openProtectedSettings: () -> Void
    private var timer: Timer?

    init(openProtectedSettings: @escaping () -> Void) {
        self.openProtectedSettings = openProtectedSettings
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let loaded = loadSites()
        sites = loaded.rows
        lockNote = loaded.note
        journalOn = journalLoaded()
    }

    func toggleJournal(_ on: Bool) {
        setJournal(on)
        journalOn = journalLoaded()
    }

    func saveTime(_ date: Date) {
        journalTime = date
        writeJournalTime(date)
    }

    func addApps() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, !kept.contains(where: { $0.id == id }) else { continue }
            kept.append(KeptApp(id: id, name: appName(id)))
        }
        writeKeepList(kept)
    }

    func remove(_ app: KeptApp) {
        kept.removeAll { $0 == app }
        writeKeepList(kept)
    }

    func startNow() {
        let alert = NSAlert()
        alert.messageText = "Start Journal Time now?"
        alert.informativeText = "This hides your open apps and opens today's journal note. Nothing is closed."
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: journalApp))
        }
    }
}

// MARK: - Views

private struct Card<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

struct RoutineView: View {
    @ObservedObject var model: RoutineModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Card(title: "Stickman Blocker", subtitle: model.lockNote) {
                    VStack(spacing: 0) {
                        ForEach(model.sites) { site in
                            HStack(alignment: .firstTextBaseline) {
                                Circle().fill(site.open ? Color.green : Color.red).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(site.name)
                                    Text(site.schedule).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(site.state).monospacedDigit().foregroundStyle(site.open ? .primary : .secondary)
                            }
                            .padding(.vertical, 6)
                            if site.id != model.sites.last?.id { Divider() }
                        }
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text("Changing a rule needs your recovery key.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Protected Settings…") { model.openProtectedSettings() }
                    }
                }

                Card(title: "Journal Time", subtitle: model.journalOn ? "On" : "Off") {
                    Toggle("Run every night", isOn: Binding(get: { model.journalOn }, set: { model.toggleJournal($0) }))
                    DatePicker(
                        "Time",
                        selection: Binding(get: { model.journalTime }, set: { model.saveTime($0) }),
                        displayedComponents: .hourAndMinute
                    )
                    .frame(maxWidth: 220)
                    Divider()
                    Text("Leave these visible").font(.subheadline)
                    Text("Every other app is hidden, not quit. Obsidian always stays visible.").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.kept) { app in
                        HStack {
                            Text(app.name)
                            Spacer()
                            Button("Remove") { model.remove(app) }.buttonStyle(.link)
                        }
                    }
                    HStack {
                        Button("Add App…") { model.addApps() }
                        Spacer()
                        Button("Start Now") { model.startNow() }
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 560, idealHeight: 640)
    }
}

final class RoutineWindowController: NSWindowController, NSWindowDelegate {
    init(openProtectedSettings: @escaping () -> Void) {
        let model = RoutineModel(openProtectedSettings: openProtectedSettings)
        let window = NSWindow(contentViewController: NSHostingController(rootView: RoutineView(model: model)))
        window.title = "Night Routine"
        window.setContentSize(NSSize(width: 460, height: 640))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        // Show a Dock icon while the window is open; go back to menu-bar-only when it closes.
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
