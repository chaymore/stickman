import Testing
import Foundation
@testable import Stickman

@Suite
struct ClaudeCodeTests {
    @Test func slashCommandsParse() {
        let local = ClaudeCodeCommandParser.parse("/claude @lsat-compass fix the failing login test")
        #expect(local?.task == "fix the failing login test")
        #expect(local?.explicitProject == "lsat-compass")
        #expect(local?.runsInCloud == false)

        let cloud = ClaudeCodeCommandParser.parse("/cloud @stickman add a dark mode screenshot to the README")
        #expect(cloud?.runsInCloud == true)
        #expect(cloud?.explicitProject == "stickman")
    }

    @Test func naturalLanguageRequestsParse() {
        let request = ClaudeCodeCommandParser.parse("Have Claude fix the redirect bug in lsat-compass")
        #expect(request?.task == "fix the redirect bug in lsat-compass")
        #expect(request?.trailingProject == "lsat-compass")
        #expect(request?.taskWithoutTrailingProject == "fix the redirect bug")

        let cloud = ClaudeCodeCommandParser.parse("ask claude code to write tests for the parser in the cloud")
        #expect(cloud?.runsInCloud == true)
        #expect(cloud?.task == "write tests for the parser")

        #expect(ClaudeCodeCommandParser.parse("claude: tidy up the imports")?.task == "tidy up the imports")
        #expect(ClaudeCodeCommandParser.parse("what's the weather like") == nil)
        #expect(ClaudeCodeCommandParser.parse("/claude") == nil)
    }

    @Test func sessionNamesAreShortAndCapitalized() {
        #expect(ClaudeCodeCommandParser.sessionName(for: "fix the failing login test on the signup page please") == "Fix the failing login test on the")
    }

    @Test func backgroundSessionJSONParses() throws {
        let json = """
        [{"id":"7c5dcf5d","kind":"background","state":"blocked","status":"waiting","waitingFor":"permission prompt",
          "cwd":"/tmp/projects/lsat-compass","startedAt":1791231831874,"sessionId":"11111111-2222-4333-8444-555555555555","name":"Fix login"},
         {"kind":"interactive","cwd":"/tmp","startedAt":1791209880052,"sessionId":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","name":"chat","status":"busy","pid":66684}]
        """
        let array = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        let sessions = array.compactMap(ClaudeCodeSession.init(json:))
        #expect(sessions.count == 2)

        let background = sessions[0]
        #expect(background.id == "7c5dcf5d")
        #expect(background.isBackground)
        #expect(background.needsAttention)
        #expect(!background.isWorking)
        #expect(background.projectName == "lsat-compass")
        #expect(background.statusTitle == "Needs you · permission prompt")

        let interactive = sessions[1]
        #expect(interactive.id == "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        #expect(interactive.isWorking)
    }

    @Test func printedBackgroundIDIsFound() {
        let output = """
        Starting background service…
        backgrounded · 7c5dcf5d · Fix login
          claude attach 7c5dcf5d    open in this terminal
        """
        #expect(ClaudeCodeService.firstSessionID(in: output) == "7c5dcf5d")
        #expect(ClaudeCodeService.firstSessionID(in: "  claude attach a1b2c3d4  open") == "a1b2c3d4")
        #expect(ClaudeCodeService.firstSessionID(in: "something else") == nil)
    }

    @Test func terminalOutputLosesEscapeCodes() {
        let raw = "\u{1B}[1;32mDone\u{1B}[0m\r\n\u{1B}]0;title\u{07}All tests pass\n\n"
        #expect(StickmanChatPanelView.cleanTerminalOutput(raw) == "Done\nAll tests pass")
    }
}
