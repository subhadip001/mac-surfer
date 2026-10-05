import Foundation

enum SchedulerEvent: Sendable {
    /// Carries the full request so history can record what was actually
    /// planned — type, parameters, risk, origin, dependencies.
    case submitted(ActionRequest)
    case statusChanged(id: UUID, summary: String, status: ActionStatus)
    /// Outcome with timing, for history and the debug panel.
    case result(id: UUID, success: Bool, message: String, durationMs: Int)
    /// A destructive action is parked until the user approves it.
    case needsConfirmation(id: UUID, summary: String)
    /// User-facing outcome text for the overlay.
    case message(String)
    case failure(String)
}

/// Runs the action dependency graph.
///
/// Actions are submitted as they are discovered mid-sentence and execute as
/// soon as three things hold: their dependencies have completed, their
/// parameters have stopped changing, and the safety gate allows it at the
/// current transcript confidence. Everything else waits — nothing is dropped
/// and nothing runs twice.
actor ActionScheduler {
    private struct Node {
        var request: ActionRequest
        var status: ActionStatus
    }

    private var nodes: [UUID: Node] = [:]
    /// Submission order, so execution is deterministic for ready siblings.
    private var order: [UUID] = []
    private var inFlight: Set<UUID> = []
    private var dispatchedKeys: Set<String> = []

    /// Set when the provider has signalled end-of-turn. `caution` actions wait
    /// for this rather than risking a half-heard transcript.
    private var transcriptIsFinal = false

    private let executor: ActionExecutorProtocol
    private let latency: LatencyTracker
    private let actionTimeout: Duration = .seconds(12)

    private let continuation: AsyncStream<SchedulerEvent>.Continuation
    let events: AsyncStream<SchedulerEvent>

    init(executor: ActionExecutorProtocol, latency: LatencyTracker) {
        self.executor = executor
        self.latency = latency
        let (stream, cont) = AsyncStream<SchedulerEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = cont
    }

    // MARK: Submission

    /// Adds an action. Returns nil if an identical action was already dispatched.
    @discardableResult
    func submit(_ request: ActionRequest) -> UUID? {
        guard !dispatchedKeys.contains(request.dedupeKey) else {
            log(.planner, "skipping duplicate \(request.dedupeKey)")
            return nil
        }
        dispatchedKeys.insert(request.dedupeKey)

        nodes[request.id] = Node(request: request, status: .pending)
        order.append(request.id)
        log(.planner, "queued \(request.summary) [risk \(request.riskLevel.label), deps \(request.dependencies.count)]")
        emit(.submitted(request))

        Task { await tick() }
        return request.id
    }

    func markTranscriptFinal() {
        guard !transcriptIsFinal else { return }
        transcriptIsFinal = true
        Task { await tick() }
    }

    /// Updates a queued action whose text parameters have since stabilised.
    func updateParameters(_ id: UUID, parameters: [String: String], stable: Bool) {
        guard var node = nodes[id], !node.status.isTerminal, !inFlight.contains(id) else { return }
        node.request.parameters = parameters
        node.request.parametersAreStable = stable
        nodes[id] = node
        Task { await tick() }
    }

    // MARK: Confirmation

    func confirm(_ id: UUID) {
        guard var node = nodes[id], node.status == .awaitingConfirmation else { return }
        node.status = .pending
        // An explicit approval is what authorises a destructive action; the
        // risk level itself is never rewritten.
        nodes[id] = node
        log(.planner, "user confirmed \(node.request.summary)")
        Task { await tick() }
    }

    func reject(_ id: UUID) {
        guard var node = nodes[id] else { return }
        node.status = .cancelled
        nodes[id] = node
        emit(.statusChanged(id: id, summary: node.request.summary, status: .cancelled))
        emit(.message("Cancelled \(node.request.summary)"))
        cancelDependents(of: id, reason: "dependency was cancelled")
    }

    var pendingConfirmations: [(id: UUID, summary: String)] {
        order.compactMap { id in
            guard let node = nodes[id], node.status == .awaitingConfirmation else { return nil }
            return (id, node.request.summary)
        }
    }

    // MARK: Cancellation

    /// Immediate cancellation. Completed actions are left alone — never rolled back.
    func cancelAll() {
        for id in order {
            guard var node = nodes[id], !node.status.isTerminal else { continue }
            node.status = .cancelled
            nodes[id] = node
            emit(.statusChanged(id: id, summary: node.request.summary, status: .cancelled))
        }
        inFlight.removeAll()
    }

    func reset() {
        nodes.removeAll()
        order.removeAll()
        inFlight.removeAll()
        dispatchedKeys.removeAll()
        transcriptIsFinal = false
    }

    func snapshot() -> [(request: ActionRequest, status: ActionStatus)] {
        order.compactMap { nodes[$0] }.map { ($0.request, $0.status) }
    }

    // MARK: Scheduling

    private func tick() async {
        for id in order {
            guard let node = nodes[id] else { continue }
            guard !node.status.isTerminal,
                  node.status != .awaitingConfirmation,
                  !inFlight.contains(id) else { continue }

            switch readiness(of: node) {
            case .ready:
                launch(id)
            case .needsConfirmation:
                setStatus(id, .awaitingConfirmation)
                emit(.needsConfirmation(id: id, summary: node.request.summary))
            case .wait(let reason):
                if case .waiting(let existing) = node.status, existing == reason { continue }
                setStatus(id, .waiting(reason))
            case .dead(let reason):
                setStatus(id, .cancelled)
                emit(.message("Skipped \(node.request.summary) — \(reason)"))
            }
        }
    }

    private enum Readiness {
        case ready
        case wait(String)
        case needsConfirmation
        case dead(String)
    }

    private func readiness(of node: Node) -> Readiness {
        // 1. Dependencies.
        for dependency in node.request.dependencies {
            guard let upstream = nodes[dependency] else { continue }
            switch upstream.status {
            case .completed: continue
            case .failed(let reason): return .dead("\(upstream.request.summary) failed: \(reason)")
            case .cancelled: return .dead("\(upstream.request.summary) was cancelled")
            default: return .wait("waiting for \(upstream.request.summary)")
            }
        }

        // 2. Parameter stability — never act on text that is still growing.
        if !node.request.parametersAreStable && !transcriptIsFinal {
            return .wait("waiting for the rest of the sentence")
        }

        // 3. Safety gate.
        switch node.request.riskLevel {
        case .safe:
            return .ready
        case .caution:
            // Reversible but state-changing: require a settled transcript.
            return transcriptIsFinal ? .ready : .wait("waiting for you to finish speaking")
        case .destructive:
            return .needsConfirmation
        }
    }

    private func launch(_ id: UUID) {
        guard let node = nodes[id] else { return }
        inFlight.insert(id)
        setStatus(id, .running)

        Task { [executor, latency, actionTimeout] in
            await latency.mark(.firstActionStart)
            let started = ContinuousClock.now

            var outcome: Result<String, Error>
            do {
                let message = try await withTimeout(actionTimeout) {
                    try await executor.execute(node.request)
                }
                outcome = .success(message)
            } catch {
                outcome = .failure(error)
            }

            let duration = (ContinuousClock.now - started)
            await self.finish(id, outcome: outcome, duration: duration)
        }
    }

    private func finish(_ id: UUID, outcome: Result<String, Error>, duration: Duration) async {
        inFlight.remove(id)
        guard let node = nodes[id] else { return }

        switch outcome {
        case .success(let message):
            setStatus(id, .completed)
            await latency.mark(.firstActionCompleted)
            log(.executor, "\(node.request.type.rawValue) completed in \(duration.milliseconds) ms — \(message)")
            emit(.result(id: id, success: true, message: message,
                         durationMs: duration.milliseconds))
            emit(.message(message))

        case .failure(let error):
            let reason = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            setStatus(id, .failed(reason))
            log(.executor, "\(node.request.type.rawValue) failed: \(reason)")
            emit(.result(id: id, success: false, message: reason,
                         durationMs: duration.milliseconds))
            emit(.failure(reason))
            cancelDependents(of: id, reason: reason)
        }

        await tick()
    }

    private func cancelDependents(of id: UUID, reason: String) {
        for other in order {
            guard var node = nodes[other],
                  !node.status.isTerminal,
                  node.request.dependencies.contains(id) else { continue }
            node.status = .cancelled
            nodes[other] = node
            emit(.statusChanged(id: other, summary: node.request.summary, status: .cancelled))
            emit(.message("Skipped \(node.request.summary) — \(reason)"))
        }
    }

    private func setStatus(_ id: UUID, _ status: ActionStatus) {
        guard var node = nodes[id] else { return }
        node.status = status
        nodes[id] = node
        emit(.statusChanged(id: id, summary: node.request.summary, status: status))
    }

    private func emit(_ event: SchedulerEvent) {
        continuation.yield(event)
    }
}

/// Runs `operation`, throwing if it outlives `duration`.
func withTimeout<T: Sendable>(_ duration: Duration,
                              operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw ActionError.executionFailed("timed out after \(duration.milliseconds) ms")
        }
        guard let result = try await group.next() else {
            throw ActionError.executionFailed("no result")
        }
        group.cancelAll()
        return result
    }
}
