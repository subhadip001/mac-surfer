import Foundation

/// Compact state handed to the decision engine.
///
/// Deliberately small: a transcript, a little app context, and at most a
/// handful of pre-filtered UI elements. The full accessibility tree is never
/// included.
struct DecisionContext: Sendable {
    var transcript: String
    var stablePrefix: String
    var isFinal: Bool
    var frontmostApp: String
    var frontmostBundleID: String?
    var availableActions: [ActionType]
    var executedActions: [String]
    var relevantElements: [[String: String]]

    func statePayload() -> [String: Any] {
        var state: [String: Any] = [
            "transcript": transcript,
            "stable_prefix": stablePrefix,
            "user_finished_speaking": isFinal,
            "frontmost_app": frontmostApp,
            "available_actions": availableActions.map(\.rawValue),
            "executed_actions": executedActions,
        ]
        if let frontmostBundleID { state["frontmost_bundle_id"] = frontmostBundleID }
        if !relevantElements.isEmpty { state["relevant_ui_elements"] = relevantElements }
        return state
    }
}

/// A typed decision. No prose, no generated code — an action type, a few
/// booleans, and calibrated confidence.
struct Decision: Sendable {
    var actionType: ActionType?
    /// The engine believes this can run right now.
    var shouldExecuteNow: Bool
    /// The user is still mid-sentence; acting now would use partial information.
    var needsMoreSpeech: Bool
    var confidence: Double?
    var riskLevel: RiskLevel
    var reason: String?
    /// Filled in separately — a typed-decision model cannot emit strings.
    var parameters: [String: String] = [:]
    /// Jev's answer to the speculative-safety question, kept separate from
    /// `shouldExecuteNow` so the raw judgement is visible in the UI.
    var safeToSpeculate: Bool = false
    /// Per-option probabilities from the `choice` answer.
    var probabilities: [String: Double] = [:]
    var latencyMs: Int?

    static let noAction = Decision(actionType: nil,
                                   shouldExecuteNow: false,
                                   needsMoreSpeech: false,
                                   confidence: nil,
                                   riskLevel: .safe,
                                   reason: "no action selected")

    /// Builds the executable request, once parameters are known.
    func action(sourceText: String, dependencies: [UUID] = []) -> ActionRequest? {
        guard let actionType else { return nil }
        return ActionRequest(type: actionType,
                             parameters: parameters,
                             riskLevel: riskLevel,
                             dependencies: dependencies,
                             origin: .jev,
                             sourceText: sourceText,
                             parametersAreStable: !needsMoreSpeech)
    }
}

/// A single call to the decision engine, recorded so it is visible in the UI
/// and in history — including calls that chose nothing.
///
/// Without this, Jev is invisible: you cannot tell "Jev said no" apart from
/// "Jev was never asked", which are very different things.
struct JevConsultation: Codable, Sendable, Identifiable {
    let id: UUID
    let at: Date
    /// The text Jev was asked about.
    let transcript: String
    /// Why it was consulted at all.
    let reason: String
    var chosenAction: String?
    var confidence: Double?
    var needsMoreSpeech: Bool?
    var safeToSpeculate: Bool?
    var risk: String?
    var probabilities: [String: Double]?
    var latencyMs: Int?
    /// Did this consultation actually produce an executed action?
    var applied: Bool
    /// Human-readable result: dispatched, declined, or the error.
    var outcome: String

    init(transcript: String, reason: String) {
        self.id = UUID()
        self.at = Date()
        self.transcript = transcript
        self.reason = reason
        self.applied = false
        self.outcome = "pending"
    }

    /// Top alternatives, strongest first — shows what Jev weighed up.
    var rankedOptions: [(String, Double)] {
        (probabilities ?? [:])
            .sorted { $0.value > $1.value }
            .prefix(4)
            .map { ($0.key, $0.value) }
    }
}

protocol DecisionProvider: Sendable {
    func decide(_ context: DecisionContext) async throws -> Decision
}

/// Extracts the string parameters an action needs. Separated from
/// `DecisionProvider` because the two are fundamentally different model types:
/// one classifies, one generates text.
protocol ParameterExtractor: Sendable {
    func extractParameters(for actionType: ActionType,
                           transcript: String,
                           context: DecisionContext) async throws -> [String: String]
}

enum DecisionError: LocalizedError {
    case missingAPIKey
    case badResponse(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Jev API key set — falling back to local commands only."
        case .badResponse(let detail):
            return "Unexpected decision response: \(detail)"
        case .http(let code, let body):
            // Shared by the decision engine and the parameter extractor, so
            // the wording must not claim it was a decision call.
            return "Request failed (HTTP \(code)): \(body)"
        }
    }
}
