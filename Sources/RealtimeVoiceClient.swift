import Foundation

protocol RealtimeVoiceClientDelegate: AnyObject {
    func realtimeVoiceClient(_ client: RealtimeVoiceClient, didChangeStatus status: String)
    func realtimeVoiceClientDidDetectUserSpeech(_ client: RealtimeVoiceClient)
    func realtimeVoiceClient(_ client: RealtimeVoiceClient, didReceiveAssistantTranscriptDelta delta: String)
    func realtimeVoiceClient(_ client: RealtimeVoiceClient, didFinishAssistantTranscript transcript: String?)
    func realtimeVoiceClient(_ client: RealtimeVoiceClient, didFailWithError error: Error)
    @MainActor func realtimeVoiceClient(_ client: RealtimeVoiceClient, executeFunction name: String, arguments: [String: Any]) -> String
}

final class RealtimeVoiceClient {
    weak var delegate: RealtimeVoiceClientDelegate?

    private let apiKey: String?
    private let model: String
    private let voice: String
    private let instructions: String
    private let session: URLSession
    private let audioIO = RealtimeAudioIOController()
    private let socketQueue = DispatchQueue(label: "stickman.realtime.websocket")

    private var webSocketTask: URLSessionWebSocketTask?
    private var isConnected = false
    private var assistantTranscript = ""
    private var didFinishAssistantTranscript = false
    private var pendingFunctionCalls = Set<String>()
    private var responseIncludesFunctionCall = false

    init(
        apiKey: String? = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
        model: String = ProcessInfo.processInfo.environment["STICKMAN_REALTIME_MODEL"] ?? "gpt-realtime-2.1",
        voice: String = ProcessInfo.processInfo.environment["STICKMAN_REALTIME_VOICE"] ?? "marin",
        instructions: String = OpenAIResponsesClient.loadInstructions(),
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.voice = voice
        self.instructions = instructions
        self.session = session
    }

    func start() async throws {
        guard let apiKey, !apiKey.isEmpty else {
            throw AIClientError.missingAPIKey
        }

        await notifyStatus("Connecting voice...")

        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("stickman-local-user", forHTTPHeaderField: "OpenAI-Safety-Identifier")

        let task = session.webSocketTask(with: request)
        webSocketTask = task
        task.resume()
        isConnected = true

        receiveNextMessage()
        try await audioIO.start { [weak self] audio in
            self?.sendAudioChunk(audio)
        }
        sendSessionUpdate()
        await notifyStatus("Voice on. Talk to Stickman.")
    }

    func stop() {
        isConnected = false
        audioIO.stop()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        Task { await notifyStatus("Voice off.") }
    }

    func sendText(_ text: String) {
        assistantTranscript = ""
        didFinishAssistantTranscript = false
        sendJSON([
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": text
                    ]
                ]
            ]
        ])
        sendJSON(["type": "response.create"])
    }

    private func sendSessionUpdate() {
        let desktopContext = DesktopContextProvider.shared.currentContext().promptSummary
        let combinedInstructions = """
        \(instructions)

        Current desktop context visible to Stickman:
        \(desktopContext)

        Current local capability status:
        \(WebsiteBlockerService.shared.statusSummary)

        You are in live voice mode. Keep replies conversational, warm, and brief unless the user asks for detail.
        Use spawn_background_agent when the user asks you to delegate work or run a sub-agent. Use the Chrome tools for explicit browser requests. Tell the user what you started or changed after the tool returns.
        """

        sendJSON([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": model,
                "instructions": combinedInstructions,
                "output_modalities": ["audio"],
                "reasoning": ["effort": "low"],
                "tools": Self.functionTools,
                "tool_choice": "auto",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": Int(RealtimeAudioIOController.sampleRate)
                        ],
                        "turn_detection": [
                            "type": "semantic_vad",
                            "interrupt_response": false
                        ]
                    ],
                    "output": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": Int(RealtimeAudioIOController.sampleRate)
                        ],
                        "voice": voice
                    ]
                ]
            ]
        ])
    }

    private func sendAudioChunk(_ audio: String) {
        guard isConnected else { return }
        sendJSON([
            "type": "input_audio_buffer.append",
            "audio": audio
        ])
    }

    private func sendJSON(_ object: [String: Any]) {
        guard isConnected, let webSocketTask else { return }

        socketQueue.async {
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let string = String(data: data, encoding: .utf8) else {
                return
            }

            webSocketTask.send(.string(string)) { [weak self] error in
                guard let self, let error else { return }
                Task { await self.notifyError(error) }
            }
        }
    }

    private func receiveNextMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                self.handle(message)
                if self.isConnected {
                    self.receiveNextMessage()
                }
            case .failure(let error):
                if self.isConnected {
                    Task { await self.notifyError(error) }
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .data(let value):
            data = value
        case .string(let value):
            data = value.data(using: .utf8)
        @unknown default:
            data = nil
        }

        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "session.created", "session.updated":
            Task { await notifyStatus("Voice on. Talk to Stickman.") }
        case "input_audio_buffer.speech_started":
            assistantTranscript = ""
            didFinishAssistantTranscript = false
            Task { await notifyUserSpeech() }
        case "response.output_audio.delta":
            if let delta = json["delta"] as? String {
                audioIO.playPCM16(base64Audio: delta)
            }
        case "response.output_audio_transcript.delta", "response.output_text.delta":
            if let delta = json["delta"] as? String {
                assistantTranscript += delta
                Task { await notifyAssistantTranscriptDelta(delta) }
            }
        case "response.output_audio_transcript.done", "response.output_text.done":
            let transcript = (json["transcript"] as? String) ?? (json["text"] as? String)
            if let transcript, !transcript.isEmpty {
                assistantTranscript = transcript
            }
            notifyAssistantTranscriptDoneOnce()
        case "response.output_item.done":
            if let item = json["item"] as? [String: Any],
               item["type"] as? String == "function_call",
               let callID = item["call_id"] as? String,
               let name = item["name"] as? String {
                responseIncludesFunctionCall = true
                let rawArguments = item["arguments"] as? String ?? "{}"
                handleFunctionCall(callID: callID, name: name, rawArguments: rawArguments)
            }
        case "response.done":
            if responseIncludesFunctionCall {
                responseIncludesFunctionCall = false
            } else if pendingFunctionCalls.isEmpty {
                notifyAssistantTranscriptDoneOnce()
            }
        case "error", "invalid_request_error":
            Task { await notifyError(RealtimeVoiceServiceError.server(message: extractErrorMessage(from: json))) }
        default:
            break
        }
    }

    private func notifyAssistantTranscriptDoneOnce() {
        guard !didFinishAssistantTranscript else { return }
        didFinishAssistantTranscript = true
        Task { await notifyAssistantTranscriptDone(assistantTranscript.isEmpty ? nil : assistantTranscript) }
    }

    private func handleFunctionCall(callID: String, name: String, rawArguments: String) {
        guard pendingFunctionCalls.insert(callID).inserted else { return }
        let arguments: [String: Any]
        if let data = rawArguments.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            arguments = decoded
        } else {
            arguments = [:]
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let output = self.delegate?.realtimeVoiceClient(self, executeFunction: name, arguments: arguments)
                ?? #"{"error":"Stickman could not execute that tool."}"#
            self.pendingFunctionCalls.remove(callID)
            self.assistantTranscript = ""
            self.didFinishAssistantTranscript = false
            self.sendJSON([
                "type": "conversation.item.create",
                "item": [
                    "type": "function_call_output",
                    "call_id": callID,
                    "output": output
                ]
            ])
            self.sendJSON(["type": "response.create"])
        }
    }

    private static let functionTools: [[String: Any]] = [
        [
            "type": "function",
            "name": "spawn_background_agent",
            "description": "Launch a durable background specialist for research or another multi-step task while the user keeps working.",
            "parameters": [
                "type": "object",
                "properties": [
                    "task": ["type": "string", "description": "The complete task for the specialist."],
                    "open_browser_links": ["type": "boolean", "description": "True only when the user explicitly asked Stickman to open useful result links in Chrome."]
                ],
                "required": ["task", "open_browser_links"],
                "additionalProperties": false
            ]
        ],
        [
            "type": "function",
            "name": "open_chrome_tab",
            "description": "Open a URL or Google search in a new Chrome tab when the user explicitly asks.",
            "parameters": [
                "type": "object",
                "properties": ["destination": ["type": "string"]],
                "required": ["destination"],
                "additionalProperties": false
            ]
        ],
        [
            "type": "function",
            "name": "list_chrome_tabs",
            "description": "List the user's currently open Chrome tabs.",
            "parameters": ["type": "object", "properties": [:], "additionalProperties": false]
        ],
        [
            "type": "function",
            "name": "activate_chrome_tab",
            "description": "Switch to an existing Chrome tab matching a title or URL fragment.",
            "parameters": [
                "type": "object",
                "properties": ["query": ["type": "string"]],
                "required": ["query"],
                "additionalProperties": false
            ]
        ]
    ]

    private func extractErrorMessage(from json: [String: Any]) -> String {
        if let message = json["message"] as? String {
            return message
        }

        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }

        return "Realtime voice returned an unknown error."
    }

    @MainActor private func notifyStatus(_ status: String) {
        delegate?.realtimeVoiceClient(self, didChangeStatus: status)
    }

    @MainActor private func notifyUserSpeech() {
        delegate?.realtimeVoiceClientDidDetectUserSpeech(self)
    }

    @MainActor private func notifyAssistantTranscriptDelta(_ delta: String) {
        delegate?.realtimeVoiceClient(self, didReceiveAssistantTranscriptDelta: delta)
    }

    @MainActor private func notifyAssistantTranscriptDone(_ transcript: String?) {
        delegate?.realtimeVoiceClient(self, didFinishAssistantTranscript: transcript)
    }

    @MainActor private func notifyError(_ error: Error) {
        delegate?.realtimeVoiceClient(self, didFailWithError: error)
    }
}

enum RealtimeVoiceServiceError: LocalizedError {
    case server(message: String)

    var errorDescription: String? {
        switch self {
        case .server(let message):
            return message
        }
    }
}
