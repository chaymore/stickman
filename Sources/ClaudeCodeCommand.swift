import Foundation

/// A request to hand work to Claude Code, parsed from chat or voice.
struct ClaudeCodeRequest: Equatable {
    var task: String
    /// Named with `@project`. Must match a known project.
    var explicitProject: String?
    /// A trailing "in <name>". Used only when it matches a known project, since
    /// "fix the bug in the parser" is part of the task, not a project.
    var trailingProject: String?
    var taskWithoutTrailingProject: String?
    var runsInCloud: Bool
}

enum ClaudeCodeCommandParser {
    static func parse(_ input: String) -> ClaudeCodeRequest? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var body = commandBody(in: text) else { return nil }

        var runsInCloud = body.cloud
        for phrase in [#"(?i)\s*\b(?:in|on)\s+the\s+cloud\b"#, #"(?i)\s*\bin\s+a\s+cloud\s+session\b"#] {
            if let range = body.task.range(of: phrase, options: .regularExpression) {
                runsInCloud = true
                body.task.removeSubrange(range)
            }
        }

        var task = body.task
        var explicitProject: String?
        if let match = task.range(of: #"(?:^|\s)@([A-Za-z0-9._-]+)"#, options: .regularExpression) {
            explicitProject = String(task[match]).trimmingCharacters(in: .whitespaces).dropFirst().description
            task.removeSubrange(match)
        }
        task = tidy(task)
        guard !task.isEmpty else { return nil }

        var trailingProject: String?
        var withoutTrailing: String?
        let trailingPattern = #"(?i)\s+(?:in|for|on)\s+(?:the\s+|my\s+)?([A-Za-z0-9._-]+)(?:\s+(?:project|repo|repository|folder|app))?[.!?]*$"#
        if explicitProject == nil, let range = task.range(of: trailingPattern, options: .regularExpression) {
            let suffix = String(task[range])
            if let regex = try? NSRegularExpression(pattern: trailingPattern),
               let match = regex.firstMatch(in: suffix, range: NSRange(suffix.startIndex..., in: suffix)),
               let nameRange = Range(match.range(at: 1), in: suffix) {
                trailingProject = String(suffix[nameRange])
                withoutTrailing = tidy(String(task[..<range.lowerBound]))
            }
        }

        return ClaudeCodeRequest(
            task: task,
            explicitProject: explicitProject,
            trailingProject: trailingProject,
            taskWithoutTrailingProject: withoutTrailing,
            runsInCloud: runsInCloud
        )
    }

    /// A short session name from the task, like "Fix the login redirect".
    static func sessionName(for task: String) -> String {
        let words = task.split(whereSeparator: \.isWhitespace).prefix(7)
        var name = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ".,!?:;"))
        if let first = name.first { name = first.uppercased() + name.dropFirst() }
        return name.count > 60 ? String(name.prefix(57)) + "…" : name
    }

    private static func commandBody(in text: String) -> (task: String, cloud: Bool)? {
        let patterns: [(String, Bool)] = [
            (#"(?is)^/claude\s+(.+)$"#, false),
            (#"(?is)^/cloud\s+(.+)$"#, true),
            (#"(?is)^(?:hey\s+)?(?:have|ask|get|tell)\s+claude(?:\s+code)?\s+(?:to\s+)?(.+)$"#, false),
            (#"(?is)^claude(?:\s+code)?\s*[:,]\s*(.+)$"#, false)
        ]
        for (pattern, cloud) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text)
            else { continue }
            return (String(text[range]), cloud)
        }
        return nil
    }

    private static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
    }
}
