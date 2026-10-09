import AppKit
import Darwin

extension Notification.Name {
    /// userInfo: "active" (Bool), "app" (String), and "stopped" (Bool) when the user pressed Esc.
    static let stickmanComputerUseDidChange = Notification.Name("StickmanComputerUseDidChange")
}

/// Serves Claude Code's computer-use tools. The `stickman-computer-use` MCP relay inside the
/// app bundle forwards each tool call here over a private socket; Stickman checks that the
/// app is approved, does the work under its own Accessibility and Screen Recording
/// permissions, and replies with text and screenshots.
@MainActor
final class ComputerUseService {
    static let shared = ComputerUseService()

    nonisolated static let relayName = "stickman-computer-use"
    nonisolated static let mcpServerName = "stickman"
    nonisolated static let allowedToolsPattern = "mcp__stickman"

    /// Apps Claude may not operate: terminals (Claude Code has its own shell, under its own
    /// permission rules), password managers, system settings, and Stickman itself.
    nonisolated static let offLimitsBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.apple.systempreferences",
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.SecurityAgent", "com.apple.loginwindow", "com.chaymore.Stickman"
    ]

    private enum Keys {
        static let alwaysAllowed = "StickmanComputerUseAllowedApps"
    }

    let engine = ComputerUseEngine()
    private let overlay = ComputerUseOverlay()
    private var server: ComputerUseSocketServer?
    private var allowedThisRun: Set<String> = []
    private var stoppedUntil: Date?
    private var lastCallAt: Date?
    private var idleTimer: Timer?
    private var isActive = false
    private var approvalInFlight = false

    private init() {
        overlay.onStop = { [weak self] in self?.stopFromUser() }
    }

    static var supportDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Stickman", isDirectory: true)
    }

    static var socketURL: URL { supportDirectory.appendingPathComponent("computer-use.sock") }
    static var mcpConfigURL: URL { supportDirectory.appendingPathComponent("computer-use-mcp.json") }

    /// The relay next to the app binary, present in built app bundles.
    static var relayURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(relayName)")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    var isAvailable: Bool { server != nil && Self.relayURL != nil }

    // MARK: Lifecycle

    func start() {
        guard server == nil, let relay = Self.relayURL else { return }
        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        let server = ComputerUseSocketServer(path: Self.socketURL.path, allowedPeer: relay.resolvingSymlinksInPath().path) { request in
            await ComputerUseService.shared.handle(request)
        }
        do {
            try server.start()
            self.server = server
            writeMCPConfig(relay: relay)
        } catch {
            NSLog("Stickman computer use couldn't listen: \(error)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }

    /// Clears an Esc stop when the user starts a new computer-use request.
    func prepareForNewRun() {
        stoppedUntil = nil
    }

    /// Claude Code loads the relay from this file with `--mcp-config`. `alwaysLoad` keeps the
    /// tools in the prompt instead of behind tool search, saving a round trip per session.
    private func writeMCPConfig(relay: URL) {
        let server: [String: Any] = ["type": "stdio", "command": relay.path, "args": [String](), "alwaysLoad": true]
        let config: [String: Any] = ["mcpServers": [Self.mcpServerName: server]]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? data.write(to: Self.mcpConfigURL, options: .atomic)
    }

    // MARK: Approvals

    var alwaysAllowedApps: [String] {
        get { UserDefaults.standard.stringArray(forKey: Keys.alwaysAllowed) ?? [] }
        set { UserDefaults.standard.set(Array(Set(newValue)).sorted(), forKey: Keys.alwaysAllowed) }
    }

    func forgetApproval(for bundleID: String) {
        alwaysAllowedApps.removeAll { $0 == bundleID }
        allowedThisRun.remove(bundleID)
    }

    private func ensureApproved(bundleID: String?, name: String) async throws {
        guard let bundleID else { throw ToolError("\(name) has no bundle identifier, so Stickman can't ask about it. It's off-limits.") }
        if Self.offLimitsBundleIDs.contains(bundleID) {
            throw ToolError("\(name) is off-limits to computer use. Do the work another way, or ask the user to do this step.")
        }
        if alwaysAllowedApps.contains(bundleID) || allowedThisRun.contains(bundleID) { return }

        while approvalInFlight {
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        if alwaysAllowedApps.contains(bundleID) || allowedThisRun.contains(bundleID) { return }
        approvalInFlight = true
        defer { approvalInFlight = false }

        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        switch await overlay.askApproval(appName: name, icon: icon) {
        case .always:
            alwaysAllowedApps.append(bundleID)
        case .once:
            allowedThisRun.insert(bundleID)
        case .deny:
            throw ToolError("The user didn't allow Claude to use \(name). Stop and report back instead of retrying.")
        }
    }

    // MARK: Requests

    private struct ToolError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private struct ToolReply {
        var text: String
        var jpeg: Data?
        var isError = false
    }

    func handle(_ requestData: Data) async -> Data {
        let reply: ToolReply
        if let stoppedUntil, stoppedUntil > Date() {
            reply = ToolReply(text: "The user pressed Esc to stop computer use. Stop now and report what you finished.", isError: true)
        } else if let request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
                  let tool = request["tool"] as? String {
            let arguments = request["arguments"] as? [String: Any] ?? [:]
            do {
                reply = try await run(tool, arguments)
            } catch {
                reply = ToolReply(text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, isError: true)
            }
        } else {
            reply = ToolReply(text: "Malformed request.", isError: true)
        }

        var content: [[String: Any]] = [["type": "text", "text": reply.text]]
        if let jpeg = reply.jpeg {
            content.append(["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"])
        }
        let object: [String: Any] = ["content": content, "isError": reply.isError]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data(#"{"content":[],"isError":true}"#.utf8)
    }

    private func run(_ tool: String, _ arguments: [String: Any]) async throws -> ToolReply {
        if tool == "list_apps" { return ToolReply(text: appList()) }

        guard let query = (arguments["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            throw ToolError("Pass the app's name or bundle identifier as \"app\".")
        }

        if tool == "open_app" {
            if let running = try? engine.resolveRunningApp(query) {
                try await ensureApproved(bundleID: running.bundleIdentifier, name: running.localizedName ?? query)
                markActive(appName: running.localizedName ?? query)
                engine.activate(running)
                try await Task.sleep(nanoseconds: 500_000_000)
                return try await stateReply(running, prefix: "\(running.localizedName ?? query) is in front.")
            }
            guard let url = engine.applicationURL(for: query) else { throw ComputerUseError.appNotFound(query) }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            try await ensureApproved(bundleID: Bundle(url: url)?.bundleIdentifier, name: name)
            markActive(appName: name)
            let app = try await engine.launch(url)
            try await waitForWindow(app, seconds: 6)
            return try await stateReply(app, prefix: "Opened \(name).")
        }

        let app = try engine.resolveRunningApp(query)
        let name = app.localizedName ?? query
        try await ensureApproved(bundleID: app.bundleIdentifier, name: name)
        markActive(appName: name)

        let index = Self.integer(arguments["element_index"])
        let x = Self.number(arguments["x"])
        let y = Self.number(arguments["y"])

        switch tool {
        case "get_app_state":
            return try await stateReply(app, prefix: nil)

        case "click":
            let right = (arguments["button"] as? String) == "right"
            let count = Self.integer(arguments["click_count"]) ?? 1
            if index == nil, x == nil || y == nil { throw ComputerUseError.needsTarget }
            let point = try await engine.click(app, index: index, x: x, y: y, rightButton: right, count: count)
            showRipple(at: point)
            let target = index.map { "element \($0)" } ?? "\(Int(x ?? 0)),\(Int(y ?? 0))"
            return try await settledState(app, prefix: "\(count == 2 ? "Double-clicked" : right ? "Right-clicked" : "Clicked") \(target).")

        case "type_text":
            guard let text = arguments["text"] as? String else { throw ToolError("Pass the text to type.") }
            overlay.noteSyntheticKey()
            try await engine.typeText(app, text: text)
            overlay.noteSyntheticKey()
            return try await settledState(app, prefix: "Typed \(text.count) characters.")

        case "press_key":
            guard let key = arguments["key"] as? String else { throw ToolError("Pass the key to press, like \"return\" or \"cmd+s\".") }
            overlay.noteSyntheticKey()
            try await engine.pressKey(app, key: key)
            overlay.noteSyntheticKey()
            return try await settledState(app, prefix: "Pressed \(key).")

        case "scroll":
            let direction = (arguments["direction"] as? String ?? "down").lowercased()
            let pages = Self.number(arguments["pages"]) ?? 1
            try await engine.scroll(app, index: index, x: x, y: y, direction: direction, pages: pages)
            return try await settledState(app, prefix: "Scrolled \(direction).")

        case "set_value":
            guard let index else { throw ToolError("Pass element_index.") }
            let value = (arguments["value"] as? String) ?? Self.number(arguments["value"]).map { String($0) } ?? ""
            try engine.setValue(app, index: index, value: value)
            return try await settledState(app, prefix: "Set element \(index) to \"\(value)\". Check the state below; if the app still shows the old value, click the field and press return.")

        case "perform_action":
            guard let index, let action = arguments["action"] as? String else { throw ToolError("Pass element_index and action.") }
            try engine.performAction(app, index: index, action: action)
            return try await settledState(app, prefix: "Performed \(action) on element \(index).")

        case "drag":
            guard let fromX = Self.number(arguments["from_x"]), let fromY = Self.number(arguments["from_y"]),
                  let toX = Self.number(arguments["to_x"]), let toY = Self.number(arguments["to_y"])
            else { throw ToolError("Pass from_x, from_y, to_x, and to_y.") }
            try await engine.drag(app, from: (fromX, fromY), to: (toX, toY))
            return try await settledState(app, prefix: "Dragged.")

        default:
            throw ToolError("Unknown tool \(tool).")
        }
    }

    /// Every action returns the app's fresh state, so Claude can check the result without another call.
    private func settledState(_ app: NSRunningApplication, prefix: String) async throws -> ToolReply {
        try await Task.sleep(nanoseconds: 450_000_000)
        guard !app.isTerminated else { return ToolReply(text: prefix + " The app quit.") }
        return try await stateReply(app, prefix: prefix)
    }

    private func stateReply(_ app: NSRunningApplication, prefix: String?) async throws -> ToolReply {
        do {
            let state = try await engine.appState(of: app)
            let text = [prefix, state.text].compactMap { $0 }.joined(separator: "\n\n")
            return ToolReply(text: text, jpeg: state.screenshotJPEG)
        } catch ComputerUseError.noWindow(let name) where prefix != nil {
            return ToolReply(text: (prefix ?? "") + " \(name) has no open window now.")
        }
    }

    private func waitForWindow(_ app: NSRunningApplication, seconds: Double) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            var windows: CFTypeRef?
            if AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows) == .success,
               let list = windows as? [AXUIElement], !list.isEmpty {
                try await Task.sleep(nanoseconds: 300_000_000)
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func appList() -> String {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let lines = engine.runningApps()
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
            .map { app -> String in
                let id = app.bundleIdentifier ?? "no bundle id"
                var notes: [String] = []
                if app.processIdentifier == front { notes.append("frontmost") }
                if Self.offLimitsBundleIDs.contains(id) {
                    notes.append("off-limits")
                } else if alwaysAllowedApps.contains(id) || allowedThisRun.contains(id) {
                    notes.append("approved")
                }
                return "- \(app.localizedName ?? id) (\(id))" + (notes.isEmpty ? "" : " · " + notes.joined(separator: ", "))
            }
        var text = "Running apps:\n" + lines.joined(separator: "\n")
        if !AXIsProcessTrusted() {
            text += "\n\nStickman doesn't have Accessibility permission yet, so other tools will fail until the user grants it."
        }
        return text
    }

    // MARK: Activity

    private func markActive(appName: String) {
        lastCallAt = Date()
        overlay.showBanner(appName: appName)
        if !isActive {
            isActive = true
            post(active: true, appName: appName)
        }
        if idleTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkIdle() }
            }
            RunLoop.main.add(timer, forMode: .common)
            idleTimer = timer
        }
    }

    private func checkIdle() {
        guard let lastCallAt else { return }
        let idle = Date().timeIntervalSince(lastCallAt)
        // Claude may think between steps; the banner stays while it's plausibly mid-task.
        if isActive, idle > 12 {
            isActive = false
            overlay.hideBanner()
            post(active: false, appName: nil)
        }
        if idle > 600 {
            allowedThisRun.removeAll()
            idleTimer?.invalidate()
            idleTimer = nil
        }
    }

    private func stopFromUser() {
        stoppedUntil = Date().addingTimeInterval(120)
        isActive = false
        overlay.showStopped()
        post(active: false, appName: nil, stopped: true)
    }

    private func post(active: Bool, appName: String?, stopped: Bool = false) {
        var info: [String: Any] = ["active": active, "stopped": stopped]
        if let appName { info["app"] = appName }
        NotificationCenter.default.post(name: .stickmanComputerUseDidChange, object: self, userInfo: info)
    }

    private func showRipple(at point: CGPoint) {
        guard point != .zero, let primary = NSScreen.screens.first else { return }
        ScreenEffectsOverlayController.shared.showClickRipple(at: CGPoint(x: point.x, y: primary.frame.maxY - point.y))
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        number(value).map { Int($0.rounded()) }
    }
}

/// A Unix socket that accepts one JSON request line per connection and answers with one line.
/// Only the bundled relay may connect: the peer's executable path must match.
final class ComputerUseSocketServer: @unchecked Sendable {
    private let path: String
    private let allowedPeer: String
    private let handler: @Sendable (Data) async -> Data
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "com.chaymore.Stickman.computer-use", attributes: .concurrent)

    init(path: String, allowedPeer: String, handler: @escaping @Sendable (Data) async -> Data) {
        self.path = path
        self.allowedPeer = allowedPeer
        self.handler = handler
    }

    struct SocketError: Error, CustomStringConvertible {
        let description: String
    }

    func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(description: "socket: \(errno)") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw SocketError(description: "socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            close(fd)
            throw SocketError(description: "bind: \(errno)")
        }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            close(fd)
            throw SocketError(description: "listen: \(errno)")
        }
        listenFD = fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "Stickman computer use"
        thread.start()
    }

    func stop() {
        if listenFD >= 0 { close(listenFD) }
        listenFD = -1
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            queue.async { [weak self] in
                self?.serve(client)
                close(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        guard peerIsRelay(client) else { return }
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var request = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while request.count < 4_000_000 {
            let count = read(client, &chunk, chunk.count)
            if count <= 0 { break }
            request.append(contentsOf: chunk[0 ..< count])
            if chunk[count - 1] == 0x0A { break }
        }
        guard !request.isEmpty else { return }

        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let handler = self.handler
        Task {
            box.data = await handler(request)
            done.signal()
        }
        done.wait()

        var reply = box.data
        reply.append(0x0A)
        reply.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(client, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    /// Checks the connecting process is the relay bundled with this copy of Stickman.
    private func peerIsRelay(_ client: Int32) -> Bool {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return false }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let peerPath = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        return peerPath == allowedPeer
    }
}
