import AppKit
import Foundation

struct ActionResult {
    let userVisibleMessage: String
}

@MainActor
final class ActionRunner {
    static let shared = ActionRunner()

    private init() {}

    func handleIfAction(_ input: String) -> ActionResult? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = text.lowercased()

        if let agentResult = handleAgentAction(text) {
            return agentResult
        }

        if let browserResult = handleBrowserAction(text) {
            return browserResult
        }

        if let calendarResult = handleCalendarAction(text) {
            return calendarResult
        }

        if let modeResult = handleModeAction(text) {
            return modeResult
        }

        if let focusResult = handleFocusAction(text) {
            return focusResult
        }

        if let windowResult = handleWindowAction(text) {
            return windowResult
        }

        if let blockerResult = handleWebsiteBlockerAction(text) {
            return blockerResult
        }

        if let url = firstURL(in: text),
           lowercased.hasPrefix("open ") || lowercased.hasPrefix("go to ") || lowercased.hasPrefix("launch ") {
            return openURL(url)
        }

        if let appName = parseAppName(from: text) {
            return openApp(named: appName)
        }

        if let path = parsePath(from: text) {
            return openPath(path)
        }

        if let clipboardText = parseClipboardText(from: text) {
            return copyToClipboard(clipboardText)
        }

        if let reminderTitle = parseReminderTitle(from: text) {
            return createReminder(title: reminderTitle)
        }

        return nil
    }

    private func handleAgentAction(_ text: String) -> ActionResult? {
        if matches(text, pattern: #"(?i)^(?:show|list|what(?:'s| is))\s+(?:my\s+)?(?:upcoming\s+)?canvas\s+(?:homework|assignments|work)[?!. ]*$"#) {
            guard ConnectorRegistryService.shared.status(for: .canvas) == .connected else {
                return ActionResult(userVisibleMessage: "Canvas is not connected yet. Open Settings → Connections and add a read-only Canvas token.")
            }
            let task = BackgroundAgentCoordinator.shared.spawn(
                prompt: "Summarize my upcoming Canvas assignments in due-date order. Flag anything due within 48 hours and include direct assignment links."
            )
            StickmanTaskAnimationController.play(.spawnAgent)
            return ActionResult(userVisibleMessage: "Agent \(task.id) is checking Canvas in the background.")
        }

        if matches(text, pattern: #"(?i)^(?:show|list)\s+(?:my\s+)?(?:background\s+)?agents[?!. ]*$"#)
            || matches(text, pattern: #"(?i)^(?:agent|agents)\s+status[?!. ]*$"#) {
            return ActionResult(userVisibleMessage: BackgroundAgentCoordinator.shared.compactSummary)
        }

        if let taskID = firstCapture(in: text, pattern: #"(?i)^cancel\s+(?:background\s+)?agent\s+([a-z0-9-]+)[?!. ]*$"#) {
            let normalizedID = taskID.lowercased()
            guard BackgroundAgentCoordinator.shared.tasks.contains(where: { $0.id == normalizedID }) else {
                return ActionResult(userVisibleMessage: "I could not find an agent named \(normalizedID).")
            }
            BackgroundAgentCoordinator.shared.cancel(taskID: normalizedID)
            return ActionResult(userVisibleMessage: "Cancelled agent \(normalizedID).")
        }

        guard let prompt = StickmanAgentCommandParser.taskPrompt(from: text) else { return nil }
        let task = BackgroundAgentCoordinator.shared.spawn(prompt: prompt)
        StickmanTaskAnimationController.play(.spawnAgent)
        let tabNote = task.opensBrowserLinks ? " I’ll open the useful Chrome tabs when it finishes." : ""
        return ActionResult(userVisibleMessage: "Agent \(task.id) is working in the background. You can keep using Stickman.\(tabNote)")
    }

    private func handleBrowserAction(_ text: String) -> ActionResult? {
        if matches(text, pattern: #"(?i)^(?:show|list|what are)\s+(?:my\s+)?(?:open\s+)?chrome tabs[?!. ]*$"#) {
            return ActionResult(userVisibleMessage: BrowserControlService.shared.summary())
        }

        if let query = firstCapture(
            in: text,
            pattern: #"(?i)^(?:switch|go|jump)\s+to\s+(?:the\s+)?(?:chrome\s+)?tab\s+(?:named\s+)?(.+)$"#
        ) {
            do {
                let tab = try BrowserControlService.shared.activateTab(matching: cleanTrailingPunctuation(query))
                StickmanTaskAnimationController.play(.openBrowserTab)
                return ActionResult(userVisibleMessage: "Switched to \(tab.title).")
            } catch {
                return ActionResult(userVisibleMessage: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }

        if let query = firstCapture(
            in: text,
            pattern: #"(?i)^(?:search|google)\s+(?:the\s+web\s+)?(?:in\s+chrome\s+)?(?:for\s+)?(.+)$"#
        ) {
            do {
                _ = try BrowserControlService.shared.searchGoogle(for: cleanTrailingPunctuation(query))
                StickmanTaskAnimationController.play(.openBrowserTab)
                return ActionResult(userVisibleMessage: "Opened a Chrome search for \(cleanTrailingPunctuation(query)).")
            } catch {
                return ActionResult(userVisibleMessage: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }

        let destination = firstCapture(
            in: text,
            pattern: #"(?i)^open\s+(?:a\s+)?(?:new\s+)?(?:chrome\s+)?tab(?:\s+(?:to|for))?\s+(.+)$"#
        ) ?? firstCapture(
            in: text,
            pattern: #"(?i)^open\s+(.+?)\s+in\s+(?:google\s+)?chrome[?!. ]*$"#
        )

        guard let destination else { return nil }
        let cleaned = cleanTrailingPunctuation(destination)
        do {
            if let url = BrowserControlService.resolvedURL(from: cleaned) {
                _ = try BrowserControlService.shared.openChromeTab(url)
                StickmanTaskAnimationController.play(.openBrowserTab)
                return ActionResult(userVisibleMessage: "Opened \(url.absoluteString) in Chrome.")
            }
            _ = try BrowserControlService.shared.searchGoogle(for: cleaned)
            StickmanTaskAnimationController.play(.openBrowserTab)
            return ActionResult(userVisibleMessage: "Opened a Chrome search for \(cleaned).")
        } catch {
            return ActionResult(userVisibleMessage: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func handleCalendarAction(_ text: String) -> ActionResult? {
        if matches(text, pattern: #"(?i)^(?:what(?:'s| is)|show me)\s+(?:on\s+)?my calendar(?:\s+today)?[?!. ]*$"#)
            || matches(text, pattern: #"(?i)^(?:today(?:'s)?\s+)?(?:calendar|schedule)[?!. ]*$"#) {
            StickmanTaskAnimationController.play(.checkCalendar)
            return ActionResult(userVisibleMessage: CalendarService.shared.todaySummary())
        }

        if let hoursText = firstCapture(
            in: text,
            pattern: #"(?i)^(?:show\s+)?(?:my\s+)?(?:calendar|schedule|meetings|classes)\s+(?:for\s+)?(?:the\s+)?next\s+(\d{1,3})\s+hours?[?!. ]*$"#
        ), let hours = Int(hoursText) {
            StickmanTaskAnimationController.play(.checkCalendar)
            return ActionResult(userVisibleMessage: CalendarService.shared.upcomingSummary(hours: hours))
        }

        if matches(text, pattern: #"(?i)^(?:show\s+)?(?:my\s+)?(?:upcoming\s+)?(?:meetings|classes|schedule)[?!. ]*$"#) {
            StickmanTaskAnimationController.play(.checkCalendar)
            return ActionResult(userVisibleMessage: CalendarService.shared.upcomingSummary())
        }

        if matches(text, pattern: #"(?i)^(?:connect|enable|grant)\s+(?:my\s+)?calendar(?:\s+access)?[?!. ]*$"#) {
            PermissionCenterService.shared.request(.calendar)
            return ActionResult(userVisibleMessage: "I opened the macOS Calendar permission request. Stickman only reads calendars you already sync into Calendar.app.")
        }

        return nil
    }

    private func handleModeAction(_ text: String) -> ActionResult? {
        if matches(text, pattern: #"(?i)^(?:(?:hey\s+)?(?:stickman|stick\s*man)[, ]*)?(?:do you want to |wanna |want to )?(?:spar|fight)(?:\s+(?:me|my cursor))?[?!. ]*$"#)
            || matches(text, pattern: #"(?i)^(?:let(?:'s| us)\s+)?(?:spar|fight|start combat|combat mode)[?!. ]*$"#) {
            return ActionResult(userVisibleMessage: "Triple-click me when you want to spar. I won't start a fight from a hover, a cursor hit, or a voice command.")
        }

        if matches(text, pattern: #"(?i)^(?:truce|peace|calm down|stop fighting|end (?:the )?(?:fight|spar)|peaceful mode)[?!. ]*$"#) {
            StickmanModeController.shared.setMode(.peaceful, reason: "spoken truce")
            return ActionResult(userVisibleMessage: "Truce. Back to being useful.")
        }

        if matches(text, pattern: #"(?i)^(?:what|which) mode are you in[?!. ]*$"#) {
            return ActionResult(userVisibleMessage: "I am in \(StickmanModeController.shared.mode.displayName.lowercased()) mode.")
        }
        return nil
    }

    private func handleFocusAction(_ text: String) -> ActionResult? {
        if let value = firstCapture(
            in: text,
            pattern: #"(?i)^(?:start\s+)?(?:a\s+)?(?:focus|pomodoro)(?:\s+session)?(?:\s+for)?\s+(\d{1,3})\s*(?:minutes?|mins?)?[?!. ]*$"#
        ), let minutes = Int(value) {
            return ActionResult(userVisibleMessage: WebsiteBlockerService.shared.startFocusSession(minutes: minutes))
        }

        if matches(text, pattern: #"(?i)^(?:start\s+)?(?:a\s+)?pomodoro(?:\s+session)?[?!. ]*$"#)
            || matches(text, pattern: #"(?i)^help me focus[?!. ]*$"#) {
            return ActionResult(userVisibleMessage: WebsiteBlockerService.shared.startFocusSession(minutes: 25))
        }

        if matches(text, pattern: #"(?i)^(?:end|stop|cancel)\s+(?:the\s+)?focus(?:\s+session)?[?!. ]*$"#) {
            return ActionResult(userVisibleMessage: WebsiteBlockerService.shared.endFocusSession())
        }

        if matches(text, pattern: #"(?i)^(?:focus status|how (?:much|long).*focus|how much time is left)[?!. ]*$"#) {
            return ActionResult(userVisibleMessage: WebsiteBlockerService.shared.focusStatus)
        }

        if matches(text, pattern: #"(?i)^(?:show\s+)?nightlock(?:\s+status)?[?!. ]*$"#) {
            return ActionResult(userVisibleMessage: NightLockBridge.shared.detailedStatus)
        }
        return nil
    }

    private func handleWindowAction(_ text: String) -> ActionResult? {
        let placement: WindowActionService.Placement?
        if matches(text, pattern: #"(?i)^(?:move|tile|put)\s+(?:this|the current)\s+window\s+(?:to\s+)?(?:the\s+)?left[?!. ]*$"#) {
            placement = .leftHalf
        } else if matches(text, pattern: #"(?i)^(?:move|tile|put)\s+(?:this|the current)\s+window\s+(?:to\s+)?(?:the\s+)?right[?!. ]*$"#) {
            placement = .rightHalf
        } else if matches(text, pattern: #"(?i)^(?:center)\s+(?:this|the current)\s+window[?!. ]*$"#) {
            placement = .center
        } else if matches(text, pattern: #"(?i)^(?:maximize|fill the screen with)\s+(?:this|the current)\s+window[?!. ]*$"#) {
            placement = .maximize
        } else if matches(text, pattern: #"(?i)^minimize\s+(?:this|the current)\s+window[?!. ]*$"#) {
            placement = .minimize
        } else {
            placement = nil
        }
        guard let placement else { return nil }
        return ActionResult(userVisibleMessage: WindowActionService.shared.placeFrontWindow(placement))
    }

    private func handleWebsiteBlockerAction(_ text: String) -> ActionResult? {
        if matches(text, pattern: #"(?i)^(?:turn|switch)\s+on\s+(?:the\s+)?(?:bedtime\s+)?(?:website\s+)?blocker\s*$"#)
            || matches(text, pattern: #"(?i)^enable\s+(?:the\s+)?(?:bedtime\s+)?(?:website\s+)?blocker\s*$"#) {
            return ActionResult(userVisibleMessage: WebsiteBlockerService.shared.enable())
        }

        if matches(text, pattern: #"(?i)^(?:turn|switch)\s+off\s+(?:the\s+)?(?:bedtime\s+)?(?:website\s+)?blocker\s*$"#)
            || matches(text, pattern: #"(?i)^disable\s+(?:the\s+)?(?:bedtime\s+)?(?:website\s+)?blocker\s*$"#) {
            return ActionResult(userVisibleMessage: WebsiteBlockerService.shared.disable())
        }

        if matches(text, pattern: #"(?i)^(?:show|list|what are)\s+(?:the\s+)?blocked\s+sites\??\s*$"#)
            || matches(text, pattern: #"(?i)^(?:show|what is)\s+(?:the\s+)?(?:bedtime\s+)?blocker\s+status\??\s*$"#) {
            return ActionResult(userVisibleMessage: WebsiteBlockerService.shared.showBlockedSites())
        }

        if matches(text, pattern: #"(?i)^(?:show|run)\s+(?:the\s+)?(?:bedtime\s+)?blocker\s+diagnostics\??\s*$"#)
            || matches(text, pattern: #"(?i)^debug\s+(?:the\s+)?(?:bedtime\s+)?blocker\s*$"#) {
            return ActionResult(userVisibleMessage: WebsiteBlockerService.shared.diagnosticsSummary())
        }

        if let reason = firstCapture(
            in: text,
            pattern: #"(?i)^snooze\s+(?:the\s+)?(?:bedtime\s+)?blocker\s+for\s+15\s+minutes\s+because\s+(.+)$"#
        ) {
            return ActionResult(userVisibleMessage: WebsiteBlockerService.shared.snoozeForChallenge(reason: cleanTrailingPunctuation(reason)))
        }

        if matches(text, pattern: #"(?i)^snooze\s+(?:the\s+)?(?:bedtime\s+)?blocker\s*$"#) {
            return ActionResult(userVisibleMessage: WebsiteBlockerService.shared.snoozeForChallenge(reason: ""))
        }

        if let domain = firstCapture(
            in: text,
            pattern: #"(?i)^block\s+(.+?)\s+until\s+morning\s*$"#
        ) {
            return ActionResult(userVisibleMessage: WebsiteBlockerService.shared.blockUntilMorning(cleanTrailingPunctuation(domain)))
        }

        return nil
    }

    private func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }

        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return detector.firstMatch(in: text, options: [], range: range)?.url
    }

    private func parseAppName(from text: String) -> String? {
        let patterns = [
            #"(?i)^(?:open|launch|start)\s+(?:the\s+)?(?:app\s+)?(.+?)\s*$"#,
            #"(?i)^(?:open|launch|start)\s+(.+?)\s+app\s*$"#
        ]

        for pattern in patterns {
            if let value = firstCapture(in: text, pattern: pattern) {
                let trimmed = cleanTrailingPunctuation(value)
                guard !trimmed.contains("/") && !trimmed.lowercased().hasPrefix("http") else {
                    continue
                }
                return trimmed
            }
        }

        return nil
    }

    private func parsePath(from text: String) -> String? {
        guard let value = firstCapture(
            in: text,
            pattern: #"(?i)^open\s+(?:file|folder|path)?\s*(.+)$"#
        ) else {
            return nil
        }

        let trimmed = cleanTrailingPunctuation(value)
        let expanded = expandPath(trimmed)

        if FileManager.default.fileExists(atPath: expanded) {
            return expanded
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let namedFolders = [
            "desktop": "\(home)/Desktop",
            "downloads": "\(home)/Downloads",
            "documents": "\(home)/Documents"
        ]

        return namedFolders[trimmed.lowercased()]
    }

    private func parseClipboardText(from text: String) -> String? {
        firstCapture(in: text, pattern: #"(?i)^(?:copy|put)\s+(.+?)\s+(?:to|on|in)\s+(?:the\s+)?clipboard\s*$"#)
            .map(cleanTrailingPunctuation)
    }

    private func parseReminderTitle(from text: String) -> String? {
        let patterns = [
            #"(?i)^remind me to\s+(.+)$"#,
            #"(?i)^create (?:a\s+)?reminder(?:\s+to|\s+for)?\s+(.+)$"#,
            #"(?i)^add (?:a\s+)?reminder(?:\s+to|\s+for)?\s+(.+)$"#
        ]

        for pattern in patterns {
            if let value = firstCapture(in: text, pattern: pattern) {
                return cleanTrailingPunctuation(value)
            }
        }

        return nil
    }

    private func openURL(_ url: URL) -> ActionResult {
        NSWorkspace.shared.open(url)
        return ActionResult(userVisibleMessage: "Opened \(url.absoluteString).")
    }

    private func openApp(named appName: String) -> ActionResult {
        if let appURL = findInstalledApp(named: appName) {
            let opened = NSWorkspace.shared.open(appURL)
            if opened {
                return ActionResult(userVisibleMessage: "Opened \(displayName(forAppURL: appURL)).")
            }
        }

        let status = runProcess("/usr/bin/open", arguments: ["-a", appName])
        if status == 0 {
            return ActionResult(userVisibleMessage: "Opened \(appName).")
        }

        return ActionResult(userVisibleMessage: "I could not open \(appName). Check the app name and try again.")
    }

    private func findInstalledApp(named appName: String) -> URL? {
        let query = normalizedAppName(appName)
        guard !query.isEmpty else { return nil }

        let searchRoots = [
            "/Applications",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/Applications",
            "/System/Applications"
        ]

        var candidates: [(url: URL, score: Int)] = []
        let fileManager = FileManager.default

        for root in searchRoots where fileManager.fileExists(atPath: root) {
            guard let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "app" else { continue }

                let candidateName = normalizedAppName(url.deletingPathExtension().lastPathComponent)
                if candidateName == query {
                    return url
                }

                if candidateName.contains(query) || query.contains(candidateName) {
                    candidates.append((url: url, score: abs(candidateName.count - query.count)))
                }
            }
        }

        return candidates.sorted { $0.score < $1.score }.first?.url
    }

    private func normalizedAppName(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: ".app", with: "")
            .replacingOccurrences(of: "application", with: "")
            .replacingOccurrences(of: "app", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private func displayName(forAppURL url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private func openPath(_ path: String) -> ActionResult {
        let status = runProcess("/usr/bin/open", arguments: [path])
        if status == 0 {
            return ActionResult(userVisibleMessage: "Opened \(path).")
        }

        return ActionResult(userVisibleMessage: "I could not open \(path).")
    }

    private func copyToClipboard(_ text: String) -> ActionResult {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return ActionResult(userVisibleMessage: "Copied to clipboard.")
    }

    private func createReminder(title: String) -> ActionResult {
        let escapedTitle = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = #"tell application "Reminders" to make new reminder with properties {name:"\#(escapedTitle)"}"#
        let status = runProcess("/usr/bin/osascript", arguments: ["-e", script])

        if status == 0 {
            return ActionResult(userVisibleMessage: "Created reminder: \(title).")
        }

        return ActionResult(userVisibleMessage: "I could not create that reminder. macOS may need permission for Stickman or Terminal to control Reminders.")
    }

    private func runProcess(_ executable: String, arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    private func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }

        return String(text[captureRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matches(_ text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }

        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private func cleanTrailingPunctuation(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    }

    private func expandPath(_ path: String) -> String {
        guard path.hasPrefix("~") else {
            return path
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + path.dropFirst()
    }
}
