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
    /// One shadow consultation per command.
    private var shadowAsked = false
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
        shadowAsked = false
    }

    // MARK: Entry point

    /// `text` is the stable prefix while speaking, the full transcript when final.
    func process(text: String, isFinal: Bool) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isFinal { await scheduler.markTranscriptFinal() }

        // Jev-first: Jev's decision is what runs. The router is the fallback
        // for anything Jev declines, so a failed or refused call still leaves
        // the deterministic path working.
        // Waiting for the complete sentence means there is nothing to gain from
        // asking Jev about a partial — it just costs an extra call per command.
        if routingMode == .jevFirst, isFinal || speculativeExecution {
            let dispatched = await considerJev(text: trimmed,
                                                isFinal: isFinal,
                                                reason: "Jev-first routing")
            if dispatched {
                await latency.mark(.localIntentDetected)
                return
            }
        }

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
            await askShadowIfNeeded(text: trimmed, isFinal: isFinal)
            return
        }

        // Nothing deterministic matched — this is what Jev is for.
        if clauses.isEmpty, routingMode != .jevFirst {
            _ = await considerJev(text: trimmed, isFinal: isFinal,
                                  reason: "local router matched nothing")
        } else {
            await askShadowIfNeeded(text: trimmed, isFinal: isFinal)
        }
    }

    /// One observe-only consultation per command, on the final transcript.
    ///
    /// Asking on every stable-prefix growth produced several near-identical
    /// entries per command, which made the history harder to read than not
    /// having it.
    private func askShadowIfNeeded(text: String, isFinal: Bool) async {
        guard routingMode == .shadow, isFinal, !shadowAsked else { return }
        shadowAsked = true
        _ = await considerJev(text: text,
                              isFinal: isFinal,
                              reason: "shadow mode — comparing against the local router",
                              dryRun: true)
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

    /// Returns true when this consultation produced a dispatched action.
    @discardableResult
    private func considerJev(text: String,
                             isFinal: Bool,
                             reason: String,
                             dryRun: Bool = false) async -> Bool {
        guard let decisionProvider else {
            // Worth surfacing: "no key" and "Jev declined" look identical otherwise.
            report(JevConsultation(transcript: text, reason: reason),
                   outcome: "not consulted — Jev is disabled or has no API key")
            return false
        }
        guard TranscriptManager.words(text).count >= 2 else { return false }
        guard !jevInFlight else { return false }
        guard dryRun || text != lastJevText else { return false }

        if !dryRun, let lastJevAt, ContinuousClock.now - lastJevAt < minimumJevInterval {
            return false
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
            return false
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
            return false
        }
        if dryRun {
            report(consultation, outcome: "shadow only — the local router already handled this")
            return false
        }
        if decision.needsMoreSpeech && !isFinal {
            log(.jev, "needs more speech — holding \(actionType.rawValue)")
            report(consultation, outcome: "held — needs more speech")
            return false
        }

        // Deterministic parsing first. Jev picks the action; the words for its
        // parameters are already in the transcript, so recovering "chrome" from
        // "open chrome" needs no model — and asking one adds a network round
        // trip and a failure mode for nothing.
        var parameters = deterministicParameters(for: actionType, text: text)
        let missing = actionType.requiredParameterKeys.filter {
            parameters[$0]?.isEmpty != false
        }

        if missing.isEmpty {
            if !parameters.isEmpty {
                log(.planner, "parameters resolved locally for \(actionType.rawValue) — no text model needed")
            }
        } else {
            guard let extractor else {
                log(.jev, "\(actionType.rawValue) is missing \(missing) and no text model is configured")
                report(consultation, outcome: "blocked — missing \(missing.joined(separator: ", ")) and no text model is configured")
                return false
            }
            log(.llm, "local parsing could not supply \(missing) for \(actionType.rawValue) — asking the text model")
            do {
                let extracted = try await extractor.extractParameters(for: actionType,
                                                                       transcript: text,
                                                                       context: context)
                // Locally parsed values win; the model only fills the gaps.
                parameters.merge(extracted) { local, _ in local }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                log(.llm, "parameter extraction failed: \(message)")
                report(consultation, outcome: "blocked — parameter extraction failed: \(message)")
                return false
            }

            let stillMissing = actionType.requiredParameterKeys.filter {
                parameters[$0]?.isEmpty != false
            }
            guard stillMissing.isEmpty else {
                log(.jev, "still missing \(stillMissing) for \(actionType.rawValue) — skipping")
                report(consultation, outcome: "declined — could not resolve \(stillMissing.joined(separator: ", "))")
                return false
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
            return false
        }
        consultation.applied = true
        report(consultation, outcome: "dispatched \(request.summary)")

        let isAppClause = [ActionType.openApp, .focusApp, .openURL].contains(actionType)
        var resolvedBundleID: String?
        if isAppClause, let spoken = parameters["app"] {
            resolvedBundleID = await registry.resolve(spoken)?.bundleIdentifier
        }
        let id = await submit(request, isAppClause: isAppClause, bundleID: resolvedBundleID)
        return id != nil
    }

    /// Pulls an action's parameters out of the transcript with the same
    /// deterministic parser the local router uses.
    ///
    /// Jev chooses *which* action; the words for its parameters are already
    /// spoken. The router's clause types may not match Jev's choice — Jev might
    /// say `focusApp` where the router parsed `openApp` — so values are matched
    /// by parameter key rather than by clause type, since both need `app`.
    private func deterministicParameters(for actionType: ActionType,
                                         text: String) -> [String: String] {
        let wanted = SarvamParameterExtractor.allowedKeys(for: actionType)
        guard !wanted.isEmpty else { return [:] }

        var found: [String: String] = [:]
        for clause in router.parse(text) {
            for key in wanted where found[key] == nil {
                if let value = clause.parameters[key], !value.isEmpty {
                    found[key] = value
                }
            }
        }

        // A spoken target can land under a different key than the one this
        // action wants — "open chrome" yields `app`, but Jev may have chosen
        // `click`, which wants `target`. These names refer to the same words.
        let interchangeable = ["app", "target", "query", "command", "text"]
        for key in wanted where found[key] == nil {
            guard interchangeable.contains(key) else { continue }
            for clause in router.parse(text) {
                for alias in interchangeable where alias != key {
                    if let value = clause.parameters[alias], !value.isEmpty {
                        found[key] = value
                        break
                    }
                }
                if found[key] != nil { break }
            }
        }

        return found
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
