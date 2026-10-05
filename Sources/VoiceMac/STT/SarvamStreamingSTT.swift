import Foundation

/// Sarvam AI realtime speech-to-text over WebSocket.
///
/// Endpoint: `wss://api.sarvam.ai/speech-to-text-realtime/ws`
/// Auth:     `api-subscription-key` header
/// Audio in: `{"event": "audio_input", "audio": "<base64 linear16>"}`
/// Out:      `session.begin`, `vad.speech_start`, `transcript.partial`,
///           `transcript.final`, `vad.speech_end`, `session.end`, `error`
///
/// Chosen over Groq Whisper because Groq exposes only a batch
/// `/audio/transcriptions` endpoint — no socket, therefore no true partials,
/// which this app's mid-sentence execution requires.
actor SarvamStreamingSTT: StreamingSTT {
    private let configuration: STTConfiguration
    private let session: URLSession

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?

    private let continuation: AsyncStream<TranscriptEvent>.Continuation
    let transcriptStream: AsyncStream<TranscriptEvent>

    private var isOpen = false
    private var didFinish = false
    private var lastInterim = ""
    /// Set when the provider reported a fatal error. The socket closes
    /// immediately afterwards, and that close must not be re-reported as a
    /// separate connection failure — it would mask the real cause (for example
    /// an invalid API key) in the UI.
    private var didReceiveFatalError = false

    init(configuration: STTConfiguration) {
        self.configuration = configuration

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 15
        sessionConfig.waitsForConnectivity = false
        self.session = URLSession(configuration: sessionConfig)

        let (stream, cont) = AsyncStream<TranscriptEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.transcriptStream = stream
        self.continuation = cont
    }

    // MARK: Lifecycle

    func start() async throws {
        guard !configuration.apiKey.isEmpty else { throw STTError.missingAPIKey }

        var components = URLComponents(string: "wss://api.sarvam.ai/speech-to-text-realtime/ws")
        components?.queryItems = [
            URLQueryItem(name: "language_code", value: configuration.language),
            URLQueryItem(name: "model", value: configuration.model),
            URLQueryItem(name: "stream_type", value: configuration.streamType),
            URLQueryItem(name: "mode", value: "transcribe"),
            URLQueryItem(name: "endpointing", value: "vad"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(configuration.sampleRate)),
            URLQueryItem(name: "silence_duration_ms", value: String(configuration.silenceDurationMs)),
            URLQueryItem(name: "min_speech_duration_ms", value: "250"),
        ]
        if let prompt = configuration.prompt, !prompt.isEmpty {
            components?.queryItems?.append(
                URLQueryItem(name: "prompt", value: String(prompt.prefix(STTConfiguration.maxPromptCharacters)))
            )
        }

        guard let url = components?.url else { throw STTError.badURL }

        var request = URLRequest(url: url)
        request.setValue(configuration.apiKey, forHTTPHeaderField: "api-subscription-key")
        request.timeoutInterval = 15

        let task = session.webSocketTask(with: request)
        socket = task
        isOpen = true
        didFinish = false
        didReceiveFatalError = false
        lastInterim = ""

        task.resume()
        log(.stt, "connecting — model \(configuration.model), stream_type \(configuration.streamType), lang \(configuration.language)")

        startReceiveLoop(task)
        startKeepAlive()

        // The socket is usable immediately; `session.begin` confirms it and is
        // surfaced as `.connected` from the receive loop. We do not block on it
        // because waiting would add a round trip before the first audio frame.
    }

    func sendAudio(_ data: Data) async throws {
        guard isOpen, let socket, !didFinish else { return }
        let message: [String: Any] = [
            "event": "audio_input",
            "audio": data.base64EncodedString(),
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: payload, encoding: .utf8) else { return }

        do {
            try await socket.send(.string(text))
        } catch {
            guard isOpen else { return }
            isOpen = false
            emit(.failed(.transportFailed(error.localizedDescription)))
            emit(.closed)
        }
    }

    func finish() async {
        guard isOpen, let socket, !didFinish else { return }
        didFinish = true
        log(.stt, "flushing — awaiting final transcript")

        if let payload = try? JSONSerialization.data(withJSONObject: ["event": "end"]),
           let text = String(data: payload, encoding: .utf8) {
            try? await socket.send(.string(text))
        }

        // Give the provider a bounded window to return the last final
        // transcript before tearing the socket down.
        try? await Task.sleep(for: .milliseconds(900))
        await stop()
    }

    func stop() async {
        guard isOpen else { return }
        isOpen = false

        keepAliveTask?.cancel()
        keepAliveTask = nil
        receiveTask?.cancel()
        receiveTask = nil

        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session.invalidateAndCancel()

        log(.stt, "socket closed")
        emit(.closed)
        continuation.finish()
    }

    // MARK: Receive

    private func startReceiveLoop(_ task: URLSessionWebSocketTask) {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard let self else { return }
                    switch message {
                    case .string(let text):
                        await self.handle(text: text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            await self.handle(text: text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    guard let self else { return }
                    await self.handleTransportFailure(error)
                    return
                }
            }
        }
    }

    private func handleTransportFailure(_ error: Error) async {
        guard isOpen else { return }
        // A close after `finish()` is expected, and a close that follows a
        // fatal provider error has already been reported. Neither is a new
        // failure.
        if didFinish || didReceiveFatalError {
            isOpen = false
            emit(.closed)
            continuation.finish()
            return
        }
        isOpen = false
        log(.stt, "transport failure: \(error.localizedDescription)")
        emit(.failed(.connectionFailed(error.localizedDescription)))
        emit(.closed)
        continuation.finish()
    }

    private func startKeepAlive() {
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                await self.ping()
            }
        }
    }

    private func ping() async {
        guard isOpen, let socket, !didFinish else { return }
        if let payload = try? JSONSerialization.data(withJSONObject: ["event": "ping"]),
           let text = String(data: payload, encoding: .utf8) {
            try? await socket.send(.string(text))
        }
    }

    // MARK: Message parsing

    /// Sarvam has shipped two realtime socket shapes: the newer flat
    /// `{"event": "...", ...}` form and an older `{"type": ..., "data": {...}}`
    /// envelope. Both are accepted so a provider-side rollout cannot silently
    /// break transcription.
    private func handle(text: String) async {
        guard let raw = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return
        }

        if let event = object["event"] as? String {
            handleFlat(event: event, object: object)
            return
        }

        if let type = object["type"] as? String {
            handleEnveloped(type: type, data: object["data"] as? [String: Any] ?? [:])
            return
        }
    }

    private func handleFlat(event: String, object: [String: Any]) {
        let text = (object["text"] as? String) ?? (object["transcript"] as? String) ?? ""

        switch event {
        case "session.begin":
            log(.stt, "session.begin")
            emit(.connected)

        case "vad.speech_start":
            emit(.speechStarted)

        case "vad.speech_end":
            emit(.speechEnded)

        case "transcript.partial":
            emitInterim(text)

        case "transcript.final":
            emitFinal(text)

        case "session.end":
            if let duration = object["audio_duration_s"] as? Double {
                log(.stt, "session.end — billed audio \(String(format: "%.1f", duration)) s")
            }

        case "error":
            let code = (object["code"] as? String) ?? String(describing: object["code"] ?? "unknown")
            let message = (object["message"] as? String) ?? "unknown error"
            let fatal = (object["is_fatal"] as? Bool) ?? true
            let status = (object["status_code"] as? Int).map { " (HTTP \($0))" } ?? ""
            log(.stt, "error \(code)\(status): \(message)")
            if fatal { didReceiveFatalError = true }
            emit(.failed(.remote(code: code, message: message, fatal: fatal)))

        case "pong", "config.updated":
            break

        default:
            log(.stt, "unhandled event \(event)")
        }
    }

    private func handleEnveloped(type: String, data: [String: Any]) {
        switch type {
        case "data":
            // Legacy socket does not distinguish partial from final; treat
            // incremental payloads as interim and let end-of-turn finalize.
            let transcript = (data["transcript"] as? String) ?? ""
            emitInterim(transcript)

        case "events":
            switch data["signal_type"] as? String {
            case "START_SPEECH": emit(.speechStarted)
            case "END_SPEECH": emit(.speechEnded)
            default: break
            }

        case "error":
            let code = (data["code"] as? String) ?? "unknown"
            let message = (data["error"] as? String) ?? "unknown error"
            log(.stt, "error \(code): \(message)")
            emit(.failed(.remote(code: code, message: message, fatal: true)))

        default:
            break
        }
    }

    private func emitInterim(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastInterim else { return }
        lastInterim = trimmed
        log(.stt, "interim: \"\(trimmed)\"", sensitive: true)
        emit(.interim(trimmed))
    }

    private func emitFinal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastInterim = ""
        log(.stt, "final: \"\(trimmed)\"", sensitive: true)
        emit(.final(trimmed))
    }

    private func emit(_ event: TranscriptEvent) {
        continuation.yield(event)
    }
}
