import Foundation

enum AIClientFactory {
    static func make() -> AIClient {
        let environment = ProcessInfo.processInfo.environment
        let prefersOpenRouter = environment["STICKMAN_AI_PROVIDER"]?.lowercased() == "openrouter"
        let hasOpenAI = environment["OPENAI_API_KEY"]?.isEmpty == false
        let hasOpenRouter = environment["OPENROUTER_API_KEY"]?.isEmpty == false
        if hasOpenRouter && (prefersOpenRouter || !hasOpenAI) {
            return OpenRouterClient()
        }
        return OpenAIResponsesClient()
    }
}

final class OpenRouterClient: AIClient {
    private let apiKey: String?
    private let model: String
    private let session: URLSession

    init(
        apiKey: String? = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"],
        model: String = ProcessInfo.processInfo.environment["STICKMAN_OPENROUTER_MODEL"] ?? "google/gemini-2.5-flash"
    ) {
        self.apiKey = apiKey
        self.model = model
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration)
    }

    func reply(
        messages: [ChatMessage],
        desktopContext: DesktopContext?,
        screenshot: ScreenshotAttachment?
    ) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else {
            throw AIClientError.requestFailed("No OpenRouter key is available in Stickman's Keychain.")
        }

        var sections: [String] = []
        if let desktopContext { sections.append(desktopContext.promptSummary) }
        sections.append(WebsiteBlockerService.shared.statusSummary)
        if screenshot != nil {
            sections.append("A fresh screenshot is attached. When visual pointing helps, append up to three tags like <stickman-guide x=\"0.42\" y=\"0.31\" label=\"Click File\"/> using normalized top-left coordinates.")
        }
        sections.append(messages.map { "\($0.role == .user ? "User" : "Stickman"): \($0.content)" }.joined(separator: "\n"))

        var content: [[String: Any]] = [["type": "text", "text": sections.joined(separator: "\n\n")]]
        if let screenshot {
            content.append(["type": "image_url", "image_url": ["url": screenshot.dataURL]])
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": OpenAIResponsesClient.loadInstructions()],
                ["role": "user", "content": content]
            ],
            "temperature": 0.4
        ]

        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Stickman macOS Desktop Buddy", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIClientError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = json?["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "OpenRouter request failed with status \(http.statusCode)."
            throw AIClientError.requestFailed(message)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw AIClientError.invalidResponse }
        return text
    }
}
