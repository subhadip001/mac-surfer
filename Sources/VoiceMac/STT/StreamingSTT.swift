import Foundation

/// Events a streaming STT provider emits as the user speaks.
enum TranscriptEvent: Sendable {
    case connected
    /// Provider-side VAD detected the start of speech.
    case speechStarted
    /// Provider-side VAD detected end-of-turn.
    case speechEnded
    /// A revisable partial transcript for the current utterance.
    case interim(String)
    /// A committed transcript for a completed utterance.
    case final(String)
    case failed(STTError)
    case closed
}

enum STTError: LocalizedError, Sendable {
    case missingAPIKey
    case badURL
    case connectionFailed(String)
    case transportFailed(String)
    case remote(code: String, message: String, fatal: Bool)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Speech recognition unavailable — no Sarvam API key set. Add one in Settings."
        case .badURL:
            return "Speech recognition unavailable — invalid provider URL in Settings."
        case .connectionFailed(let detail):
            return "Speech recognition unavailable — could not connect (\(detail))."
        case .transportFailed(let detail):
            return "Speech recognition interrupted — \(detail)."
        case .remote(let code, let message, _):
            return "Speech recognition error \(code): \(message)"
        }
    }

    var isFatal: Bool {
        switch self {
        case .missingAPIKey, .badURL, .connectionFailed: return true
        case .remote(_, _, let fatal): return fatal
        case .transportFailed: return true
        }
    }
}

/// Provider-agnostic streaming speech-to-text.
///
/// Implementations must deliver revisable interim transcripts — the whole
/// mid-sentence execution design depends on them. A provider that can only
/// return a transcript after the audio ends is not usable here.
protocol StreamingSTT: Sendable {
    var transcriptStream: AsyncStream<TranscriptEvent> { get }

    func start() async throws
    func sendAudio(_ data: Data) async throws
    /// Graceful end-of-input: flush and allow a last final transcript through.
    func finish() async
    /// Immediate teardown, used by cancellation.
    func stop() async
}

/// Static configuration for a session, resolved on the main actor before the
/// socket is opened so the STT actor never touches `Settings`.
struct STTConfiguration: Sendable {
    var apiKey: String
    var language: String
    var model: String
    var streamType: String
    var silenceDurationMs: Int
    var sampleRate: Int
    /// Terminology hint — we bias the model toward installed app names so
    /// "open obsidian" does not come back as "open a city in".
    var prompt: String?

    static let maxPromptCharacters = 800
}
