import Foundation

enum ChatRole {
    case assistant
    case user
}

struct ChatMessage {
    let role: ChatRole
    var content: String
}

struct ScreenshotAttachment {
    let dataURL: String
    let capturedAt: Date
}

protocol AIClient {
    func reply(
        messages: [ChatMessage],
        desktopContext: DesktopContext?,
        screenshot: ScreenshotAttachment?
    ) async throws -> String
}

enum AIClientError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case requestFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Set OPENAI_API_KEY in your shell before launching Stickman."
        case .invalidResponse:
            return "Stickman received an unexpected response from the AI service."
        case .requestFailed(let message):
            return message
        case .timedOut:
            return "Stickman's AI request timed out. Check your network, API key, and model access, then try again."
        }
    }
}
