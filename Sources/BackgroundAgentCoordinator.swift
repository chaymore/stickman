import Foundation

enum StickmanAgentStatus: String, Codable {
    case queued
    case inProgress = "in_progress"
    case completed
    case failed
    case cancelled
    case incomplete

    var isActive: Bool { self == .queued || self == .inProgress }

    var displayName: String {
        switch self {
        case .queued: return "Queued"
        case .inProgress: return "Working"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .incomplete: return "Incomplete"
        }
    }
}

struct StickmanAgentTask: Codable, Identifiable, Equatable {
    let id: String
    let prompt: String
    let createdAt: Date
    var updatedAt: Date
    var status: StickmanAgentStatus
    var responseID: String?
    var result: String?
    var errorMessage: String?
    let opensBrowserLinks: Bool
    var openedURLs: [String]
}

enum StickmanAgentCommandParser {
    static func taskPrompt(from input: String) -> String? {
        let patterns = [
            #"(?i)^(?:(?:hey\s+)?stickman[, ]*)?(?:spawn|start|run|launch)\s+(?:a|an|another)?\s*(?:background\s+)?(?:sub[- ]?)?agent(?:\s+to|\s+for)?\s+(.+)$"#,
            #"(?i)^(?:(?:hey\s+)?stickman[, ]*)?ask\s+(?:a|an)\s+(?:background\s+)?(?:sub[- ]?)?agent\s+to\s+(.+)$"#,
            #"(?i)^(?:(?:hey\s+)?stickman[, ]*)?(?:sub[- ]?)?agent[, :]\s*(?:can you\s+)?(.+)$"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(input.startIndex ..< input.endIndex, in: input)
            guard let match = regex.firstMatch(in: input, range: range),
                  match.numberOfRanges > 1,
                  let capture = Range(match.range(at: 1), in: input)
            else { continue }
            let prompt = String(input[capture]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prompt.isEmpty { return prompt }
        }
        return nil
    }

    static func shouldOpenBrowserLinks(for prompt: String) -> Bool {
        let text = prompt.lowercased()
        let asksToOpen = text.contains("open") || text.contains("pull up") || text.contains("bring up")
        let mentionsBrowser = text.contains("tab") || text.contains("chrome") || text.contains("browser") || text.contains("website")
        return asksToOpen && mentionsBrowser
    }
}

enum StickmanAgentOutputParser {
    static func urls(in text: String, limit: Int = 5) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        var seen = Set<String>()
        return detector.matches(in: text, range: range).compactMap(\.url).filter { url in
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  seen.insert(url.absoluteString).inserted,
                  seen.count <= limit
            else { return false }
            return true
        }
    }

    static func outputText(from json: [String: Any]) -> String? {
        if let outputText = json["output_text"] as? String, !outputText.isEmpty { return outputText }
        guard let output = json["output"] as? [[String: Any]] else { return nil }
        let fragments = output.flatMap { item -> [String] in
            guard item["type"] as? String == "message",
                  let content = item["content"] as? [[String: Any]]
            else { return [] }
            return content.compactMap { part in
                guard part["type"] as? String == "output_text" else { return nil }
                return part["text"] as? String
            }
        }
        let joined = fragments.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}

extension Notification.Name {
    static let stickmanAgentTasksDidChange = Notification.Name("StickmanAgentTasksDidChange")
    static let stickmanAgentTaskDidComplete = Notification.Name("StickmanAgentTaskDidComplete")
}

@MainActor
final class BackgroundAgentCoordinator {
    static let shared = BackgroundAgentCoordinator()

    private(set) var tasks: [StickmanAgentTask] = []
    private let apiKey: String?
    private let model: String
    private let session: URLSession
    private let storageURL: URL
    private var pollTimer: Timer?
    private var currentlyPolling = Set<String>()

    init(
        apiKey: String? = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
        model: String = ProcessInfo.processInfo.environment["STICKMAN_AGENT_MODEL"] ?? "gpt-5.6-sol",
        storageURL: URL? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration)
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        loadTasks()
    }

    func start() {
        guard pollTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in await BackgroundAgentCoordinator.shared.pollActiveTasks() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        for task in tasks where task.status == .queued && task.responseID == nil {
            Task { await submit(taskID: task.id) }
        }
        Task { await pollActiveTasks() }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    @discardableResult
    func spawn(prompt: String, opensBrowserLinks: Bool? = nil) -> StickmanAgentTask {
        let task = StickmanAgentTask(
            id: String(UUID().uuidString.prefix(8)).lowercased(),
            prompt: prompt,
            createdAt: Date(),
            updatedAt: Date(),
            status: .queued,
            responseID: nil,
            result: nil,
            errorMessage: nil,
            opensBrowserLinks: opensBrowserLinks ?? StickmanAgentCommandParser.shouldOpenBrowserLinks(for: prompt),
            openedURLs: []
        )
        tasks.insert(task, at: 0)
        trimAndPersist()
        notifyChange()
        Task { await submit(taskID: task.id) }
        return task
    }

    func cancel(taskID: String) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        let responseID = tasks[index].responseID
        tasks[index].status = .cancelled
        tasks[index].updatedAt = Date()
        persist()
        notifyChange()
        guard let responseID else { return }
        Task { try? await cancelResponse(responseID) }
    }

    var activeCount: Int { tasks.filter { $0.status.isActive }.count }

    var compactSummary: String {
        guard !tasks.isEmpty else { return "No background agents yet." }
        let rows = tasks.prefix(8).map { task in
            let shortPrompt = task.prompt.count > 72 ? String(task.prompt.prefix(69)) + "…" : task.prompt
            return "• \(task.id) · \(task.status.displayName): \(shortPrompt)"
        }
        return "Background agents (\(activeCount) active):\n\(rows.joined(separator: "\n"))"
    }

    private func submit(taskID: String) async {
        guard let apiKey, !apiKey.isEmpty else {
            fail(taskID: taskID, message: "Stickman needs an OpenAI API key before he can launch background agents.")
            return
        }
        guard let task = tasks.first(where: { $0.id == taskID }), task.status == .queued else { return }

        let instructions = """
        You are one background specialist working for Stickman, a personal macOS assistant.
        Complete the assigned task independently and return a concise, useful result with source links when research is involved.
        Do not claim to have changed local files, apps, accounts, calendars, email, or browser state; Stickman's native harness performs those actions separately.
        If the request asks to open browser tabs, return the best direct URLs in the result so Stickman can open them after you finish.
        State blockers and uncertainty plainly. Stop when the requested deliverable is complete.
        """
        let localContext = await ConnectorRegistryService.shared.localContext(for: task.prompt)
        let agentInput = localContext.map {
            "\(task.prompt)\n\nTrusted local schedule context supplied by Stickman:\n\($0)"
        } ?? task.prompt
        let body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": agentInput,
            "background": true,
            "tools": [["type": "web_search"]],
            "reasoning": ["effort": "medium", "context": "current_turn"],
            "text": ["verbosity": "medium"]
        ]

        do {
            let json = try await requestJSON(
                url: URL(string: "https://api.openai.com/v1/responses")!,
                method: "POST",
                body: body,
                apiKey: apiKey
            )
            guard let responseID = json["id"] as? String else { throw AIClientError.invalidResponse }
            update(taskID: taskID) { task in
                task.responseID = responseID
                task.status = Self.status(from: json["status"] as? String) ?? .inProgress
            }
            if Self.status(from: json["status"] as? String) == .completed {
                finish(taskID: taskID, json: json)
            }
        } catch {
            fail(taskID: taskID, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func pollActiveTasks() async {
        let active = tasks.filter { $0.status.isActive && $0.responseID != nil }
        await withTaskGroup(of: Void.self) { group in
            for task in active {
                guard let responseID = task.responseID, !currentlyPolling.contains(responseID) else { continue }
                currentlyPolling.insert(responseID)
                group.addTask { [weak self] in
                    await self?.poll(taskID: task.id, responseID: responseID)
                }
            }
        }
    }

    private func poll(taskID: String, responseID: String) async {
        defer { currentlyPolling.remove(responseID) }
        guard let apiKey, !apiKey.isEmpty else { return }
        do {
            let json = try await requestJSON(
                url: URL(string: "https://api.openai.com/v1/responses/\(responseID)")!,
                method: "GET",
                body: nil,
                apiKey: apiKey
            )
            let status = Self.status(from: json["status"] as? String) ?? .inProgress
            switch status {
            case .completed:
                finish(taskID: taskID, json: json)
            case .failed, .cancelled, .incomplete:
                let error = Self.errorMessage(from: json) ?? "The background agent ended with status \(status.displayName.lowercased())."
                update(taskID: taskID) { task in
                    task.status = status
                    task.errorMessage = error
                }
            case .queued, .inProgress:
                update(taskID: taskID) { $0.status = status }
            }
        } catch {
            // Keep the task active after transient polling failures; the next timer tick retries.
        }
    }

    private func finish(taskID: String, json: [String: Any]) {
        let result = StickmanAgentOutputParser.outputText(from: json) ?? "The agent finished without a text result."
        update(taskID: taskID) { task in
            task.status = .completed
            task.result = result
            if task.opensBrowserLinks {
                for url in StickmanAgentOutputParser.urls(in: result) {
                    do {
                        try BrowserControlService.shared.openChromeTab(url, activate: false)
                        task.openedURLs.append(url.absoluteString)
                    } catch {
                        task.errorMessage = "The research finished, but Stickman could not open one or more Chrome tabs."
                    }
                }
            }
        }
        guard let task = tasks.first(where: { $0.id == taskID }) else { return }
        NotificationCenter.default.post(name: .stickmanAgentTaskDidComplete, object: self, userInfo: ["task": task])
    }

    private func fail(taskID: String, message: String) {
        update(taskID: taskID) { task in
            task.status = .failed
            task.errorMessage = message
        }
    }

    private func update(taskID: String, mutation: (inout StickmanAgentTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        mutation(&tasks[index])
        tasks[index].updatedAt = Date()
        persist()
        notifyChange()
    }

    private func requestJSON(url: URL, method: String, body: [String: Any]?, apiKey: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIClientError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = json?["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "Background agent request failed with status \(http.statusCode)."
            throw AIClientError.requestFailed(message)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIClientError.invalidResponse
        }
        return json
    }

    private func cancelResponse(_ responseID: String) async throws {
        guard let apiKey, !apiKey.isEmpty else { return }
        _ = try await requestJSON(
            url: URL(string: "https://api.openai.com/v1/responses/\(responseID)/cancel")!,
            method: "POST",
            body: [:],
            apiKey: apiKey
        )
    }

    private static func status(from raw: String?) -> StickmanAgentStatus? {
        guard let raw else { return nil }
        return StickmanAgentStatus(rawValue: raw)
    }

    private static func errorMessage(from json: [String: Any]) -> String? {
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let details = json["incomplete_details"] as? [String: Any], let reason = details["reason"] as? String { return reason }
        return nil
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .stickmanAgentTasksDidChange, object: self)
    }

    private func trimAndPersist() {
        if tasks.count > 50 { tasks.removeLast(tasks.count - 50) }
        persist()
    }

    private func loadTasks() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? decoder.decode([StickmanAgentTask].self, from: data)
        else { return }
        tasks = decoded
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(tasks).write(to: storageURL, options: .atomic)
        } catch {
            // A persistence failure should not crash or stop an in-flight agent.
        }
    }

    private static func defaultStorageURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return root.appendingPathComponent("Stickman/agent-tasks.json")
    }
}
