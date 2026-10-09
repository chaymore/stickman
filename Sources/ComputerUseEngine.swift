import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ScreenCaptureKit

extension CGEvent {
    /// Marks input Stickman posts for Claude, so the Esc-to-stop monitor can tell it from the user's own keys.
    static let stickmanTag: Int64 = 0x5354_4B4D

    var isStickmanSynthetic: Bool { getIntegerValueField(.eventSourceUserData) == Self.stickmanTag }

    func postTagged() {
        setIntegerValueField(.eventSourceUserData, value: Self.stickmanTag)
        post(tap: .cghidEventTap)
    }
}

enum ComputerUseError: LocalizedError {
    case accessibilityNeeded
    case appNotRunning(String)
    case appNotFound(String)
    case noWindow(String)
    case noSnapshot(String)
    case badIndex(Int)
    case staleElement(Int)
    case needsTarget
    case passwordField
    case unknownKey(String)
    case actionFailed(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityNeeded:
            return "Stickman needs Accessibility permission to operate apps. Ask the user to turn on Stickman in System Settings → Privacy & Security → Accessibility, then try again."
        case .appNotRunning(let app):
            return "\(app) isn't running. Use open_app first."
        case .appNotFound(let app):
            return "Couldn't find an app called \(app)."
        case .noWindow(let app):
            return "\(app) has no open window. Open one with a menu command or a keyboard shortcut, then call get_app_state again."
        case .noSnapshot(let app):
            return "Call get_app_state for \(app) first, so element numbers are current."
        case .badIndex(let index):
            return "There's no element \(index) in the latest get_app_state. Call it again and use a listed number."
        case .staleElement(let index):
            return "Element \(index) is gone; the window changed. Call get_app_state again."
        case .needsTarget:
            return "Pass an element_index, or both x and y."
        case .passwordField:
            return "That's a password field. Stickman doesn't type passwords; ask the user to enter it themselves."
        case .unknownKey(let key):
            return "Don't know the key \"\(key)\". Use names like return, tab, escape, up, cmd+s, or cmd+shift+t."
        case .actionFailed(let detail):
            return detail
        }
    }
}

/// Reads app interfaces through the accessibility tree and drives them with real input
/// events. Elements are numbered per app on each get_app_state, and later actions refer
/// to those numbers.
@MainActor
final class ComputerUseEngine {
    struct AppState {
        let text: String
        let screenshotJPEG: Data?
    }

    private struct Snapshot {
        /// Front window in global top-left coordinates, as accessibility reports it.
        let windowFrame: CGRect
        /// Screenshot pixels per window point.
        let imageScale: CGFloat
        let elements: [AXUIElement]
    }

    private var snapshots: [pid_t: Snapshot] = [:]
    private static let maxElements = 350
    private static let maxDepth = 40
    private static let maxImageWidth: CGFloat = 1280
    private static let maxImageHeight: CGFloat = 960

    // MARK: Apps

    func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
    }

    func resolveRunningApp(_ query: String) throws -> NSRunningApplication {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let apps = runningApps()
        if let match = apps.first(where: { $0.bundleIdentifier?.lowercased() == needle })
            ?? apps.first(where: { $0.localizedName?.lowercased() == needle })
            ?? apps.first(where: { $0.localizedName?.lowercased().hasPrefix(needle) == true }) {
            return match
        }
        throw ComputerUseError.appNotRunning(query)
    }

    /// Finds an installed app by bundle identifier or name.
    func applicationURL(for query: String) -> URL? {
        var url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query)
        if url == nil {
            let name = query.hasSuffix(".app") ? query : query + ".app"
            for folder in ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                           FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path] {
                let candidate = URL(fileURLWithPath: folder).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    url = candidate
                    break
                }
            }
        }
        return url
    }

    func launch(_ url: URL) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    // MARK: State

    func appState(of app: NSRunningApplication) async throws -> AppState {
        try requireAccessibility()
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1.5)
        let name = app.localizedName ?? app.bundleIdentifier ?? "App"
        guard let window = frontWindow(of: root), let windowFrame = frame(of: window) else {
            throw ComputerUseError.noWindow(name)
        }

        var image: CGImage?
        var imageScale = min(1, Self.maxImageWidth / max(1, windowFrame.width), Self.maxImageHeight / max(1, windowFrame.height))
        var screenshotNote: String?
        if #available(macOS 14.0, *) {
            if CGPreflightScreenCaptureAccess() {
                ScreenShareMonitor.shared.ignoreOwnCapture()
                image = try? await captureWindow(pid: app.processIdentifier, frame: windowFrame, scale: imageScale)
                if image == nil { screenshotNote = "Screenshot unavailable for this window." }
            } else {
                CGRequestScreenCaptureAccess()
                screenshotNote = "No screenshot: Stickman needs Screen Recording permission (System Settings → Privacy & Security → Screen & System Audio Recording)."
            }
        } else {
            screenshotNote = "Screenshots need macOS 14 or later."
        }
        if let image { imageScale = CGFloat(image.width) / windowFrame.width }

        var elements: [AXUIElement] = []
        var lines: [String] = []
        let title: String = stringAttribute(window, kAXTitleAttribute) ?? ""
        lines.append("\(name)\(title.isEmpty ? "" : " — window \"\(title)\"")")
        if let image {
            lines.append("Screenshot: \(image.width)x\(image.height) pixels. x/y arguments use these pixels.")
        } else if let screenshotNote {
            lines.append(screenshotNote)
        }

        let menuItems = menuBarItems(of: root)
        if !menuItems.isEmpty {
            let labels = menuItems.map { item -> String in
                elements.append(item.element)
                return "[\(elements.count)] \(item.title)"
            }
            lines.append("Menu bar: " + labels.joined(separator: "  "))
        }

        if let openMenu = openMenu(of: root) {
            lines.append("Open menu:")
            walk(openMenu, depth: 1, windowFrame: windowFrame, scale: imageScale, elements: &elements, lines: &lines, clipToWindow: false)
        }

        lines.append("Window:")
        let before = elements.count
        walk(window, depth: 1, windowFrame: windowFrame, scale: imageScale, elements: &elements, lines: &lines, clipToWindow: true)
        if elements.count - before == 0 {
            lines.append("  (no readable controls; use the screenshot and x/y)")
        }
        if elements.count >= Self.maxElements {
            lines.append("(Outline cut off at \(Self.maxElements) elements. Scroll, or use the screenshot for the rest.)")
        }

        if let focused: AXUIElement = elementAttribute(root, kAXFocusedUIElementAttribute),
           let index = elements.firstIndex(where: { CFEqual($0, focused) }) {
            lines.append("Keyboard focus: [\(index + 1)]")
        }

        snapshots[app.processIdentifier] = Snapshot(windowFrame: windowFrame, imageScale: imageScale, elements: elements)
        let jpeg = image.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .jpeg, properties: [.compressionFactor: 0.72]) }
        return AppState(text: lines.joined(separator: "\n"), screenshotJPEG: jpeg)
    }

    // MARK: Actions

    /// Returns the global point that was clicked, for the on-screen ripple.
    func click(_ app: NSRunningApplication, index: Int?, x: Double?, y: Double?, rightButton: Bool, count: Int) async throws -> CGPoint {
        try requireAccessibility()
        if let index {
            let element = try element(index, in: app)
            if !rightButton, count == 1, actionNames(element).contains(kAXPressAction),
               AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                return center(of: element) ?? .zero
            }
            guard let point = center(of: element) else { throw ComputerUseError.staleElement(index) }
            activate(app)
            try await Task.sleep(nanoseconds: 150_000_000)
            try await passingThroughOwnWindows { postClick(at: point, rightButton: rightButton, count: count) }
            return point
        }
        let point = try globalPoint(app, x: x, y: y)
        activate(app)
        try await Task.sleep(nanoseconds: 150_000_000)
        try await passingThroughOwnWindows { postClick(at: point, rightButton: rightButton, count: count) }
        return point
    }

    func typeText(_ app: NSRunningApplication, text: String) async throws {
        try requireAccessibility()
        try refuseIfPasswordFocused(app)
        activate(app)
        try await Task.sleep(nanoseconds: 150_000_000)
        let lines = text.components(separatedBy: "\n")
        for (offset, line) in lines.enumerated() {
            postUnicode(line)
            if offset < lines.count - 1 { postKey(CGKeyCode(kVK_Return), flags: []) }
        }
    }

    func pressKey(_ app: NSRunningApplication, key: String) async throws {
        try requireAccessibility()
        guard let parsed = Self.parseKey(key) else { throw ComputerUseError.unknownKey(key) }
        activate(app)
        try await Task.sleep(nanoseconds: 120_000_000)
        postKey(parsed.keyCode, flags: parsed.flags)
    }

    func scroll(_ app: NSRunningApplication, index: Int?, x: Double?, y: Double?, direction: String, pages: Double) async throws {
        try requireAccessibility()
        guard let snapshot = snapshots[app.processIdentifier] else { throw ComputerUseError.noSnapshot(app.localizedName ?? "the app") }
        let point: CGPoint
        if let index {
            guard let center = center(of: try element(index, in: app)) else { throw ComputerUseError.staleElement(index) }
            point = center
        } else if x != nil || y != nil {
            point = try globalPoint(app, x: x, y: y)
        } else {
            point = CGPoint(x: snapshot.windowFrame.midX, y: snapshot.windowFrame.midY)
        }
        activate(app)
        try await Task.sleep(nanoseconds: 120_000_000)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.postTagged()

        let vertical = direction.hasPrefix("u") || direction.hasPrefix("d")
        let span = (vertical ? snapshot.windowFrame.height : snapshot.windowFrame.width) * 0.8 * CGFloat(max(0.1, min(10, pages)))
        let sign: CGFloat = (direction.hasPrefix("u") || direction.hasPrefix("l")) ? 1 : -1
        let steps = 8
        for _ in 0 ..< steps {
            let amount = Int32(sign * span / CGFloat(steps))
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                wheel1: vertical ? amount : 0, wheel2: vertical ? 0 : amount, wheel3: 0)
            event?.postTagged()
            try await Task.sleep(nanoseconds: 12_000_000)
        }
    }

    func setValue(_ app: NSRunningApplication, index: Int, value: String) throws {
        try requireAccessibility()
        let element = try element(index, in: app)
        if role(of: element) == kAXSecureTextFieldSubrole || subrole(of: element) == kAXSecureTextFieldSubrole {
            throw ComputerUseError.passwordField
        }
        let current: CFTypeRef? = rawAttribute(element, kAXValueAttribute)
        let newValue: CFTypeRef
        if let number = current as? NSNumber, let parsed = Double(value) {
            newValue = (number is Bool ? NSNumber(value: parsed != 0) : NSNumber(value: parsed)) as CFTypeRef
        } else {
            newValue = value as CFString
        }
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newValue)
        guard result == .success else {
            throw ComputerUseError.actionFailed("Element \(index) won't take a value directly (error \(result.rawValue)). Click it and use type_text instead.")
        }
        // Fields like a font-size box only apply a new value once it's confirmed.
        if actionNames(element).contains("AXConfirm") {
            AXUIElementPerformAction(element, "AXConfirm" as CFString)
        }
    }

    func performAction(_ app: NSRunningApplication, index: Int, action: String) throws {
        try requireAccessibility()
        let element = try element(index, in: app)
        let available = actionNames(element)
        let name = action.hasPrefix("AX") ? action : "AX" + action.prefix(1).uppercased() + action.dropFirst()
        guard available.contains(name) else {
            let list = available.isEmpty ? "none" : available.joined(separator: ", ")
            throw ComputerUseError.actionFailed("Element \(index) doesn't support \(name). It supports: \(list).")
        }
        let result = AXUIElementPerformAction(element, name as CFString)
        guard result == .success else { throw ComputerUseError.actionFailed("\(name) failed on element \(index) (error \(result.rawValue)).") }
    }

    func drag(_ app: NSRunningApplication, from: (Double, Double), to: (Double, Double)) async throws {
        try requireAccessibility()
        let start = try globalPoint(app, x: from.0, y: from.1)
        let end = try globalPoint(app, x: to.0, y: to.1)
        activate(app)
        try await Task.sleep(nanoseconds: 150_000_000)
        let ownWindows = ignoreMouseInOwnWindows()
        defer { restoreMouse(in: ownWindows) }
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left)?.postTagged()
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)?.postTagged()
        let steps = 16
        for step in 1 ... steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?.postTagged()
            try await Task.sleep(nanoseconds: 14_000_000)
        }
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?.postTagged()
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    // MARK: Keys

    /// Parses "return", "cmd+s", or "cmd+shift+t" into a key code and modifier flags.
    nonisolated static func parseKey(_ text: String) -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        var flags: CGEventFlags = []
        var parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        if text.hasSuffix("++") { parts.append("+") }
        guard let keyName = parts.last, !keyName.isEmpty else { return nil }
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: return nil
            }
        }
        guard let code = keyCodes[keyName] else { return nil }
        return (CGKeyCode(code), flags)
    }

    private nonisolated static let keyCodes: [String: Int] = {
        var codes: [String: Int] = [
            "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space,
            "escape": kVK_Escape, "esc": kVK_Escape, "delete": kVK_Delete, "backspace": kVK_Delete,
            "forwarddelete": kVK_ForwardDelete, "up": kVK_UpArrow, "down": kVK_DownArrow,
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "home": kVK_Home, "end": kVK_End,
            "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
            "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
            "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
            "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
            "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
            "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave
        ]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (offset, code) in functionKeys.enumerated() { codes["f\(offset + 1)"] = code }
        return codes
    }()

    // MARK: Outline

    private static let interactiveRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXSecureTextField",
        "AXPopUpButton", "AXComboBox", "AXMenuButton", "AXLink", "AXMenuItem", "AXMenuBarItem",
        "AXTab", "AXSlider", "AXIncrementor", "AXStepper", "AXDisclosureTriangle", "AXSearchField",
        "AXCell", "AXRow", "AXColorWell", "AXDateField", "AXSwitch", "AXToggle"
    ]

    private static let attributeNames = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        kAXValueAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute,
        kAXChildrenAttribute, "AXPlaceholderValue", kAXSelectedAttribute
    ] as CFArray

    private func walk(
        _ element: AXUIElement,
        depth: Int,
        windowFrame: CGRect,
        scale: CGFloat,
        elements: inout [AXUIElement],
        lines: inout [String],
        clipToWindow: Bool
    ) {
        guard depth <= Self.maxDepth, elements.count < Self.maxElements else { return }
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, Self.attributeNames, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let values = raw as? [AnyObject], values.count == 11
        else { return }
        func value(_ index: Int) -> AnyObject? {
            let object = values[index]
            if CFGetTypeID(object) == AXValueGetTypeID(), AXValueGetType(object as! AXValue) == .axError { return nil }
            return object
        }

        let role = value(0) as? String ?? "AXUnknown"
        let subrole = value(1) as? String
        let title = (value(2) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = (value(3) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholder = (value(9) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let enabled = (value(7) as? Bool) ?? true
        let selected = (value(10) as? Bool) ?? false
        let children = value(8) as? [AXUIElement] ?? []
        // Scroll bars and ruler ticks add lines without adding anything Claude can use; scroll covers scrolling.
        if Self.skippedRoles.contains(role) { return }

        var frame: CGRect?
        if let positionValue = value(5), let sizeValue = value(6),
           CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() {
            var origin = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            frame = CGRect(origin: origin, size: size)
        }
        if let frame {
            if frame.width < 2 || frame.height < 2 { return }
            if clipToWindow, !frame.intersects(windowFrame) { return }
        }

        let isSecure = role == "AXSecureTextField" || subrole == kAXSecureTextFieldSubrole
        var valueText: String?
        if isSecure {
            valueText = "(hidden)"
        } else if let string = value(4) as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { valueText = trimmed }
        } else if let number = value(4) as? NSNumber {
            valueText = number.stringValue
        }

        let label = [title, description].compactMap { $0 }.first { !$0.isEmpty }
        let hasText = label != nil || valueText != nil
        let include = Self.interactiveRoles.contains(role) || isSecure || hasText
        var childDepth = depth

        func emit(label: String?) {
            elements.append(element)
            var line = String(repeating: "  ", count: depth) + "[\(elements.count)] \(Self.roleName(role, subrole: subrole, secure: isSecure))"
            if let label { line += " \"\(Self.clip(label, 80))\"" }
            if let valueText, valueText != label {
                let limit = role == "AXTextArea" || role == "AXWebArea" ? 600 : 120
                line += " = \"\(Self.clip(valueText, limit))\""
            }
            if let placeholder, !placeholder.isEmpty, valueText == nil { line += " (placeholder \"\(Self.clip(placeholder, 60))\")" }
            if !enabled { line += " disabled" }
            if selected { line += " selected" }
            if let frame {
                let x = Int(((frame.minX - windowFrame.minX) * scale).rounded())
                let y = Int(((frame.minY - windowFrame.minY) * scale).rounded())
                let w = Int((frame.width * scale).rounded())
                let h = Int((frame.height * scale).rounded())
                line += " @\(x),\(y) \(w)x\(h)"
            }
            lines.append(line)
        }

        // A list or table row reads as one line built from its text ("report.pdf · 2 MB · Today"),
        // followed only by the controls inside it, instead of a cell and text field per column.
        if Self.rowRoles.contains(role), label == nil, valueText == nil {
            var pieces: [String] = []
            var controls: [AXUIElement] = []
            for child in children { summarizeRow(child, depth: 1, text: &pieces, controls: &controls) }
            if pieces.isEmpty, controls.isEmpty, !selected { return }
            emit(label: pieces.isEmpty ? nil : pieces.joined(separator: " · "))
            for control in controls {
                walk(control, depth: depth + 1, windowFrame: windowFrame, scale: scale, elements: &elements, lines: &lines, clipToWindow: clipToWindow)
            }
            return
        }

        if include, role != "AXWindow" {
            emit(label: label)
            childDepth += 1
        }

        // Plain text inside a button or link repeats its label; skip it.
        if include, Self.interactiveRoles.contains(role) {
            let deeper = children.filter { child in
                guard let childRole: String = stringAttribute(child, kAXRoleAttribute) else { return true }
                return childRole != "AXStaticText" && childRole != "AXImage"
            }
            for child in deeper { walk(child, depth: childDepth, windowFrame: windowFrame, scale: scale, elements: &elements, lines: &lines, clipToWindow: clipToWindow) }
            return
        }
        for child in children {
            walk(child, depth: childDepth, windowFrame: windowFrame, scale: scale, elements: &elements, lines: &lines, clipToWindow: clipToWindow)
        }
    }

    private static let rowRoles: Set<String> = ["AXRow", "AXCell"]

    private static let skippedRoles: Set<String> = ["AXScrollBar", "AXRulerMarker", "AXRuler", "AXGrowArea"]

    private static let rowControlRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXDisclosureTriangle", "AXPopUpButton", "AXMenuButton",
        "AXLink", "AXRadioButton", "AXSlider", "AXIncrementor", "AXComboBox"
    ]

    /// Collects a row's visible text and the controls nested in it.
    private func summarizeRow(_ element: AXUIElement, depth: Int, text: inout [String], controls: inout [AXUIElement]) {
        guard depth <= 5 else { return }
        let role = role(of: element) ?? ""
        if Self.rowControlRoles.contains(role) {
            controls.append(element)
            return
        }
        if role == "AXSecureTextField" || subrole(of: element) == kAXSecureTextFieldSubrole { return }
        if role == "AXStaticText" || role == "AXTextField" {
            if text.count < 5,
               let value = (rawAttribute(element, kAXValueAttribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty, !text.contains(value) {
                text.append(value)
            }
            return
        }
        for child in rawAttribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            summarizeRow(child, depth: depth + 1, text: &text, controls: &controls)
        }
    }

    nonisolated static func roleName(_ role: String, subrole: String?, secure: Bool) -> String {
        if secure { return "password field" }
        switch role {
        case "AXStaticText": return "text"
        case "AXTextField": return subrole == "AXSearchField" ? "search field" : "text field"
        case "AXTextArea": return "text area"
        case "AXPopUpButton": return "pop-up"
        case "AXMenuButton": return "menu button"
        case "AXMenuItem": return "menu item"
        case "AXMenuBarItem": return "menu"
        case "AXCheckBox": return subrole == "AXSwitch" ? "switch" : "checkbox"
        case "AXRadioButton": return subrole == "AXTabButton" ? "tab" : "radio button"
        case "AXDisclosureTriangle": return "disclosure"
        case "AXButton" where subrole == "AXCloseButton": return "close button"
        case "AXButton" where subrole == "AXMinimizeButton": return "minimize button"
        case "AXButton" where subrole == "AXFullScreenButton" || subrole == "AXZoomButton": return "zoom button"
        case "AXComboBox": return "combo box"
        default:
            let trimmed = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
            return trimmed.isEmpty ? "element" : trimmed.prefix(1).lowercased() + trimmed.dropFirst()
        }
    }

    nonisolated static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ↵ ")
            .replacingOccurrences(of: "\"", with: "'")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    // MARK: Accessibility helpers

    private func requireAccessibility() throws {
        guard AXIsProcessTrusted() else {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            throw ComputerUseError.accessibilityNeeded
        }
    }

    private func frontWindow(of app: AXUIElement) -> AXUIElement? {
        if let focused: AXUIElement = elementAttribute(app, kAXFocusedWindowAttribute) { return focused }
        if let main: AXUIElement = elementAttribute(app, kAXMainWindowAttribute) { return main }
        let windows: [AXUIElement] = rawAttribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.first
    }

    private func menuBarItems(of app: AXUIElement) -> [(element: AXUIElement, title: String)] {
        guard let menuBar: AXUIElement = elementAttribute(app, kAXMenuBarAttribute) else { return [] }
        let items = rawAttribute(menuBar, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return items.dropFirst().compactMap { item in
            guard let title: String = stringAttribute(item, kAXTitleAttribute), !title.isEmpty else { return nil }
            return (item, title)
        }
    }

    /// The menu that's currently open, found through the focused menu item.
    private func openMenu(of app: AXUIElement) -> AXUIElement? {
        // A menu bar menu hangs off its selected menu bar item; a context menu sits under the app.
        if let menuBar: AXUIElement = elementAttribute(app, kAXMenuBarAttribute) {
            for item in rawAttribute(menuBar, kAXChildrenAttribute) as? [AXUIElement] ?? []
            where (rawAttribute(item, kAXSelectedAttribute) as? Bool) == true {
                let menus = (rawAttribute(item, kAXChildrenAttribute) as? [AXUIElement] ?? []).filter { role(of: $0) == kAXMenuRole }
                if let menu = menus.first { return menu }
            }
        }
        for child in rawAttribute(app, kAXChildrenAttribute) as? [AXUIElement] ?? [] where role(of: child) == kAXMenuRole {
            return child
        }
        guard let focused: AXUIElement = elementAttribute(app, kAXFocusedUIElementAttribute) else { return nil }
        var current: AXUIElement? = focused
        for _ in 0 ..< 4 {
            guard let element = current else { return nil }
            if role(of: element) == kAXMenuRole { return element }
            current = elementAttribute(element, kAXParentAttribute)
        }
        return nil
    }

    private func element(_ index: Int, in app: NSRunningApplication) throws -> AXUIElement {
        guard let snapshot = snapshots[app.processIdentifier] else { throw ComputerUseError.noSnapshot(app.localizedName ?? "the app") }
        guard index >= 1, index <= snapshot.elements.count else { throw ComputerUseError.badIndex(index) }
        let element = snapshot.elements[index - 1]
        guard role(of: element) != nil else { throw ComputerUseError.staleElement(index) }
        return element
    }

    private func globalPoint(_ app: NSRunningApplication, x: Double?, y: Double?) throws -> CGPoint {
        guard let x, let y else { throw ComputerUseError.needsTarget }
        guard let snapshot = snapshots[app.processIdentifier] else { throw ComputerUseError.noSnapshot(app.localizedName ?? "the app") }
        return CGPoint(
            x: snapshot.windowFrame.minX + CGFloat(x) / snapshot.imageScale,
            y: snapshot.windowFrame.minY + CGFloat(y) / snapshot.imageScale
        )
    }

    private func refuseIfPasswordFocused(_ app: NSRunningApplication) throws {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused: AXUIElement = elementAttribute(root, kAXFocusedUIElementAttribute) else { return }
        if role(of: focused) == "AXSecureTextField" || subrole(of: focused) == kAXSecureTextFieldSubrole {
            throw ComputerUseError.passwordField
        }
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = rawAttribute(element, kAXPositionAttribute),
              let sizeValue = rawAttribute(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    private func center(of element: AXUIElement) -> CGPoint? {
        frame(of: element).map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    private func role(of element: AXUIElement) -> String? { stringAttribute(element, kAXRoleAttribute) }

    private func subrole(of element: AXUIElement) -> String? { stringAttribute(element, kAXSubroleAttribute) }

    private func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private func rawAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        rawAttribute(element, name) as? String
    }

    private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = rawAttribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    // MARK: Input events

    /// Stickman, his chat panel, and the banner may sit over the spot Claude clicks.
    /// They let clicks fall through to the app underneath until the click lands.
    private func passingThroughOwnWindows(_ post: () -> Void) async throws {
        let ownWindows = ignoreMouseInOwnWindows()
        defer { restoreMouse(in: ownWindows) }
        post()
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    private func ignoreMouseInOwnWindows() -> [NSWindow] {
        let windows = NSApp.windows.filter { $0.isVisible && !$0.ignoresMouseEvents }
        windows.forEach { $0.ignoresMouseEvents = true }
        return windows
    }

    private func restoreMouse(in windows: [NSWindow]) {
        windows.forEach { $0.ignoresMouseEvents = false }
    }

    func activate(_ app: NSRunningApplication) {
        if !app.isActive { app.activate() }
    }

    private func postClick(at point: CGPoint, rightButton: Bool, count: Int) {
        let button: CGMouseButton = rightButton ? .right : .left
        let downType: CGEventType = rightButton ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = rightButton ? .rightMouseUp : .leftMouseUp
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button)?.postTagged()
        for click in 1 ... max(1, min(3, count)) {
            let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: button)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            down?.postTagged()
            let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: button)
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            up?.postTagged()
        }
    }

    private func postUnicode(_ text: String) {
        let units = Array(text.utf16)
        var start = 0
        while start < units.count {
            let chunk = Array(units[start ..< min(start + 16, units.count)])
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown)
                chunk.withUnsafeBufferPointer { buffer in
                    event?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
                event?.postTagged()
            }
            start += 16
            usleep(6_000)
        }
    }

    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown)
            event?.flags = flags
            event?.postTagged()
        }
    }

    // MARK: Screenshot

    @available(macOS 14.0, *)
    private func captureWindow(pid: pid_t, frame: CGRect, scale: CGFloat) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let candidates = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
        guard let window = candidates.min(by: { distance($0.frame, frame) < distance($1.frame, frame) }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }
}
