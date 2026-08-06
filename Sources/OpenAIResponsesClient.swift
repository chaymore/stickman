import Foundation

final class OpenAIResponsesClient: AIClient {
    private static let fallbackInstructions = "You are Stickman, a warm, concise macOS desktop companion. Be useful, direct, and friendly. You currently only know what the user types into this chat."

    private let apiKey: String?
    private let model: String
    private let instructions: String
    private let session: URLSession

    init(
        apiKey: String? = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
        model: String = ProcessInfo.processInfo.environment["STICKMAN_OPENAI_MODEL"] ?? "gpt-5.6-terra",
        instructions: String = OpenAIResponsesClient.loadInstructions(),
        session: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 45
            configuration.timeoutIntervalForResource = 90
            return URLSession(configuration: configuration)
        }()
    ) {
        self.apiKey = apiKey
        self.model = model
        self.instructions = instructions
        self.session = session
    }

    func reply(
        messages: [ChatMessage],
        desktopContext: DesktopContext?,
        screenshot: ScreenshotAttachment?
    ) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else {
            throw AIClientError.missingAPIKey
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: requestBody(
                messages: messages,
                desktopContext: desktopContext,
                screenshot: screenshot
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIClientError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw AIClientError.requestFailed(extractErrorMessage(from: data) ?? "OpenAI request failed with status \(httpResponse.statusCode).")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIClientError.invalidResponse
        }

        let text = extractOutputText(from: json)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw AIClientError.requestFailed("OpenAI returned HTTP 200, but Stickman could not find any output text in the response.")
        }

        return text
    }

    private func requestBody(
        messages: [ChatMessage],
        desktopContext: DesktopContext?,
        screenshot: ScreenshotAttachment?
    ) -> [String: Any] {
        let inputText = flattenedInput(from: messages, desktopContext: desktopContext, screenshot: screenshot)
        let input: Any

        if let screenshot {
            input = [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": inputText
                        ],
                        [
                            "type": "input_image",
                            "image_url": screenshot.dataURL,
                            "detail": "high"
                        ]
                    ]
                ]
            ]
        } else {
            input = inputText
        }

        return [
            "model": model,
            "instructions": instructions,
            "input": input,
            "reasoning": [
                "effort": "none",
                "context": "current_turn"
            ],
            "store": false
        ]
    }

    static func loadInstructions() -> String {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        let explicitPath = environment["STICKMAN_SYSTEM_PROMPT_PATH"]

        let candidatePaths: [String] = [
            explicitPath,
            environment["STICKMAN_PROJECT_DIR"].map { "\($0)/STICKMAN_SYSTEM_PROMPT.md" },
            URL(fileURLWithPath: CommandLine.arguments.first ?? "")
                .deletingLastPathComponent()
                .appendingPathComponent("STICKMAN_SYSTEM_PROMPT.md")
                .path,
            fileManager.currentDirectoryPath + "/STICKMAN_SYSTEM_PROMPT.md"
        ].compactMap { $0 }

        for path in candidatePaths where fileManager.fileExists(atPath: path) {
            if let text = try? String(contentsOfFile: path, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
        }

        return fallbackInstructions
    }

    private func flattenedInput(
        from messages: [ChatMessage],
        desktopContext: DesktopContext?,
        screenshot: ScreenshotAttachment?
    ) -> String {
        var sections: [String] = []

        if let desktopContext {
            sections.append("""
            Current desktop context visible to Stickman:
            \(desktopContext.promptSummary)
            """)
        }

        sections.append("""
        Current local capability status:
        \(WebsiteBlockerService.shared.statusSummary)
        """)

        if let screenshot {
            sections.append("""
            A screenshot captured at \(screenshot.capturedAt) is attached. Use it as visual context for the user's latest request.
            If pointing at one or more visible controls would materially help, add up to three tags after your answer in this exact format: <stickman-guide x="0.42" y="0.31" label="Click File"/>. Coordinates are normalized from the screenshot's top-left. Do not mention these tags in the prose.
            """)
        }

        sections.append(messages.map { message in
            let speaker = message.role == .user ? "User" : "Stickman"
            return "\(speaker): \(message.content)"
        }.joined(separator: "\n"))

        return sections.joined(separator: "\n\n")
    }

    private func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)
        }

        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }

        if let response = json["response"] as? [String: Any],
           let error = response["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }

        return nil
    }

    private func extractOutputText(from json: [String: Any]) -> String? {
        if let text = json["text"] as? String {
            return text
        }

        if let response = json["response"] as? [String: Any],
           let text = extractOutputText(fromResponseLikeObject: response) {
            return text
        }

        return extractOutputText(fromResponseLikeObject: json)
    }

    private func extractOutputText(fromResponseLikeObject object: [String: Any]) -> String? {
        if let content = object["content"] as? [[String: Any]] {
            let text = content.compactMap { part -> String? in
                guard (part["type"] as? String) == "output_text" || part["text"] is String else {
                    return nil
                }
                return part["text"] as? String
            }.joined()

            if !text.isEmpty {
                return text
            }
        }

        guard let output = object["output"] as? [[String: Any]] else {
            return nil
        }

        let text = output.compactMap { item in
            extractOutputText(fromResponseLikeObject: item)
        }.joined()

        return text.isEmpty ? nil : text
    }
}
