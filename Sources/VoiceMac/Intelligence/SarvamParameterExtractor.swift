import Foundation

/// Pulls typed string parameters out of a transcript using Sarvam's chat model.
///
/// Needed because Jev returns typed answers only — it can decide the action is
/// `searchWeb` but cannot hand back the query string. The model is constrained
/// hard: it may only fill in values for a fixed set of keys belonging to an
/// action type the local router or Jev already chose. It never picks the
/// action, and nothing it returns is executed directly.
struct SarvamParameterExtractor: ParameterExtractor {
    let apiKey: String
    let model: String
    let session: URLSession

    init(apiKey: String, model: String = "sarvam-105b") {
        self.apiKey = apiKey
        self.model = model

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.httpMaximumConnectionsPerHost = 4
        self.session = URLSession(configuration: configuration)
    }

    /// The only keys each action type accepts. Anything else is discarded.
    static func allowedKeys(for type: ActionType) -> [String] {
        switch type {
        case .openApp, .closeApp, .focusApp: return ["app"]
        case .openURL: return ["url"]
        case .searchWeb, .searchInApp: return ["query"]
        case .typeText: return ["text", "target"]
        case .sendMessage: return ["text", "recipient"]
        case .click, .doubleClick, .rightClick, .focusElement: return ["target"]
        case .clickAt: return ["x", "y"]
        case .menuCommand: return ["command", "menu"]
        case .clearField: return ["target"]
        case .pressKey: return ["key"]
        case .scroll: return ["direction"]
        case .setVolume: return ["level", "direction"]
        case .screenshot, .mute, .unmute, .copy, .paste: return []
        }
    }

    func extractParameters(for actionType: ActionType,
                           transcript: String,
                           context: DecisionContext) async throws -> [String: String] {
        let keys = Self.allowedKeys(for: actionType)
        guard !keys.isEmpty else { return [:] }
        guard !apiKey.isEmpty else { throw DecisionError.missingAPIKey }
        guard let url = URL(string: "https://api.sarvam.ai/v1/chat/completions") else {
            throw DecisionError.badResponse("invalid chat URL")
        }

        let schema = keys.map { "\"\($0)\": \"<value or empty string>\"" }.joined(separator: ", ")

        let system = """
        You extract parameters for a macOS voice assistant. The action has \
        already been chosen. Return ONLY a JSON object with exactly these keys: \
        { \(schema) }
        Rules:
        - Copy values verbatim from the user's words. Do not invent, expand, or \
        answer the request.
        - Strip command words like "open", "search for", "find".
        - If a value is not present in the transcript, use an empty string.
        - Output raw JSON only. No markdown, no explanation.
        """

        let user = """
        Action: \(actionType.rawValue)
        Frontmost app: \(context.frontmostApp.isEmpty ? "unknown" : context.frontmostApp)
        Transcript: \(transcript)
        """

        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "max_tokens": 200,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "api-subscription-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = ContinuousClock.now
        let (data, response) = try await session.data(for: request)
        let elapsed = ContinuousClock.now - started

        guard let http = response as? HTTPURLResponse else {
            throw DecisionError.badResponse("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw DecisionError.http(http.statusCode, detail)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw DecisionError.badResponse("missing choices[0].message.content")
        }

        let extracted = Self.parseJSONObject(content)
        // Whitelist: only keys this action type declares are kept.
        var parameters: [String: String] = [:]
        for key in keys {
            if let value = extracted[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                parameters[key] = value
            }
        }

        log(.llm, "extracted \(parameters.keys.sorted()) for \(actionType.rawValue) in \(elapsed.milliseconds) ms")
        return parameters
    }

    /// Tolerant JSON extraction — models wrap objects in fences or prose even
    /// when told not to.
    static func parseJSONObject(_ raw: String) -> [String: String] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            text = String(text[start...end])
        }

        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        var out: [String: String] = [:]
        for (key, value) in object {
            if let string = value as? String { out[key] = string }
            else if let number = value as? NSNumber { out[key] = number.stringValue }
        }
        return out
    }
}
