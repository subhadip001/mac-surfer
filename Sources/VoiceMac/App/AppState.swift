import AVFoundation
import AppKit
import Combine
import Foundation

struct ActionRow: Identifiable, Equatable {
    let id: UUID
    var summary: String
    var status: ActionStatus

    var statusLabel: String {
        switch status {
        case .pending: return "queued"
        case .waiting(let reason): return reason
        case .awaitingConfirmation: return "needs confirmation"
        case .running: return "running"
        case .completed: return "done"
        case .failed(let reason): return "failed — \(reason)"
        case .cancelled: return "cancelled"
        }
    }
}

/// UI-facing state. Owns the session and translates its event stream into
/// published properties for SwiftUI.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var sessionState: SessionState = .idle
    @Published private(set) var stableText = ""
    @Published private(set) var fullText = ""
    @Published private(set) var transcriptIsFinal = false
    @Published private(set) var level: Float = 0
    @Published private(set) var actions: [ActionRow] = []
    @Published private(set) var lastMessage = ""
    @Published private(set) var lastError = ""
    @Published private(set) var pendingConfirmation: (id: UUID, summary: String)?
    @Published private(set) var latency = LatencySnapshot()
    @Published private(set) var logLines: [LogLine] = []
    /// Decision-engine calls for the current command.
    @Published private(set) var jevConsultations: [JevConsultation] = []
    @Published private(set) var lastJevConsultation: JevConsultation?

    @Published private(set) var microphoneAuthorized = false
    @Published private(set) var accessibilityTrusted = false

    let settings = Settings.shared
    private let session = SessionManager()
    private var eventPump: Task<Void, Never>?
    private var permissionTimer: Timer?

    var isListening: Bool { sessionState.isActive }

    var hasRequiredKeys: Bool { KeychainManager.has(.sarvamAPIKey) }

    init() {
        refreshPermissions()

        eventPump = Task { [weak self] in
            guard let self else { return }
            for await event in self.session.events {
                self.apply(event)
            }
        }

        AppLog.shared.onLine = { [weak self] line in
            Task { @MainActor in
                guard let self else { return }
                self.logLines.append(line)
                if self.logLines.count > 400 {
                    self.logLines.removeFirst(self.logLines.count - 400)
                }
            }
        }

        logLines = AppLog.shared.recent()

        // Accessibility trust can be granted while we are running, and macOS
        // gives no notification for it.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }

        Task { await session.warmUp() }
    }

    // MARK: Permissions

    func refreshPermissions() {
        microphoneAuthorized = AudioCapture.microphoneAuthorization() == .authorized
        accessibilityTrusted = AccessibilityManager.isTrusted
    }

    func requestMicrophoneAccess() {
        Task {
            let granted = await AudioCapture.requestMicrophoneAccess()
            refreshPermissions()
            if !granted {
                lastError = "Microphone access denied. Enable it in System Settings › Privacy & Security › Microphone."
                openSystemSettings(pane: "Privacy_Microphone")
            }
        }
    }

    func requestAccessibilityAccess() {
        AccessibilityManager.requestTrust()
        openSystemSettings(pane: "Privacy_Accessibility")
    }

    func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Control

    func toggleListening() {
        if sessionState.isActive {
            finishListening()
        } else {
            startListening()
        }
    }

    /// Stop taking input but let queued actions finish. Used by push-to-talk
    /// release, where the key going up means "I've stopped speaking".
    func finishListening() {
        guard sessionState.isActive else { return }
        Task { await session.finishListening() }
    }

    func startListening() {
        guard !sessionState.isActive else { return }

        guard microphoneAuthorized else {
            lastError = "Microphone permission required."
            requestMicrophoneAccess()
            return
        }
        guard hasRequiredKeys else {
            lastError = "Add your Sarvam API key in Settings to enable speech recognition."
            return
        }

        actions.removeAll()
        jevConsultations.removeAll()
        pendingConfirmation = nil
        lastError = ""
        lastMessage = ""
        stableText = ""
        fullText = ""
        transcriptIsFinal = false

        let configuration = buildConfiguration()
        Task { await session.start(configuration: configuration) }
    }

    func cancel() {
        Task { await session.cancel() }
    }

    func confirmPending() {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        Task { await session.confirm(pending.id) }
    }

    func rejectPending() {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        Task { await session.reject(pending.id) }
    }

    private func buildConfiguration() -> SessionConfiguration {
        let sarvamKey = KeychainManager.get(.sarvamAPIKey) ?? ""
        return SessionConfiguration(
            stt: STTConfiguration(apiKey: sarvamKey,
                                  language: settings.language,
                                  model: settings.sttModel,
                                  streamType: settings.streamType,
                                  silenceDurationMs: settings.silenceDurationMs,
                                  sampleRate: Int(AudioCapture.targetSampleRate),
                                  prompt: nil),
            sarvamAPIKey: sarvamKey,
            jevAPIKey: KeychainManager.get(.jevAPIKey),
            jevEnabled: settings.jevEnabled,
            jevModel: settings.jevModel,
            jevBaseURL: settings.jevBaseURL,
            llmModel: settings.llmModel,
            speculativeExecution: settings.speculativeExecution,
            stabilityWindow: settings.stabilityWindow,
            searchEngine: settings.searchEngine,
            keepHistory: settings.keepHistory,
            routingMode: settings.routingMode
        )
    }

    // MARK: History

    @Published private(set) var history: [CommandRecord] = []
    @Published private(set) var historySizeBytes = 0

    /// Set by `AppDelegate`, which owns the windows. A direct callback rather
    /// than a responder-chain selector, so the button cannot silently do
    /// nothing if the chain does not reach the delegate.
    var presentHistory: (() -> Void)?

    func reloadHistory() {
        Task {
            let records = await CommandHistory.shared.load()
            let size = await CommandHistory.shared.fileSizeBytes()
            self.history = records
            self.historySizeBytes = size
        }
    }

    func clearHistory() {
        Task {
            await CommandHistory.shared.clear()
            self.history = []
            self.historySizeBytes = 0
        }
    }

    func revealHistoryInFinder() {
        let url = CommandHistory.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(CommandHistory.directoryURL)
        }
    }

    // MARK: Event application

    private func apply(_ event: SessionEvent) {
        switch event {
        case .state(let next):
            sessionState = next
            if case .failed(let message) = next { lastError = message }

        case .level(let value):
            level = value

        case .transcript(let stable, let full, let isFinal):
            stableText = stable
            fullText = full
            transcriptIsFinal = isFinal

        case .jev(let consultation):
            lastJevConsultation = consultation
            jevConsultations.append(consultation)

        case .action(let id, let summary, let status):
            if let index = actions.firstIndex(where: { $0.id == id }) {
                actions[index].status = status
                actions[index].summary = summary
            } else {
                actions.append(ActionRow(id: id, summary: summary, status: status))
            }

        case .needsConfirmation(let id, let summary):
            pendingConfirmation = (id, summary)

        case .message(let text):
            lastMessage = text

        case .failure(let text):
            lastError = text

        case .latency(let snapshot):
            latency = snapshot
        }
    }

    func clearLogs() {
        AppLog.shared.clear()
        logLines.removeAll()
    }

    func latencyReport() async -> String {
        await session.latencyReport()
    }
}
