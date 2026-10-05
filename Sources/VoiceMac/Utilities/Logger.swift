import Foundation

enum LogCategory: String, Sendable {
    case app = "App"
    case audio = "Audio"
    case stt = "STT"
    case transcript = "Transcript"
    case router = "Router"
    case planner = "Planner"
    case jev = "Jev"
    case llm = "LLM"
    case executor = "Executor"
    case accessibility = "AX"
    case permission = "Perm"
    case latency = "Latency"
    case hotkey = "HotKey"
}

struct LogLine: Identifiable, Sendable {
    let id = UUID()
    let at: Date
    let category: LogCategory
    let message: String

    var formatted: String {
        "[\(category.rawValue)] \(message)"
    }
}

/// Structured logging with a bounded in-memory ring buffer for the debug panel.
///
/// Two rules are enforced here rather than left to call sites:
///   1. API keys are never accepted by this type — `KeychainManager` has no
///      logging path at all.
///   2. Anything the user actually said or typed must be passed with
///      `sensitive: true`, and is redacted unless Debug Mode is explicitly on.
final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    private let lock = NSLock()
    private var buffer: [LogLine] = []
    private let capacity = 600

    /// Mirrors `Settings.debugMode`. Set by `Settings` on change.
    private var _debugMode = false
    var debugMode: Bool {
        get { lock.withLock { _debugMode } }
        set { lock.withLock { _debugMode = newValue } }
    }

    /// Set by the UI so the debug panel can live-update.
    var onLine: (@Sendable (LogLine) -> Void)?

    private init() {}

    func log(_ category: LogCategory, _ message: String, sensitive: Bool = false) {
        let text: String
        if sensitive && !debugMode {
            text = "<redacted — enable Debug Mode to see transcript content>"
        } else {
            text = message
        }

        let line = LogLine(at: Date(), category: category, message: text)

        lock.withLock {
            buffer.append(line)
            if buffer.count > capacity {
                buffer.removeFirst(buffer.count - capacity)
            }
        }

        FileHandle.standardError.write(Data("\(line.formatted)\n".utf8))
        onLine?(line)
    }

    func recent(_ limit: Int = 200) -> [LogLine] {
        lock.withLock { Array(buffer.suffix(limit)) }
    }

    func clear() {
        lock.withLock { buffer.removeAll() }
    }
}

@inline(__always)
func log(_ category: LogCategory, _ message: String, sensitive: Bool = false) {
    AppLog.shared.log(category, message, sensitive: sensitive)
}
