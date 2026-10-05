import Foundation
import Carbon.HIToolbox

/// Non-secret configuration, persisted in UserDefaults. Secrets go to Keychain.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    // MARK: STT

    @Published var sttProvider: STTProviderKind {
        didSet { defaults.set(sttProvider.rawValue, forKey: "sttProvider") }
    }

    @Published var language: String {
        didSet { defaults.set(language, forKey: "language") }
    }

    /// `saaras:v3-realtime` is the low-latency partial-transcript model.
    @Published var sttModel: String {
        didSet { defaults.set(sttModel, forKey: "sttModel") }
    }

    /// `fast` | `balanced` | `simulated` — controls partial-transcript latency.
    @Published var streamType: String {
        didSet { defaults.set(streamType, forKey: "streamType") }
    }

    /// Trailing silence that ends a turn. Lower = snappier, more false ends.
    @Published var silenceDurationMs: Int {
        didSet { defaults.set(silenceDurationMs, forKey: "silenceDurationMs") }
    }

    // MARK: Intelligence

    @Published var jevEnabled: Bool {
        didSet { defaults.set(jevEnabled, forKey: "jevEnabled") }
    }

    @Published var routingMode: RoutingMode {
        didSet { defaults.set(routingMode.rawValue, forKey: "routingMode") }
    }

    @Published var jevModel: String {
        didSet { defaults.set(jevModel, forKey: "jevModel") }
    }

    @Published var jevBaseURL: String {
        didSet { defaults.set(jevBaseURL, forKey: "jevBaseURL") }
    }

    /// Sarvam chat model used only for extracting string parameters that Jev,
    /// being a typed-decision model, cannot produce.
    @Published var llmModel: String {
        didSet { defaults.set(llmModel, forKey: "llmModel") }
    }

    // MARK: Behaviour

    /// Execute safe actions from a stable prefix before the sentence ends.
    @Published var speculativeExecution: Bool {
        didSet { defaults.set(speculativeExecution, forKey: "speculativeExecution") }
    }

    /// How many consecutive interim transcripts must agree on a prefix.
    @Published var stabilityWindow: Int {
        didSet { defaults.set(stabilityWindow, forKey: "stabilityWindow") }
    }

    @Published var searchEngine: SearchEngine {
        didSet { defaults.set(searchEngine.rawValue, forKey: "searchEngine") }
    }

    /// Record each spoken command and its actions to a local file.
    @Published var keepHistory: Bool {
        didSet { defaults.set(keepHistory, forKey: "keepHistory") }
    }

    @Published var debugMode: Bool {
        didSet {
            defaults.set(debugMode, forKey: "debugMode")
            AppLog.shared.debugMode = debugMode
        }
    }

    // MARK: Hotkeys

    @Published var listenHotKey: HotKeyCombo {
        didSet { defaults.set(listenHotKey.encoded, forKey: "listenHotKey") }
    }

    /// Use the Fn (Globe) key to start listening.
    @Published var useFnKey: Bool {
        didSet { defaults.set(useFnKey, forKey: "useFnKey") }
    }

    /// Held longer than this, Fn behaves as push-to-talk and releasing ends the
    /// command. A shorter tap toggles listening on and leaves it on.
    @Published var fnHoldThresholdMs: Int {
        didSet { defaults.set(fnHoldThresholdMs, forKey: "fnHoldThresholdMs") }
    }

    private init() {
        let d = UserDefaults.standard

        sttProvider = STTProviderKind(rawValue: d.string(forKey: "sttProvider") ?? "")
            ?? .sarvam
        language = d.string(forKey: "language") ?? "en-IN"
        sttModel = d.string(forKey: "sttModel") ?? "saaras:v3-realtime"
        streamType = d.string(forKey: "streamType") ?? "fast"
        silenceDurationMs = d.object(forKey: "silenceDurationMs") as? Int ?? 500

        jevEnabled = d.object(forKey: "jevEnabled") as? Bool ?? true
        routingMode = RoutingMode(rawValue: d.string(forKey: "routingMode") ?? "")
            ?? .localFirst
        jevModel = d.string(forKey: "jevModel") ?? "jev-latest"
        jevBaseURL = d.string(forKey: "jevBaseURL") ?? "https://api.typesafe.ai"
        llmModel = d.string(forKey: "llmModel") ?? "sarvam-30b"

        speculativeExecution = d.object(forKey: "speculativeExecution") as? Bool ?? true
        stabilityWindow = d.object(forKey: "stabilityWindow") as? Int ?? 2
        searchEngine = SearchEngine(rawValue: d.string(forKey: "searchEngine") ?? "")
            ?? .google
        keepHistory = d.object(forKey: "keepHistory") as? Bool ?? true
        debugMode = d.object(forKey: "debugMode") as? Bool ?? true

        listenHotKey = HotKeyCombo(encoded: d.string(forKey: "listenHotKey"))
            ?? HotKeyCombo(keyCode: UInt32(kVK_Space),
                           modifiers: UInt32(cmdKey | shiftKey))
        useFnKey = d.object(forKey: "useFnKey") as? Bool ?? true
        fnHoldThresholdMs = d.object(forKey: "fnHoldThresholdMs") as? Int ?? 350

        AppLog.shared.debugMode = debugMode
    }
}

/// How work is divided between the deterministic router and Jev.
enum RoutingMode: String, CaseIterable, Identifiable {
    /// Jev is consulted only for text the router could not claim. Fastest,
    /// and the reason simple commands never touch the network.
    case localFirst
    /// The router still executes, but Jev is asked in parallel and its answer
    /// recorded for comparison. Nothing Jev says is executed.
    case shadow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localFirst: return "Local first — Jev only for unmatched commands"
        case .shadow: return "Shadow — always ask Jev, execute the router"
        }
    }

    var detail: String {
        switch self {
        case .localFirst:
            return "\"open chrome\" never reaches the network. Jev is consulted only when the deterministic router finds no command."
        case .shadow:
            return "Every command is also sent to Jev so you can see its judgement next to the router's. Jev's answer is recorded but never executed, so this costs an API call per command."
        }
    }
}

enum STTProviderKind: String, CaseIterable, Identifiable {
    case sarvam
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .sarvam: return "Sarvam AI (streaming WebSocket)"
        }
    }
}

enum SearchEngine: String, CaseIterable, Identifiable {
    case google, duckduckgo, bing
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .bing: return "Bing"
        }
    }

    func url(for query: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        switch self {
        case .google:
            components.host = "www.google.com"
            components.path = "/search"
        case .duckduckgo:
            components.host = "duckduckgo.com"
            components.path = "/"
        case .bing:
            components.host = "www.bing.com"
            components.path = "/search"
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url
    }
}

/// A Carbon hot-key combination (key code + modifier mask).
struct HotKeyCombo: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    var encoded: String { "\(keyCode):\(modifiers)" }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(encoded: String?) {
        guard let encoded else { return nil }
        let parts = encoded.split(separator: ":")
        guard parts.count == 2,
              let k = UInt32(parts[0]), let m = UInt32(parts[1]) else { return nil }
        self.keyCode = k
        self.modifiers = m
    }

    var displayString: String {
        var out = ""
        if modifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { out += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { out += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { out += "⌘" }
        out += HotKeyCombo.keyName(keyCode)
        return out
    }

    static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Space: return "Space"
        case kVK_Escape: return "Esc"
        case kVK_Return: return "Return"
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_Z: return "Z"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        default: return "Key \(code)"
        }
    }
}
