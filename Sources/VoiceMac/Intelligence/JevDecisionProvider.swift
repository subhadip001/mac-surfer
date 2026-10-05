import Foundation

/// Jev / System One as a structured decision engine.
///
/// `POST {base}/v1/systemone` with a `state` object and a set of typed
/// questions; the response contains typed answers with calibrated confidence —
/// a `choice` for which action, `noul` probabilities for the gating questions,
/// and a `score` for risk. Nothing is generated as text, so there is no JSON to
/// repair and no prose to parse.
///
/// This is why parameter extraction lives elsewhere: Jev cannot return the
/// string "best bengali restaurants in kolkata". It can only tell us that the
/// action is `searchWeb`.
struct JevDecisionProvider: DecisionProvider {
    let apiKey: String
    let model: String
    let baseURL: String
    let session: URLSession

    init(apiKey: String,
         model: String = "jev-latest",
         baseURL: String = "https://api.typesafe.ai") {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL

        let configuration = URLSessionConfiguration.ephemeral
        // Jev answers in 70–500 ms; anything slower than this is not useful to
        // a pipeline whose whole point is pre-emptive execution.
        configuration.timeoutIntervalForRequest = 2.5
        configuration.httpMaximumConnectionsPerHost = 4
        self.session = URLSession(configuration: configuration)
    }

    func decide(_ context: DecisionContext) async throws -> Decision {
        guard !apiKey.isEmpty else { throw DecisionError.missingAPIKey }
        guard let url = URL(string: baseURL + "/v1/systemone") else {
            throw DecisionError.badResponse("invalid base URL")
        }

        var actionCriteria: [String: String] = [:]
        for type in context.availableActions {
            actionCriteria[type.rawValue] = type.criteria
        }
        actionCriteria["none"] = "The transcript does not yet contain a complete, actionable command."

        let body: [String: Any] = [
            "model": model,
            "state": context.statePayload(),
            "questions": [
                "action": [
                    "type": "choice",
                    "instructions": "The user is speaking a command to their Mac. Which single action should execute next, given what has already been executed?",
                    "criteria": actionCriteria,
                ],
                "needs_more_speech": [
                    "type": "noul",
                    "instructions": "Does this command still need more speech before it can be executed correctly?",
                    "criteria": [
                        "true": "The transcript is cut off mid-command, or a required detail such as a search query or target name is clearly incomplete.",
                        "false": "The command has everything it needs to execute as stated.",
                    ],
                ],
                "safe_to_speculate": [
                    "type": "noul",
                    "instructions": "Is it safe to execute this action immediately, before the user has finished speaking?",
                    "criteria": [
                        "true": "The action is easily reversible and has no effect anyone else can see — opening or focusing an app, opening a URL, scrolling, taking a screenshot.",
                        "false": "The action changes data, sends something to another person, or is hard to undo.",
                    ],
                ],
                "risk": [
                    "type": "score",
                    "instructions": "How risky is executing this action without explicit user confirmation?",
                    "criteria": [
                        "Fully reversible, affects only window state.",
                        "Changes application state or input focus but harms nothing.",
                        "Irreversible, destructive, or visible to other people.",
                    ],
                ],
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

        var decision = try parse(data)
        decision.latencyMs = elapsed.milliseconds
        log(.jev, "decision in \(elapsed.milliseconds) ms — \(decision.actionType?.rawValue ?? "none"), execute_now=\(decision.shouldExecuteNow), needs_more_speech=\(decision.needsMoreSpeech), risk=\(decision.riskLevel.label)")
        return decision
    }

    // MARK: Response

    private func parse(_ data: Data) throws -> Decision {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any] else {
            throw DecisionError.badResponse("missing answers object")
        }

        // choice
        var actionType: ActionType?
        var confidence: Double?
        var probabilities: [String: Double] = [:]
        if let answer = answers["action"] as? [String: Any] {
            if let choice = answer["choice"] as? String, choice != "none" {
                actionType = ActionType(rawValue: choice)
            }
            confidence = answer["confidence"] as? Double
            if let raw = answer["probabilities"] as? [String: Any] {
                for (key, value) in raw {
                    if let number = value as? Double { probabilities[key] = number }
                    else if let number = value as? NSNumber { probabilities[key] = number.doubleValue }
                }
            }
        }

        // noul answers are probabilities of "true"
        let needsMoreSpeech = noul(answers["needs_more_speech"]) ?? false
        let safeToSpeculate = noul(answers["safe_to_speculate"]) ?? false

        // score -> risk level
        var risk: RiskLevel = actionType?.defaultRisk ?? .safe
        if let answer = answers["risk"] as? [String: Any],
           let score = answer["score"] as? Double {
            let rounded = Int(score.rounded())
            risk = RiskLevel(rawValue: min(max(rounded, 0), 2)) ?? risk
        }
        // The action type's own floor always wins — a model cannot declare
        // `sendMessage` safe.
        if let actionType { risk = max(risk, actionType.defaultRisk) }

        let shouldExecuteNow = actionType != nil
            && !needsMoreSpeech
            && (safeToSpeculate || risk == .safe)

        return Decision(actionType: actionType,
                        shouldExecuteNow: shouldExecuteNow,
                        needsMoreSpeech: needsMoreSpeech,
                        confidence: confidence,
                        riskLevel: risk,
                        reason: safeToSpeculate ? "safe to speculate" : "deferred",
                        safeToSpeculate: safeToSpeculate,
                        probabilities: probabilities)
    }

    /// Reads a `noul` answer as a probability, thresholded at 0.5.
    private func noul(_ raw: Any?) -> Bool? {
        guard let answer = raw as? [String: Any] else { return nil }
        guard let probability = answer["noul"] as? Double else { return nil }
        return probability >= 0.5
    }
}
