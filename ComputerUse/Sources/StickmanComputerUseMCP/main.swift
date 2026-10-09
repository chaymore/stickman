import Darwin
import Foundation

// Stickman Computer Use: an MCP server over stdio for Claude Code.
//
// This process only speaks the protocol. Each tool call is forwarded over a private
// Unix socket to the running Stickman app, which holds the Accessibility and Screen
// Recording permissions, asks before touching a new app, and shows the "Esc to stop"
// banner while it works.

let serverName = "stickman"
let serverVersion = "0.1.0"
let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
let socketPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Stickman/computer-use.sock").path

let instructions = """
Stickman Computer Use operates Mac apps on the user's behalf. Prefer CLIs, APIs, and files when \
they can do the job; use these tools for work that needs an app's interface.

Loop: call get_app_state for the app to get a screenshot and a numbered outline of its controls. \
Act on a control by its element_index whenever it's listed, and fall back to x/y screenshot \
pixels only when it isn't. Every action returns the app's updated state, so read it to check the \
step worked before the next one. Element numbers always refer to the most recent state for that app.

The user approves each app the first time Claude uses it. Terminals, password managers, and \
System Settings are off-limits, and so are password fields. If a tool says the user pressed Esc \
or didn't allow an app, stop and report back instead of retrying.
"""

// MARK: Tool definitions

func schema(_ properties: [String: Any], required: [String]) -> [String: Any] {
    ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
}

let appProperty: [String: Any] = ["type": "string", "description": "App name or bundle identifier, like \"Safari\" or \"com.apple.Notes\"."]
let indexProperty: [String: Any] = ["type": "integer", "description": "Element number from the latest get_app_state for this app."]
let xProperty: [String: Any] = ["type": "number", "description": "X in the latest screenshot's pixels."]
let yProperty: [String: Any] = ["type": "number", "description": "Y in the latest screenshot's pixels."]

let tools: [[String: Any]] = [
    [
        "name": "list_apps",
        "description": "List running apps with their bundle identifiers, which one is frontmost, and which the user has already approved.",
        "inputSchema": schema([:], required: [])
    ],
    [
        "name": "open_app",
        "description": "Launch an app, or bring it to the front if it's already running.",
        "inputSchema": schema(["app": appProperty], required: ["app"])
    ],
    [
        "name": "get_app_state",
        "description": "Screenshot of the app's front window plus a numbered outline of its controls (role, label, value, position). Call this before acting and after each change.",
        "inputSchema": schema(["app": appProperty], required: ["app"])
    ],
    [
        "name": "click",
        "description": "Click a control by element_index (preferred), or at x/y in the screenshot. Returns the updated app state.",
        "inputSchema": schema([
            "app": appProperty,
            "element_index": indexProperty,
            "x": xProperty,
            "y": yProperty,
            "button": ["type": "string", "enum": ["left", "right"], "description": "Defaults to left."],
            "click_count": ["type": "integer", "description": "2 for a double-click. Defaults to 1."]
        ], required: ["app"])
    ],
    [
        "name": "type_text",
        "description": "Type text into whatever has keyboard focus in the app. Click or focus a field first.",
        "inputSchema": schema(["app": appProperty, "text": ["type": "string"]], required: ["app", "text"])
    ],
    [
        "name": "press_key",
        "description": "Press a key or shortcut, like \"return\", \"tab\", \"escape\", \"down\", \"cmd+s\", or \"cmd+shift+t\".",
        "inputSchema": schema(["app": appProperty, "key": ["type": "string"]], required: ["app", "key"])
    ],
    [
        "name": "scroll",
        "description": "Scroll over a control by element_index, or at x/y, or the middle of the window.",
        "inputSchema": schema([
            "app": appProperty,
            "element_index": indexProperty,
            "x": xProperty,
            "y": yProperty,
            "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
            "pages": ["type": "number", "description": "How far to scroll, in window heights. Defaults to 1."]
        ], required: ["app", "direction"])
    ],
    [
        "name": "set_value",
        "description": "Set a control's value directly, like a text field's contents or a slider's position.",
        "inputSchema": schema(["app": appProperty, "element_index": indexProperty, "value": ["type": "string"]], required: ["app", "element_index", "value"])
    ],
    [
        "name": "perform_action",
        "description": "Run one of a control's accessibility actions, like AXPress, AXShowMenu, AXIncrement, AXDecrement, AXConfirm, or AXRaise.",
        "inputSchema": schema(["app": appProperty, "element_index": indexProperty, "action": ["type": "string"]], required: ["app", "element_index", "action"])
    ],
    [
        "name": "drag",
        "description": "Drag from one point to another, in screenshot pixels.",
        "inputSchema": schema([
            "app": appProperty,
            "from_x": ["type": "number"], "from_y": ["type": "number"],
            "to_x": ["type": "number"], "to_y": ["type": "number"]
        ], required: ["app", "from_x", "from_y", "to_x", "to_y"])
    ]
]

// MARK: Stickman connection

func errorResult(_ message: String) -> [String: Any] {
    ["content": [["type": "text", "text": message]], "isError": true]
}

/// Sends one tool call to Stickman and waits for its JSON reply on the same line-based socket.
func callStickman(tool: String, arguments: [String: Any]) -> [String: Any] {
    let notRunning = "Stickman isn't running, so computer use is unavailable. Ask the user to open Stickman, then try again."
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return errorResult(notRunning) }
    defer { close(fd) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return errorResult("Socket path is too long.") }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: pathBytes)
        buffer[pathBytes.count] = 0
    }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return errorResult(notRunning) }

    // Approval prompts can take a while; give the user a few minutes to answer.
    var timeout = timeval(tv_sec: 300, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    guard var request = try? JSONSerialization.data(withJSONObject: ["tool": tool, "arguments": arguments]) else {
        return errorResult("Could not encode the request.")
    }
    request.append(0x0A)
    let sent = request.withUnsafeBytes { buffer -> Bool in
        var offset = 0
        while offset < buffer.count {
            let written = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if written <= 0 { return false }
            offset += written
        }
        return true
    }
    guard sent else { return errorResult("Lost the connection to Stickman.") }

    var reply = Data()
    var chunk = [UInt8](repeating: 0, count: 65_536)
    while true {
        let count = read(fd, &chunk, chunk.count)
        if count <= 0 { break }
        reply.append(contentsOf: chunk[0 ..< count])
        if chunk[count - 1] == 0x0A { break }
    }
    guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
        return errorResult("Stickman didn't answer in time.")
    }
    return object
}

// MARK: JSON-RPC over stdio

func emit(_ message: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

func respond(_ id: Any, result: [String: Any]) {
    emit(["jsonrpc": "2.0", "id": id, "result": result])
}

func respond(_ id: Any, errorCode: Int, message: String) {
    emit(["jsonrpc": "2.0", "id": id, "error": ["code": errorCode, "message": message]])
}

setvbuf(stdout, nil, _IONBF, 0)

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty,
          let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { continue }

    let id = message["id"]
    let method = message["method"] as? String ?? ""
    let params = message["params"] as? [String: Any] ?? [:]

    switch method {
    case "initialize":
        let requested = params["protocolVersion"] as? String ?? ""
        let version = supportedProtocolVersions.contains(requested) ? requested : supportedProtocolVersions[0]
        respond(id ?? 0, result: [
            "protocolVersion": version,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": serverName, "version": serverVersion],
            "instructions": instructions
        ])
    case "ping":
        respond(id ?? 0, result: [:])
    case "tools/list":
        respond(id ?? 0, result: ["tools": tools])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        guard tools.contains(where: { $0["name"] as? String == name }) else {
            respond(id ?? 0, result: errorResult("Unknown tool \(name)."))
            continue
        }
        respond(id ?? 0, result: callStickman(tool: name, arguments: arguments))
    default:
        // Notifications have no id and need no reply.
        if let id { respond(id, errorCode: -32601, message: "Method not found: \(method)") }
    }
}
