import Foundation

/// The complete set of things the app is allowed to do.
///
/// This enum is the security boundary. Jev and the LLM may only *select* from
/// these cases and fill in typed parameters — they can never introduce a new
/// capability, run a shell command, or supply code. Every case maps to hand
/// written Swift in `MacOSActionExecutor`.
enum ActionType: String, Sendable, CaseIterable, Codable {
    case openApp
    case closeApp
    case focusApp
    case openURL
    case searchWeb
    case searchInApp
    case click
    case doubleClick
    case rightClick
    case clickAt
    case focusElement
    case menuCommand
    case clearField
    case typeText
    case pressKey
    case scroll
    case screenshot
    case setVolume
    case mute
    case unmute
    case copy
    case paste
    case sendMessage

    /// Default risk, before any provider opinion is considered. The executor
    /// trusts this, not the model: a model that claims `sendMessage` is safe
    /// cannot downgrade it.
    var defaultRisk: RiskLevel {
        switch self {
        case .openApp, .focusApp, .openURL, .searchWeb, .scroll, .screenshot,
             .setVolume, .mute, .unmute, .searchInApp:
            return .safe
        case .closeApp, .click, .doubleClick, .rightClick, .clickAt,
             .focusElement, .menuCommand, .clearField, .typeText, .pressKey,
             .copy, .paste:
            return .caution
        case .sendMessage:
            return .destructive
        }
    }

    /// Parameters without which the action cannot run at all.
    ///
    /// Distinct from the full key list: `typeText` accepts a `target`, but only
    /// `text` is essential. Used to decide whether a text model is needed —
    /// if deterministic parsing already supplied these, it is not.
    var requiredParameterKeys: [String] {
        switch self {
        case .openApp, .closeApp, .focusApp: return ["app"]
        case .openURL: return ["url"]
        case .searchWeb, .searchInApp: return ["query"]
        case .typeText, .sendMessage: return ["text"]
        case .click, .doubleClick, .rightClick, .focusElement: return ["target"]
        case .clickAt: return ["x", "y"]
        case .menuCommand: return ["command"]
        case .pressKey: return ["key"]
        // These either need nothing or have a sensible default.
        case .clearField, .scroll, .setVolume, .screenshot,
             .mute, .unmute, .copy, .paste:
            return []
        }
    }

    /// True when the action carries free text whose exact content matters.
    /// Such actions must not fire from a prefix that is still growing.
    var carriesFreeText: Bool {
        switch self {
        case .searchWeb, .searchInApp, .typeText, .sendMessage: return true
        default: return false
        }
    }

    var displayName: String {
        switch self {
        case .openApp: return "Open app"
        case .closeApp: return "Quit app"
        case .focusApp: return "Focus app"
        case .openURL: return "Open URL"
        case .searchWeb: return "Search the web"
        case .searchInApp: return "Search in app"
        case .click: return "Click"
        case .doubleClick: return "Double-click"
        case .rightClick: return "Right-click"
        case .clickAt: return "Click at position"
        case .focusElement: return "Focus"
        case .menuCommand: return "Menu command"
        case .clearField: return "Clear field"
        case .typeText: return "Type text"
        case .pressKey: return "Press key"
        case .scroll: return "Scroll"
        case .screenshot: return "Screenshot"
        case .setVolume: return "Set volume"
        case .mute: return "Mute"
        case .unmute: return "Unmute"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .sendMessage: return "Send message"
        }
    }

    /// Short description handed to Jev as choice criteria.
    var criteria: String {
        switch self {
        case .openApp: return "Launch or open a named macOS application."
        case .closeApp: return "Quit or close a named macOS application."
        case .focusApp: return "Switch to or focus an already running application."
        case .openURL: return "Open a specific web address or domain in the browser."
        case .searchWeb: return "Perform a web search for a query."
        case .searchInApp: return "Search or find something inside the app that is currently in front."
        case .click: return "Click a button, link, or control in the frontmost app."
        case .doubleClick: return "Double-click an item, such as a file or a word to select it."
        case .rightClick: return "Right-click an item to open its context menu."
        case .clickAt: return "Click at explicit screen coordinates."
        case .focusElement: return "Put the keyboard focus into a named field or control without clicking anything else."
        case .menuCommand: return "Run a command from the application's menu bar, such as New Tab or Save As."
        case .clearField: return "Erase the contents of a text field."
        case .typeText: return "Type text into a text field, optionally a named one."
        case .pressKey: return "Press a keyboard key or shortcut."
        case .scroll: return "Scroll the current window up or down."
        case .screenshot: return "Capture a screenshot of the screen."
        case .setVolume: return "Change the system output volume."
        case .mute: return "Mute system audio."
        case .unmute: return "Unmute system audio."
        case .copy: return "Copy the current selection."
        case .paste: return "Paste the clipboard contents."
        case .sendMessage: return "Send a message, email, or post to someone. Irreversible."
        }
    }
}

enum RiskLevel: Int, Sendable, Comparable, Codable {
    /// Reversible, no side effects beyond window state. Speculate freely.
    case safe = 0
    /// Affects app state or input focus. Wait for a final transcript.
    case caution = 1
    /// Irreversible or visible to other people. Requires explicit confirmation.
    case destructive = 2

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .safe: return "safe"
        case .caution: return "caution"
        case .destructive: return "destructive"
        }
    }
}

/// Risk that depends on an action's parameters rather than its type alone.
///
/// `menuCommand` is the motivating case: "New Tab" and "Move to Trash" are the
/// same action type, but only one of them should run without being confirmed.
/// Matching is on whole words so "Undelete" or "Clear Formatting" are not
/// caught by "delete" or "clear".
enum RiskPolicy {
    private static let destructiveWords: Set<String> = [
        "delete", "trash", "erase", "remove", "destroy", "wipe",
        "uninstall", "reset", "revoke", "deactivate", "unsend",
        "send", "post", "publish", "purchase", "buy", "pay",
        "submit", "logout", "signout", "shutdown", "restart",
    ]

    private static let destructivePhrases: [String] = [
        "move to trash", "empty trash", "delete all", "clear history",
        "sign out", "log out", "shut down", "erase all",
    ]

    static func escalatedRisk(for type: ActionType,
                              parameters: [String: String]) -> RiskLevel {
        // Only parameter-driven commands can escalate; a scroll is a scroll.
        guard type == .menuCommand || type == .click || type == .doubleClick else {
            return type.defaultRisk
        }

        let haystack = [parameters["command"], parameters["menu"], parameters["target"]]
            .compactMap { $0 }
            .joined(separator: " ")
        let normalized = Fuzzy.normalize(haystack)
        guard !normalized.isEmpty else { return type.defaultRisk }

        for phrase in destructivePhrases where normalized.contains(phrase) {
            return .destructive
        }
        let words = Set(normalized.split(separator: " ").map(String.init))
        if !words.isDisjoint(with: destructiveWords) {
            return .destructive
        }
        return type.defaultRisk
    }
}

enum ActionOrigin: String, Sendable, Codable {
    case localRouter
    case jev
    case llm
    case manual
}

/// A single typed, validated unit of work.
struct ActionRequest: Identifiable, Sendable {
    let id: UUID
    let type: ActionType
    var parameters: [String: String]
    var riskLevel: RiskLevel
    /// Ids of actions that must complete first. `openApp` -> `searchInApp`.
    var dependencies: [UUID]
    var origin: ActionOrigin
    /// The transcript fragment this came from, for the debug panel.
    var sourceText: String
    /// False when the action's text parameters are still growing.
    var parametersAreStable: Bool
    let createdAt: Date

    init(id: UUID = UUID(),
         type: ActionType,
         parameters: [String: String] = [:],
         riskLevel: RiskLevel? = nil,
         dependencies: [UUID] = [],
         origin: ActionOrigin,
         sourceText: String = "",
         parametersAreStable: Bool = true,
         createdAt: Date = Date()) {
        self.id = id
        self.type = type
        self.parameters = parameters
        // Never let a caller lower the floor set by the action type, or by what
        // the parameters reveal the action actually does.
        self.riskLevel = max(riskLevel ?? type.defaultRisk,
                             RiskPolicy.escalatedRisk(for: type, parameters: parameters))
        self.dependencies = dependencies
        self.origin = origin
        self.sourceText = sourceText
        self.parametersAreStable = parametersAreStable
        self.createdAt = createdAt
    }

    /// A signature used to avoid executing the same clause twice as the
    /// transcript grows and the same text is re-parsed.
    var dedupeKey: String {
        let params = parameters.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Fuzzy.normalize($0.value))" }
            .joined(separator: "&")
        return "\(type.rawValue)|\(params)"
    }

    var summary: String {
        let detail = parameters["app"] ?? parameters["query"] ?? parameters["url"]
            ?? parameters["text"] ?? parameters["target"] ?? ""
        return detail.isEmpty ? type.displayName : "\(type.displayName): \(detail)"
    }
}

enum ActionStatus: Sendable, Equatable {
    case pending
    /// Waiting on dependencies, or on the transcript becoming stable enough.
    case waiting(String)
    case awaitingConfirmation
    case running
    case completed
    case failed(String)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }
}

struct ActionResult: Sendable {
    let id: UUID
    let success: Bool
    let message: String
    let duration: TimeInterval

    static func ok(_ id: UUID, _ message: String = "", duration: TimeInterval = 0) -> ActionResult {
        ActionResult(id: id, success: true, message: message, duration: duration)
    }
    static func failure(_ id: UUID, _ message: String, duration: TimeInterval = 0) -> ActionResult {
        ActionResult(id: id, success: false, message: message, duration: duration)
    }
}

enum ActionError: LocalizedError {
    case applicationNotFound(String)
    case missingParameter(String)
    case accessibilityPermissionRequired
    case elementNotFound(String)
    case unsupported(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .applicationNotFound(let name):
            return name.isEmpty ? "Application not found." : "Application not found: \(name)"
        case .missingParameter(let key):
            return "Missing required parameter: \(key)"
        case .accessibilityPermissionRequired:
            return "Accessibility permission required. Enable VoiceMac in System Settings › Privacy & Security › Accessibility."
        case .elementNotFound(let target):
            return "Could not find \"\(target)\" in the current window."
        case .unsupported(let what):
            return "Not supported yet: \(what)"
        case .executionFailed(let detail):
            return detail
        }
    }
}
