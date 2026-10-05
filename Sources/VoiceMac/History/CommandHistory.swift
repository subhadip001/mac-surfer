import Foundation

/// One action as it actually ran.
struct RecordedAction: Codable, Identifiable, Sendable {
    let id: UUID
    let type: String
    let parameters: [String: String]
    let risk: String
    /// `localRouter`, `jev`, `llm`, or `manual` — which path produced it.
    let origin: String
    let dependsOn: [UUID]
    var status: String
    var message: String?
    var durationMs: Int?
    /// Milliseconds from the start of the command to this action starting.
    var startedAtMs: Double?

    var summary: String {
        let detail = parameters["app"] ?? parameters["query"] ?? parameters["url"]
            ?? parameters["target"] ?? parameters["command"] ?? parameters["text"] ?? ""
        return detail.isEmpty ? type : "\(type): \(detail)"
    }
}

/// Everything that happened for one spoken command.
struct CommandRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    /// The transcript as finally understood.
    var transcript: String
    /// What was stable at the moment the first action fired — this is the
    /// evidence that execution really did begin mid-sentence.
    var stablePrefixAtFirstAction: String?
    var actions: [RecordedAction]
    var timeToFirstTranscriptMs: Double?
    var timeToFirstActionMs: Double?
    var totalMs: Double?
    var outcome: String
    /// True when any action ran before the transcript was final.
    var executedMidSentence: Bool
    /// Every decision-engine call made for this command, including refusals.
    /// Empty means Jev was never asked — usually because the local router
    /// handled everything.
    var jevConsultations: [JevConsultation] = []

    var succeededCount: Int { actions.filter { $0.status == "completed" }.count }
    var failedCount: Int { actions.filter { $0.status.hasPrefix("failed") }.count }
}

/// Append-only local history of spoken commands.
///
/// Stored as JSON Lines in Application Support. One line per command means an
/// append is a single write with no read-modify-cycle, so a crash mid-session
/// cannot corrupt earlier entries.
///
/// Nothing leaves the machine. The file does contain what you said, so it is
/// plain text you can read, delete, or disable entirely in Settings.
actor CommandHistory {
    static let shared = CommandHistory()

    /// Older entries are dropped beyond this.
    private let maximumRecords = 500
    private var appendsSinceCompaction = 0

    nonisolated static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask)[0]
        return base.appendingPathComponent("VoiceMac", isDirectory: true)
    }

    nonisolated static var fileURL: URL {
        directoryURL.appendingPathComponent("history.jsonl")
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: Writing

    func append(_ record: CommandRecord) {
        do {
            try FileManager.default.createDirectory(at: Self.directoryURL,
                                                     withIntermediateDirectories: true)

            var line = try encoder.encode(record)
            line.append(0x0A)   // newline

            let url = Self.fileURL
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
                // The file records what you said; keep it to this user.
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                        ofItemAtPath: url.path)
            }

            appendsSinceCompaction += 1
            if appendsSinceCompaction >= 25 {
                appendsSinceCompaction = 0
                compact()
            }
        } catch {
            log(.app, "could not write command history: \(error.localizedDescription)")
        }
    }

    // MARK: Reading

    /// Newest first.
    func load(limit: Int = 200) -> [CommandRecord] {
        guard let contents = try? String(contentsOf: Self.fileURL, encoding: .utf8) else {
            return []
        }

        var records: [CommandRecord] = []
        // Reverse first so `limit` keeps the newest, not the oldest.
        for line in contents.split(separator: "\n").reversed() {
            guard records.count < limit else { break }
            guard let data = line.data(using: .utf8),
                  let record = try? decoder.decode(CommandRecord.self, from: data) else {
                continue   // skip a torn or outdated line rather than failing
            }
            records.append(record)
        }
        return records
    }

    func clear() {
        try? FileManager.default.removeItem(at: Self.fileURL)
        appendsSinceCompaction = 0
        log(.app, "command history cleared")
    }

    func fileSizeBytes() -> Int {
        let attributes = try? FileManager.default
            .attributesOfItem(atPath: Self.fileURL.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Rewrites the file keeping only the most recent `maximumRecords` lines.
    private func compact() {
        guard let contents = try? String(contentsOf: Self.fileURL, encoding: .utf8) else { return }
        let lines = contents.split(separator: "\n")
        guard lines.count > maximumRecords else { return }

        let kept = lines.suffix(maximumRecords).joined(separator: "\n") + "\n"
        try? kept.write(to: Self.fileURL, atomically: true, encoding: .utf8)
        log(.app, "command history compacted to \(maximumRecords) entries")
    }
}

/// Accumulates a `CommandRecord` while a session is in flight.
struct CommandRecordBuilder {
    private var record: CommandRecord
    private var actionOrder: [UUID] = []
    private var indexByID: [UUID: Int] = [:]
    private var transcriptIsFinal = false

    init(startedAt: Date = Date()) {
        record = CommandRecord(id: UUID(),
                               startedAt: startedAt,
                               endedAt: nil,
                               transcript: "",
                               stablePrefixAtFirstAction: nil,
                               actions: [],
                               timeToFirstTranscriptMs: nil,
                               timeToFirstActionMs: nil,
                               totalMs: nil,
                               outcome: "no action",
                               executedMidSentence: false,
                               jevConsultations: [])
    }

    mutating func noteConsultation(_ consultation: JevConsultation) {
        record.jevConsultations.append(consultation)
    }

    var hasContent: Bool {
        !record.transcript.isEmpty || !record.actions.isEmpty
            || !record.jevConsultations.isEmpty
    }
    private(set) var latestStablePrefix = ""

    mutating func noteTranscript(stable: String, full: String, isFinal: Bool) {
        latestStablePrefix = stable
        record.transcript = full.isEmpty ? stable : full
        if isFinal { transcriptIsFinal = true }
    }

    mutating func noteSubmitted(_ request: ActionRequest) {
        guard indexByID[request.id] == nil else { return }
        indexByID[request.id] = record.actions.count
        actionOrder.append(request.id)
        record.actions.append(RecordedAction(
            id: request.id,
            type: request.type.rawValue,
            parameters: request.parameters,
            risk: request.riskLevel.label,
            origin: request.origin.rawValue,
            dependsOn: request.dependencies,
            status: "pending",
            message: nil,
            durationMs: nil,
            startedAtMs: nil
        ))
    }

    mutating func noteStatus(_ id: UUID, _ status: ActionStatus) {
        guard let index = indexByID[id] else { return }
        record.actions[index].status = Self.describe(status)

        if case .running = status {
            record.actions[index].startedAtMs =
                Date().timeIntervalSince(record.startedAt) * 1000
            // The whole point of the design: did anything run before the user
            // finished talking?
            if !transcriptIsFinal {
                record.executedMidSentence = true
                if record.stablePrefixAtFirstAction == nil {
                    record.stablePrefixAtFirstAction = latestStablePrefix
                }
            }
        }
    }

    mutating func noteResult(_ id: UUID, success: Bool, message: String, durationMs: Int) {
        guard let index = indexByID[id] else { return }
        record.actions[index].message = message
        record.actions[index].durationMs = durationMs
    }

    mutating func noteLatency(_ snapshot: LatencySnapshot) {
        record.timeToFirstTranscriptMs = snapshot.timeToFirstTranscript
        record.timeToFirstActionMs = snapshot.timeToFirstAction
        record.totalMs = snapshot.totalCommandLatency
    }

    mutating func finish(outcome: String) -> CommandRecord {
        record.endedAt = Date()
        record.outcome = outcome
        return record
    }

    private static func describe(_ status: ActionStatus) -> String {
        switch status {
        case .pending: return "pending"
        case .waiting(let reason): return "waiting: \(reason)"
        case .awaitingConfirmation: return "awaiting confirmation"
        case .running: return "running"
        case .completed: return "completed"
        case .failed(let reason): return "failed: \(reason)"
        case .cancelled: return "cancelled"
        }
    }
}
