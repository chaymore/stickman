import Foundation

enum StickmanTaskAnimation: String {
    case spawnAgent
    case openBrowserTab
    case checkCalendar
    case requestPermission
    case connectService
    /// The dance easter egg.
    case dance
}

extension Notification.Name {
    static let stickmanTaskAnimationRequested = Notification.Name("StickmanTaskAnimationRequested")
}

@MainActor
enum StickmanTaskAnimationController {
    static func play(_ animation: StickmanTaskAnimation) {
        NotificationCenter.default.post(
            name: .stickmanTaskAnimationRequested,
            object: nil,
            userInfo: ["animation": animation.rawValue]
        )
    }
}

/// The dance easter egg: "dance", "can you dance?", "do a little dance", "bust a move".
enum StickmanDanceCommand {
    static func matches(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"(?i)^(?:hey\s+|yo\s+)?(?:stickman[,!]?\s+)?(?:can\s+you\s+|could\s+you\s+|will\s+you\s+|please\s+|let'?s\s+see\s+you\s+|time\s+to\s+)?(?:do\s+(?:a|some|the|your|a\s+little)\s+)?(?:little\s+)?(?:dance|bust\s+a\s+move|show\s+(?:me\s+)?your\s+moves|dance\s+party)(?:\s+for\s+me)?(?:[,]?\s+stickman)?(?:\s+please)?[.!?]*$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    static func reply() -> String {
        ["Say less.", "Hit it.", "You asked for this.", "Clear the floor.", "One time only. Maybe."].randomElement() ?? "Hit it."
    }
}
