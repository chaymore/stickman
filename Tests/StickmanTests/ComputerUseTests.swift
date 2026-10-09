import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import Stickman

struct ComputerUseTests {
    @Test func parsesComputerUseRequests() {
        let slash = ClaudeCodeCommandParser.parse("/computer rename the Q3 deck in Keynote")
        #expect(slash?.usesComputer == true)
        #expect(slash?.task == "rename the Q3 deck in Keynote")
        #expect(slash?.runsInCloud == false)

        let spoken = ClaudeCodeCommandParser.parse("use my computer to add tomorrow's dentist appointment to Calendar")
        #expect(spoken?.usesComputer == true)
        #expect(spoken?.task == "add tomorrow's dentist appointment to Calendar")

        let viaClaude = ClaudeCodeCommandParser.parse("have Claude use my computer to clean up my desktop")
        #expect(viaClaude?.usesComputer == true)
        #expect(viaClaude?.task == "clean up my desktop")

        // Computer use only works on this Mac, so it never goes to the cloud.
        #expect(ClaudeCodeCommandParser.parse("/computer check my bank balance in the cloud")?.runsInCloud == false)
        #expect(ClaudeCodeCommandParser.parse("/claude fix the parser")?.usesComputer == false)
    }

    @Test func parsesKeysAndShortcuts() {
        let save = ComputerUseEngine.parseKey("cmd+s")
        #expect(save?.keyCode == CGKeyCode(kVK_ANSI_S))
        #expect(save?.flags == .maskCommand)

        let reopen = ComputerUseEngine.parseKey("Cmd+Shift+T")
        #expect(reopen?.keyCode == CGKeyCode(kVK_ANSI_T))
        #expect(reopen?.flags == [.maskCommand, .maskShift])

        #expect(ComputerUseEngine.parseKey("return")?.keyCode == CGKeyCode(kVK_Return))
        #expect(ComputerUseEngine.parseKey("esc")?.keyCode == CGKeyCode(kVK_Escape))
        #expect(ComputerUseEngine.parseKey("f5")?.keyCode == CGKeyCode(kVK_F5))
        #expect(ComputerUseEngine.parseKey("cmd++")?.keyCode == nil)
        #expect(ComputerUseEngine.parseKey("hyper+k") == nil)
        #expect(ComputerUseEngine.parseKey("") == nil)
    }

    @Test func namesRolesPlainly() {
        #expect(ComputerUseEngine.roleName("AXButton", subrole: nil, secure: false) == "button")
        #expect(ComputerUseEngine.roleName("AXTextField", subrole: "AXSearchField", secure: false) == "search field")
        #expect(ComputerUseEngine.roleName("AXTextField", subrole: nil, secure: true) == "password field")
        #expect(ComputerUseEngine.roleName("AXCheckBox", subrole: "AXSwitch", secure: false) == "switch")
        #expect(ComputerUseEngine.roleName("AXStaticText", subrole: nil, secure: false) == "text")
        #expect(ComputerUseEngine.clip("line one\nline \"two\"", 40) == "line one ↵ line 'two'")
        #expect(ComputerUseEngine.roleName("AXButton", subrole: "AXCloseButton", secure: false) == "close button")
        #expect(ComputerUseEngine.clip(String(repeating: "a", count: 20), 10) == "aaaaaaaaa…")
    }

    @Test func computerUseSessionsRunOnOpusWithStickmanTools() {
        let arguments = ClaudeCodeService.computerUseArguments(mcpConfig: "/tmp/computer-use-mcp.json")
        #expect(arguments.starts(with: ["--model", "opus", "--mcp-config", "/tmp/computer-use-mcp.json", "--allowedTools", "mcp__stickman"]))
        #expect(arguments.contains("--append-system-prompt"))
        #expect(ComputerUseService.offLimitsBundleIDs.contains("com.apple.Terminal"))
        #expect(ComputerUseService.offLimitsBundleIDs.contains("com.chaymore.Stickman"))
    }

    @Test func recognizesUntrustedWorkspaces() {
        #expect(ClaudeCodeService.isUntrustedWorkspace("Workspace not trusted. Run `claude` in /x once and accept the trust prompt, then retry."))
        #expect(ClaudeCodeService.isUntrustedWorkspace("this workspace has not been trusted"))
        #expect(!ClaudeCodeService.isUntrustedWorkspace("backgrounded · 7c5dcf5d · Fix the tests"))
    }
}
