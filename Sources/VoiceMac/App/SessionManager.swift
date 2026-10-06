import AppKit
import Foundation

enum SessionState: Sendable, Equatable {
    case idle
    case starting
    /// Mic live, nothing said yet.
    case listening
    /// Speech detected, transcripts arriving.
    case transcribing
    /// A decision is in flight.
    case understanding
    /// At least one action is running — the mic is still live.
    case executing
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .starting: return "Starting…"
        case .listening: return "Listening"
        case .transcribing: return "Transcribing"
        case .understanding: return "Understanding"
        case .executing: return "Executing"
        case .failed(let message): return message
        }
    }

    /// True whenever the microphone should be running.
    var isActive: Bool {
        switch self {
        case .idle, .failed: return false
        default: return true
        }
    }
}

enum SessionEvent: Sendable {
    case state(SessionState)
    case level(Float)
    case transcript(stable: String, full: String, isFinal: Bool)
    case action(id: UUID, summary: String, status: ActionStatus)
    /// A decision-engine call, including ones that chose nothing.
    case jev(JevConsultation)
    case needsConfirmation(id: UUID, summary: String)
    case message(String)
    case failure(String)
    case latency(LatencySnapshot)
}

/// Everything needed for one listening session, resolved up front on the main
/// actor so no pipeline component ever reads `Settings` or the Keychain.
struct SessionConfiguration: Sendable {
    var stt: STTConfiguration
    var sarvamAPIKey: String
    var jevAPIKey: String?
    var jevEnabled: Bool
    var jevModel: String
    var jevBaseURL: String
    var llmModel: String
    var speculativeExecution: Bool
    var stabilityWindow: Int
    var searchEngine: SearchEngine
    var keepHistory: Bool
    var routingMode: RoutingMode
}

/// The pipeline state machine.
///
/// The components below run as independent concurrent tasks, not as a
/// sequential `record -> transcribe -> understand -> execute` chain. Audio
/// forwarding, transcript handling, and action execution all proceed at the
/// same time — which is the only way Chrome can launch while the user is still
/// talking.
actor SessionManager {
    private let audio = AudioCapture()
    private let transcripts: TranscriptManager
    private let registry = ApplicationRegistry()
    private let accessibility = AccessibilityManager()
    private let latency = LatencyTracker()

    private let executor: MacOSActionExecutor
    private let scheduler: ActionScheduler
    private let planner: ActionPlanner

    private var stt: SarvamStreamingSTT?
    private var audioPump: Task<Void, Never>?
    private var transcriptPump: Task<Void, Never>?
    private var schedulerPump: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?
    private var historyBackstop: Task<Void, Never>?
    private var pendingHistoryOutcome: String?

    private var state: SessionState = .idle
    private var vad = VoiceActivityDetector()
    private var sentFirstChunk = false
    private var runningActions = 0

    /// Accumulates this session's history entry. Nil when history is off.
    private var recorder: CommandRecordBuilder?

    private let continuation: AsyncStream<SessionEvent>.Continuation
    let events: AsyncStream<SessionEvent>

    init() {
        let transcripts = TranscriptManager()
        let executor = MacOSActionExecutor(registry: registry,
                                           accessibility: accessibility,
                                           searchEngine: .google)
        let latency = self.latency
        let scheduler = ActionScheduler(executor: executor, latency: latency)

        self.transcripts = transcripts
        self.executor = executor
        self.scheduler = scheduler
        self.planner = ActionPlanner(registry: registry,
                                      accessibility: accessibility,
                                      scheduler: scheduler,
                                      latency: latency)

        let (stream, cont) = AsyncStream<SessionEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = cont
    }

    /// Indexes installed applications at launch so the first "open <app>" does
    /// not pay for a filesystem scan.
    func warmUp() async {
        startSchedulerPump()
        await registry.refresh()
    }

    func currentState() -> SessionState { state }

    func latencyReport() async -> String { await latency.report() }

    func actionSnapshot() async -> [(request: ActionRequest, status: ActionStatus)] {
        await scheduler.snapshot()
    }

    // MARK: Start

    func start(configuration: SessionConfiguration) async {
        guard !state.isActive else {
            log(.app, "session already active")
            return
        }

        transition(.starting)
        await latency.beginSession()

        // Fresh per-session state; completed actions from earlier are history.
        await transcripts.reset()
        await transcripts.configure(stabilityWindow: configuration.stabilityWindow)
        await planner.reset()
        await scheduler.reset()
        await executor.resetSession()
        await executor.updateSearchEngine(configuration.searchEngine)
        vad.reset()
        sentFirstChunk = false
        runningActions = 0
        recorder = configuration.keepHistory ? CommandRecordBuilder() : nil

        let decisionProvider: DecisionProvider? = {
            guard configuration.jevEnabled,
                  let key = configuration.jevAPIKey, !key.isEmpty else { return nil }
            return JevDecisionProvider(apiKey: key,
                                        model: configuration.jevModel,
                                        baseURL: configuration.jevBaseURL)
        }()

        let extractor: ParameterExtractor? = configuration.sarvamAPIKey.isEmpty
            ? nil
            : SarvamParameterExtractor(apiKey: configuration.sarvamAPIKey,
                                        model: configuration.llmModel)

        await planner.configure(
            decisionProvider: decisionProvider,
            extractor: extractor,
            speculativeExecution: configuration.speculativeExecution,
            routingMode: configuration.routingMode,
            onConsultation: { [weak self] consultation in
                Task { await self?.recordConsultation(consultation) }
            }
        )

        if decisionProvider == nil {
            log(.jev, "disabled or no API key — deterministic commands only")
        }

        // Speech-to-text first: the socket handshake is the slowest part of
        // startup, so it overlaps with starting the audio engine.
        var sttConfiguration = configuration.stt
        if sttConfiguration.prompt == nil {
            sttConfiguration.prompt = await registry.sttPromptBias()
        }

        let provider = SarvamStreamingSTT(configuration: sttConfiguration)
        stt = provider

        do {
            try await provider.start()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            log(.stt, "start failed: \(message)")
            transition(.failed(message))
            emit(.failure(message))
            await teardown()
            return
        }

        startTranscriptPump(provider)
        // The scheduler pump is started once in `warmUp`, not per session.
        startSchedulerPump()

        let chunks: AsyncStream<AudioChunk>
        do {
            chunks = try audio.start()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            log(.audio, "start failed: \(message)")
            transition(.failed(message))
            emit(.failure(message))
            await teardown()
            return
        }

        await latency.mark(.micStart)
        startAudioPump(chunks, provider: provider)
        transition(.listening)
    }

    // MARK: Pumps

    private func startAudioPump(_ chunks: AsyncStream<AudioChunk>,
                                provider: SarvamStreamingSTT) {
        audioPump = Task { [weak self] in
            for await chunk in chunks {
                guard let self, !Task.isCancelled else { return }
                await self.forward(chunk, to: provider)
            }
        }
    }

    private func forward(_ chunk: AudioChunk, to provider: SarvamStreamingSTT) async {
        if !sentFirstChunk {
            sentFirstChunk = true
            await latency.mark(.firstAudioSent)
        }

        try? await provider.sendAudio(chunk.pcm)

        if vad.consume(rms: chunk.rms), vad.isSpeaking {
            log(.audio, "local VAD: speech")
        }
        emit(.level(min(chunk.rms * 6, 1.0)))
    }

    private func startTranscriptPump(_ provider: SarvamStreamingSTT) {
        transcriptPump = Task { [weak self] in
            for await event in provider.transcriptStream {
                guard let self, !Task.isCancelled else { return }
                await self.handle(event)
            }
        }
    }

    /// Starts the scheduler event pump exactly once for the lifetime of this
    /// manager.
    ///
    /// `AsyncStream` supports a single iteration. The scheduler is long-lived,
    /// so re-subscribing per session silently stopped delivering action events
    /// after the first command of a launch — history recorded "no action" for
    /// commands that had plainly run.
    private func startSchedulerPump() {
        guard schedulerPump == nil else { return }
        schedulerPump = Task { [weak self] in
            guard let self else { return }
            for await event in self.scheduler.events {
                await self.handle(schedulerEvent: event)
            }
        }
    }

    // MARK: Transcript handling

    private func handle(_ event: TranscriptEvent) async {
        switch event {
        case .connected:
            await latency.mark(.sttConnected)

        case .speechStarted:
            if state == .listening { transition(.transcribing) }

        case .speechEnded:
            // End-of-turn. Promote whatever is pending and wrap the session up,
            // but let already-queued actions finish.
            if let update = await transcripts.promoteInterimToFinal() {
                await apply(update)
            }
            scheduleAutoStop()

        case .interim(let text):
            await latency.mark(.firstSttInterim)
            if state == .listening { transition(.transcribing) }
            let update = await transcripts.ingest(interim: text)
            await apply(update)

        case .final(let text):
            await latency.mark(.finalTranscript)
            let update = await transcripts.ingest(final: text)
            await apply(update)
            scheduleAutoStop()

        case .failed(let error):
            let message = error.errorDescription ?? "Speech recognition failed"
            emit(.failure(message))
            if error.isFatal {
                transition(.failed(message))
                await teardown()
            }

        case .closed:
            break
        }
    }

    private func apply(_ update: TranscriptUpdate) async {
        switch update {
        case .interimChanged(let full):
            let state = await transcripts.current()
            emit(.transcript(stable: state.stablePrefix, full: full, isFinal: false))

        case .stablePrefixGrew(let stable, let full):
            await latency.mark(.stablePrefixDetected)
            emit(.transcript(stable: stable, full: full, isFinal: false))
            // This is the mid-sentence execution path.
            await planner.process(text: stable, isFinal: false)

        case .stablePrefixRevised(let old, let stable, let full):
            log(.transcript, "revision — already-executed safe actions stand")
            _ = old
            emit(.transcript(stable: stable, full: full, isFinal: false))
            await planner.process(text: stable, isFinal: false)

        case .finalized(let full):
            emit(.transcript(stable: full, full: full, isFinal: true))
            await planner.process(text: full, isFinal: true)
            let snapshot = await latency.current()
            emit(.latency(snapshot))
        }
    }

    // MARK: Scheduler handling

    private func handle(schedulerEvent event: SchedulerEvent) async {
        switch event {
        case .submitted(let request):
            recorder?.noteSubmitted(request)

        case .result(let id, let success, let message, let durationMs):
            recorder?.noteResult(id, success: success, message: message,
                                 durationMs: durationMs)

        case .statusChanged(let id, let summary, let status):
            recorder?.noteStatus(id, status)
            switch status {
            case .running:
                runningActions += 1
                if state.isActive { transition(.executing) }
            case .completed, .failed, .cancelled:
                runningActions = max(0, runningActions - 1)
                // Executing never blocks listening: once nothing is running we
                // go straight back to listening if the mic is still live.
                if runningActions == 0, state == .executing {
                    transition(audio.running ? .transcribing : .idle)
                }
                await flushHistoryIfSettled()
            default:
                break
            }
            emit(.action(id: id, summary: summary, status: status))

        case .needsConfirmation(let id, let summary):
            emit(.needsConfirmation(id: id, summary: summary))
            emit(.message("Confirm: \(summary)"))

        case .message(let text):
            emit(.message(text))

        case .failure(let text):
            emit(.failure(text))
        }
    }

    private func recordConsultation(_ consultation: JevConsultation) {
        recorder?.noteConsultation(consultation)
        emit(.jev(consultation))
    }

    // MARK: Confirmation

    func confirm(_ id: UUID) async { await scheduler.confirm(id) }
    func reject(_ id: UUID) async { await scheduler.reject(id) }

    // MARK: Stop and cancel

    /// Graceful end of input. Audio stops; queued actions are left to finish.
    func finishListening() async {
        guard state.isActive else { return }
        log(.app, "finishing input")

        audio.stop()
        audioPump?.cancel()
        audioPump = nil

        if let stt { await stt.finish() }
        self.stt = nil

        // Anything still waiting on "the rest of the sentence" can go now.
        await scheduler.markTranscriptFinal()

        let snapshot = await latency.current()
        emit(.latency(snapshot))
        await latency.endSession()

        // The record is written once the actions this command queued have
        // settled, so it captures outcomes rather than just intentions.
        pendingHistoryOutcome = "completed"
        await flushHistoryIfSettled()
        startHistoryBackstop()

        if runningActions == 0 {
            transition(.idle)
        }
    }

    /// Writes history once nothing is still running.
    private func flushHistoryIfSettled() async {
        guard let outcome = pendingHistoryOutcome, runningActions == 0 else { return }
        pendingHistoryOutcome = nil
        historyBackstop?.cancel()
        historyBackstop = nil
        await flushHistory(outcome: outcome)
    }

    /// An action parked on confirmation may never settle; write the record
    /// anyway rather than losing the command entirely.
    private func startHistoryBackstop() {
        historyBackstop?.cancel()
        historyBackstop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled else { return }
            await self.forceFlushHistory()
        }
    }

    private func forceFlushHistory() async {
        guard let outcome = pendingHistoryOutcome else { return }
        pendingHistoryOutcome = nil
        await flushHistory(outcome: outcome == "completed" ? "incomplete" : outcome)
    }

    /// Hard cancel. Stops the stream, drops pending actions, clears transcript.
    /// Completed actions are never rolled back.
    func cancel() async {
        guard state.isActive else { return }
        log(.app, "cancelled by user")

        await scheduler.cancelAll()
        await teardown()
        pendingHistoryOutcome = "cancelled"
        runningActions = 0
        await flushHistoryIfSettled()
        await transcripts.reset()
        await planner.reset()
        emit(.transcript(stable: "", full: "", isFinal: false))
        emit(.message("Cancelled"))
        transition(.idle)
    }

    private func scheduleAutoStop() {
        autoStopTask?.cancel()
        autoStopTask = Task { [weak self] in
            // Short grace period so a trailing final transcript still lands.
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            await self.finishListening()
        }
    }

    private func teardown() async {
        autoStopTask?.cancel(); autoStopTask = nil
        historyBackstop?.cancel(); historyBackstop = nil
        audioPump?.cancel(); audioPump = nil
        transcriptPump?.cancel(); transcriptPump = nil
        // Deliberately NOT cancelling schedulerPump: it is per-manager, not
        // per-session, and its AsyncStream cannot be iterated a second time.

        audio.stop()
        if let stt { await stt.stop() }
        stt = nil
        await latency.endSession()
        runningActions = 0
    }

    // MARK: Events

    private func transition(_ next: SessionState) {
        guard state != next else { return }
        log(.app, "state \(state.label) -> \(next.label)")
        state = next
        emit(.state(next))
    }

    private func emit(_ event: SessionEvent) {
        if case .transcript(let stable, let full, let isFinal) = event {
            recorder?.noteTranscript(stable: stable, full: full, isFinal: isFinal)
        }
        if case .latency(let snapshot) = event {
            recorder?.noteLatency(snapshot)
        }
        continuation.yield(event)
    }

    /// Writes this session's history entry, if there is anything worth keeping.
    private func flushHistory(outcome: String) async {
        guard var builder = recorder, builder.hasContent else {
            recorder = nil
            return
        }
        recorder = nil

        let snapshot = await latency.current()
        builder.noteLatency(snapshot)
        let record = builder.finish(outcome: outcome)
        await CommandHistory.shared.append(record)
        log(.app, "history: recorded \(record.actions.count) action(s), outcome \(outcome)")
    }
}
