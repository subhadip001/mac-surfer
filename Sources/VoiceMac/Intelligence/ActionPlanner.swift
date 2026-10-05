import AppKit
import Foundation

/// Turns transcript updates into a dependency graph of actions.
///
/// Called on every stable-prefix growth, so it must be cheap and idempotent:
/// it re-parses the whole prefix each time and relies on clause word offsets to
/// recognise what it has already dispatched.
///
/// Routing order is deliberate — the deterministic router runs first and Jev is
/// consulted only for what the router could not claim. "open chrome" never
/// reaches the network.
actor ActionPlanner {
    private let router = LocalCommandRouter()
    private let registry: ApplicationRegistry
    private let accessibility: AccessibilityManager
    private let scheduler: ActionScheduler
    private let latency: LatencyTracker

    private var decisionProvider: DecisionProvider?
    private var extractor: ParameterExtractor?
    private var speculativeExecution = true
    private var routingMode: RoutingMode = .localFirst

    /// Reports every decision-engine call so it can be shown and recorded.
    var onConsultation: (@Sendable (JevConsultation) -> Void)?

    /// Clause word offsets already turned into actions.
    private var dispatchedClauseStarts: Set<Int> = []
    /// Most recent app-targeting action, for dependency wiring.
    private var lastAppActionID: UUID?
    private var lastAppBundleID: String?
    private var executedSummaries: [String] = []

    // Jev debouncing.
    private var lastJevText = ""
    private var jevInFlight = false
    private var lastJevAt: ContinuousClock.Instant?
    private let minimumJevInterval: Duration = .milliseconds(250)

    init(registry: ApplicationRegistry,
         accessibility: AccessibilityManager,
         scheduler: ActionScheduler,
         latency: LatencyTracker) {
        self.registry = registry
        self.accessibility = accessibility
        self.scheduler = scheduler
        self.latency = latency
    }

    func configure(decisionProvider: DecisionProvider?,
                   extractor: ParameterExtractor?,
                   speculativeExecution: Bool,
                   routingMode: RoutingMode = .localFirst,
                   onConsultation: (@Sendable (JevConsultation) -> Void)? = nil) {
        self.decisionProvider = decisionProvider
        self.extractor = extractor
        self.speculativeExecution = speculativeExecution
        self.routingMode = routingMode
        self.onConsultation = onConsultation
    }

    func reset() {
        dispatchedClauseStarts.removeAll()
        lastAppActionID = nil
        lastAppBundleID = nil
        executedSummaries.removeAll()
        lastJevText = ""
        jevInFlight = false
        lastJevAt = nil
    }

    // MARK: Entry point

    /// `text` is the stable prefix while speaking, the full transcript when final.
    func process(text: String, isFinal: Bool) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isFinal { await scheduler.markTranscriptFinal() }

        let clauses = router.parse(trimmed)
        var dispatchedAny = false

        for clause in clauses {
            guard !dispatchedClauseStarts.contains(clause.startWordIndex) else { continue }

            // Free text that is still growing must wait. "search for the best
            // bengali rest..." would otherwise search for a truncated query.
            if clause.type.carriesFreeText && !clause.isBounded && !isFinal {
                continue
            }
            if !speculativeExecution && !isFinal { continue }

            if let id = await dispatch(clause, isFinal: isFinal) {
                dispatchedClauseStarts.insert(clause.startWordIndex)
                dispatchedAny = true
                _ = id
            }
        }

        if dispatchedAny {
            await latency.mark(.localIntentDetected)
            // In shadow mode we still ask Jev, purely so its judgement is
            // visible alongside the router's. Its answer is not executed.
            if routingMode == .shadow, isFinal {
                await considerJev(text: trimmed, isFinal: isFinal,
                                  reason: "shadow mode — comparing against the local router",
                                  dryRun: true)
            }
            return
        }

        // Nothing deterministic matched — this is what Jev is for.
        if clauses.isEmpty {
            await considerJev(text: trimmed, isFinal: isFinal,
                              reason: "local router matched nothing")
        } else if routingMode == .shadow, isFinal {
            await considerJev(text: trimmed, isFinal: isFinal,
                              reason: "shadow mode — router found clauses but dispatched none",
                              dryRun: true)
        }
    }

    // MARK: Local dispatch

    private func dispatch(_ clause: ParsedClause, isFinal: Bool) async -> UUID? {
        var parameters = clause.parameters

        // "open youtube" is a site, not an app — decide now, while we can
        // still cheaply consult the registry.
        if clause.type == .openApp, let fallback = parameters["urlFallback"] {
            if let spoken = parameters["app"], await registry.resolve(spoken) == nil {
                let request = ActionRequest(type: .openURL,
                                            parameters: ["url": fallback],
                                            dependencies: [],
                                            origin: .localRouter,
                                            sourceText: clause.text)
                return await submit(request, isAppClause: true, bundleID: nil)
            }
            parameters["urlFallback"] = nil
        }

        // "focus the search field" and "focus Chrome" are the same words. If
        // the object names an installed app it is an app switch; otherwise the
        // user meant a control inside the current window.
        if clause.type == .focusApp,
           let spoken = parameters["app"],
           await registry.resolve(spoken) == nil {
            let request = ActionRequest(type: .focusElement,
                                        parameters: ["target": spoken],
                                        dependencies: lastAppActionID.map { [$0] } ?? [],
                                        origin: .localRouter,
                                        sourceText: clause.text)
            log(.router, "\"\(spoken)\" is not an installed app — treating as an element", sensitive: true)
            return await submit(request, isAppClause: false, bundleID: nil)
        }

        var dependencies: [UUID] = []
        if clause.dependsOnPreviousAppClause, let upstream = lastAppActionID {
            dependencies.append(upstream)
            // Send the search into the app the user named, not the default browser.
            if let bundleID = lastAppBundleID {
                parameters["bundleID"] = bundleID
            }
        }

        let isAppClause = clause.type == .openApp
            || clause.type == .focusApp
            || clause.type == .openURL

        var resolvedBundleID: String?
        if isAppClause, let spoken = parameters["app"] {
            resolvedBundleID = await registry.resolve(spoken)?.bundleIdentifier
        }

        let request = ActionRequest(type: clause.type,
                                    parameters: parameters.compactMapValues { $0 },
                                    dependencies: dependencies,
                                    origin: .localRouter,
                                    sourceText: clause.text,
                                    parametersAreStable: clause.isBounded || isFinal
                                        || !clause.type.carriesFreeText)

        log(.router, "matched \(clause.type.rawValue) from \"\(clause.text)\"", sensitive: true)
        return await submit(request, isAppClause: isAppClause, bundleID: resolvedBundleID)
    }

    private func submit(_ request: ActionRequest,
                        isAppClause: Bool,
                        bundleID: String?) async -> UUID? {
        guard let id = await scheduler.submit(request) else { return nil }
        executedSummaries.append(request.summary)
        if isAppClause {
            lastAppActionID = id
            lastAppBundleID = bundleID
        }
        return id
    }

    // MARK: Jev

    private func considerJev(text: String,
                             isFinal: Bool,
                             reason: String,
                             dryRun: Bool = false) async {
        guard let decisionProvider else {
            // Worth surfacing: "no key" and "Jev declined" look identical otherwise.
            report(JevConsultation(transcript: text, reason: reason),
                   outcome: "not consulted — Jev is disabled or has no API key")
            return
        }
        guard TranscriptManager.words(text).count >= 2 else { return }
        guard !jevInFlight else { return }
        guard dryRun || text != lastJevText else { return }

        if !dryRun, let lastJevAt, ContinuousClock.now - lastJevAt < minimumJevInterval {
            return
        }

        jevInFlight = true
        if !dryRun { lastJevText = text }
        lastJevAt = ContinuousClock.now

        defer { jevInFlight = false }

        var consultation = JevConsultation(transcript: text, reason: reason)
        let context = await buildContext(text: text, isFinal: isFinal)

        await latency.mark(.jevRequestStart)
        let decision: Decision
        do {
            decision = try await decisionProvider.decide(context)
            await latency.mark(.jevResponseReceived)
        } catch {
            // Jev unavailable is not fatal: the deterministic router keeps working.
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            log(.jev, "unavailable (\(message)) — local commands only")
            report(consultation, outcome: "error — \(message)")
            return
        }

        consultation.chosenAction = decision.actionType?.rawValue ?? "none"
        consultation.confidence = decision.confidence
        consultation.needsMoreSpeech = decision.needsMoreSpeech
        consultation.safeToSpeculate = decision.safeToSpeculate
        consultation.risk = decision.riskLevel.label
        consultation.probabilities = decision.probabilities
        consultation.latencyMs = decision.latencyMs

        guard let actionType = decision.actionType else {
            report(consultation, outcome: "declined — no applicable action")
            return
        }
        if dryRun {
            report(consultation, outcome: "shadow only — the local router already handled this")
            return
        }
        if decision.needsMoreSpeech && !isFinal {
            log(.jev, "needs more speech — holding \(actionType.rawValue)")
            report(consultation, outcome: "held — needs more speech")
            return
        }

        var parameters: [String: String] = [:]
        let requiredKeys = SarvamParameterExtractor.allowedKeys(for: actionType)
        if !requiredKeys.isEmpty {
            guard let extractor else {
                log(.jev, "\(actionType.rawValue) needs parameters but no extractor is configured")
                report(consultation, outcome: "blocked — \(actionType.rawValue) needs parameters but no extractor is configured")
                return
            }
            do {
                parameters = try await extractor.extractParameters(for: actionType,
                                                                    transcript: text,
                                                                    context: context)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                log(.llm, "parameter extraction failed: \(message)")
                report(consultation, outcome: "blocked — parameter extraction failed: \(message)")
                return
            }
            guard !parameters.isEmpty else {
                log(.jev, "no parameters extracted for \(actionType.rawValue) — skipping")
                report(consultation, outcome: "declined — no parameters could be extracted")
                return
            }
        }

        // Resolve the clicked element against the live window, so the model's
        // label is turned into a real AX handle by our code, not by the model.
        if actionType == .click, let target = parameters["target"] {
            let snapshot = await accessibility.snapshotFrontmost()
            if let element = await accessibility.bestMatch(for: target, in: snapshot) {
                parameters["elementID"] = element.id
            }
        }

        var decided = decision
        decided.parameters = parameters
        guard let request = decided.action(sourceText: text,
                                            dependencies: lastAppActionID.map { [$0] } ?? []) else {
            report(consultation, outcome: "declined — could not build an action")
            return
        }
        consultation.applied = true
        report(consultation, outcome: "dispatched \(request.summary)")

        let isAppClause = [ActionType.openApp, .focusApp, .openURL].contains(actionType)
        var resolvedBundleID: String?
        if isAppClause, let spoken = parameters["app"] {
            resolvedBundleID = await registry.resolve(spoken)?.bundleIdentifier
        }
        _ = await submit(request, isAppClause: isAppClause, bundleID: resolvedBundleID)
    }

    private func report(_ consultation: JevConsultation, outcome: String) {
        var recorded = consultation
        recorded.outcome = outcome
        log(.jev, "consultation: \(outcome)")
        onConsultation?(recorded)
    }

    private func buildContext(text: String, isFinal: Bool) async -> DecisionContext {
        let frontmost = NSWorkspace.shared.frontmostApplication

        // Only pay for an AX snapshot when the command plausibly touches the UI.
        var elements: [[String: String]] = []
        if Self.mentionsUI(text), AccessibilityManager.isTrusted {
            let snapshot = await accessibility.snapshotFrontmost()
            let relevant = await accessibility.relevantElements(for: text,
                                                                 in: snapshot,
                                                                 limit: 8)
            elements = relevant.map(\.compact)
        }

        return DecisionContext(transcript: text,
                               stablePrefix: text,
                               isFinal: isFinal,
                               frontmostApp: frontmost?.localizedName ?? "",
                               frontmostBundleID: frontmost?.bundleIdentifier,
                               availableActions: ActionType.allCases,
                               executedActions: executedSummaries,
                               relevantElements: elements)
    }

    private static let uiKeywords: Set<String> = [
        "click", "tap", "press", "button", "field", "select", "choose",
        "type", "write", "send", "find", "search", "menu", "tab", "link",
    ]

    private static func mentionsUI(_ text: String) -> Bool {
        let words = Set(TranscriptManager.words(text).map { TranscriptManager.normalizeWord($0) })
        return !words.isDisjoint(with: uiKeywords)
    }
}
