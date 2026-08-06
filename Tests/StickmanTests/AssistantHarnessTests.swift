import Foundation
import Testing
@testable import Stickman

struct AssistantHarnessTests {
    @Test func agentCommandsExtractTheBackgroundTask() {
        #expect(StickmanAgentCommandParser.taskPrompt(from: "spawn an agent to research my religion paper") == "research my religion paper")
        #expect(StickmanAgentCommandParser.taskPrompt(from: "Stickman agent, can you find the Canvas assignment") == "find the Canvas assignment")
        #expect(StickmanAgentCommandParser.taskPrompt(from: "what time is it") == nil)
    }

    @Test func browserOpeningRequiresAnExplicitAgentRequest() {
        #expect(StickmanAgentCommandParser.shouldOpenBrowserLinks(for: "research the assignment and open the useful Chrome tabs"))
        #expect(!StickmanAgentCommandParser.shouldOpenBrowserLinks(for: "research the assignment"))
        #expect(!StickmanAgentCommandParser.shouldOpenBrowserLinks(for: "tell me about browser tabs"))
    }

    @Test func agentOutputKeepsUniqueWebLinksOnly() {
        let text = "Use https://canvas.byu.edu first, then https://learningsuite.byu.edu. Canvas again: https://canvas.byu.edu"
        let urls = StickmanAgentOutputParser.urls(in: text)
        #expect(urls.map(\.absoluteString) == ["https://canvas.byu.edu", "https://learningsuite.byu.edu"])
    }

    @Test func browserDestinationsNormalizeDomainsWithoutGuessingSearches() {
        #expect(BrowserControlService.resolvedURL(from: "canvas.byu.edu")?.absoluteString == "https://canvas.byu.edu")
        #expect(BrowserControlService.resolvedURL(from: "https://learningsuite.byu.edu")?.absoluteString == "https://learningsuite.byu.edu")
        #expect(BrowserControlService.resolvedURL(from: "religion homework") == nil)
    }

    @Test func appleScriptEscapingProtectsQuotedURLs() {
        #expect(BrowserControlService.escapeForAppleScript(#"https://example.com/?q="test""#) == #"https://example.com/?q=\"test\""#)
    }

    @Test func canvasTenantAcceptsSchoolDomainsButRequiresHTTPS() {
        #expect(CanvasService.normalizedBaseURL(from: "canvas.example.edu/courses")?.absoluteString == "https://canvas.example.edu")
        #expect(CanvasService.normalizedBaseURL(from: "https://school.instructure.com/profile/settings")?.absoluteString == "https://school.instructure.com")
        #expect(CanvasService.normalizedBaseURL(from: "http://canvas.example.edu") == nil)
        #expect(CanvasService.normalizedBaseURL(from: "not a url") == nil)
    }

    @Test func proactiveStudyPrepOnlyMatchesStudyBlocks() {
        let religion = StickmanCalendarEvent(
            id: "religion",
            title: "Religion homework",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3_600),
            location: nil,
            calendarTitle: "School",
            isAllDay: false
        )
        let lunch = StickmanCalendarEvent(
            id: "lunch",
            title: "Lunch with Sam",
            startDate: Date(),
            endDate: Date().addingTimeInterval(3_600),
            location: nil,
            calendarTitle: "Personal",
            isAllDay: false
        )
        #expect(ProactiveStudyService.isStudyEvent(religion))
        #expect(!ProactiveStudyService.isStudyEvent(lunch))
    }

    @Test func taskAnimationsAreIncludedInNativePreviewStates() {
        #expect(StickmanView.PreviewState.allCases.contains(.agentWave))
        #expect(StickmanView.PreviewState.allCases.contains(.browserWand))
        #expect(StickmanView.PreviewState.allCases.contains(.calendarPeek))
        #expect(StickmanView.PreviewState.allCases.contains(.permissionKey))
        #expect(StickmanView.PreviewState.allCases.contains(.connectorLink))
    }
}
