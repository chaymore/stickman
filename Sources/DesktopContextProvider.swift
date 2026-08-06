import AppKit
import CoreGraphics

struct DesktopContext {
    let appName: String?
    let bundleIdentifier: String?
    let windowTitle: String?
    let windowNumber: CGWindowID?
    let windowFrame: NSRect?
    let updatedAt: Date

    var stableWindowIdentity: String? {
        guard let bundleIdentifier, let windowNumber else { return nil }
        return "\(bundleIdentifier):\(windowNumber)"
    }

    var promptSummary: String {
        var lines: [String] = []

        if let appName, !appName.isEmpty {
            lines.append("Foreground app: \(appName)")
        }

        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            lines.append("Bundle identifier: \(bundleIdentifier)")
        }

        if let windowTitle, !windowTitle.isEmpty {
            lines.append("Active window title: \(windowTitle)")
        }

        if lines.isEmpty {
            return "No foreground app or window title is currently available."
        }

        return lines.joined(separator: "\n")
    }
}

final class DesktopContextProvider {
    static let shared = DesktopContextProvider()

    private var timer: Timer?
    private var latestContext = DesktopContext(
        appName: nil,
        bundleIdentifier: nil,
        windowTitle: nil,
        windowNumber: nil,
        windowFrame: nil,
        updatedAt: Date()
    )
    private let currentProcessID = ProcessInfo.processInfo.processIdentifier

    private init() {}

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func currentContext() -> DesktopContext {
        refresh()
        return latestContext
    }

    private func refresh() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return
        }

        if app.processIdentifier == currentProcessID {
            return
        }

        let activeWindow = activeWindow(for: app)
        latestContext = DesktopContext(
            appName: app.localizedName,
            bundleIdentifier: app.bundleIdentifier,
            windowTitle: activeWindow?.title,
            windowNumber: activeWindow?.number,
            windowFrame: activeWindow?.frame,
            updatedAt: Date()
        )
    }

    private func activeWindow(for app: NSRunningApplication) -> (title: String?, number: CGWindowID, frame: NSRect)? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windows {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == app.processIdentifier,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0
            else {
                continue
            }

            guard let number = window[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let cgBounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  cgBounds.width >= 180,
                  cgBounds.height >= 120
            else { continue }

            let title = (window[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
            let appKitFrame = NSRect(
                x: cgBounds.minX,
                y: mainDisplayHeight - cgBounds.maxY,
                width: cgBounds.width,
                height: cgBounds.height
            )
            return (title?.isEmpty == true ? nil : title, number, appKitFrame)
        }

        return nil
    }
}
