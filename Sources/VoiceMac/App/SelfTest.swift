import Foundation

/// `VoiceMac --self-test` exercises the parts of the pipeline that do not need
/// a microphone or the network: transcript stability, the deterministic router,
/// the dependency graph, and the risk floor.
///
/// This exists because the behaviour that matters most — acting on a partial
/// transcript before the sentence ends — is a timing property, and the only way
/// to check it repeatably is to replay a scripted partial stream and record
/// when each action actually fired.
enum SelfTest {

    /// Records what ran and when, instead of touching the system.
    actor RecordingExecutor: ActionExecutorProtocol {
        struct Entry: Sendable {
            let action: ActionRequest
            let at: ContinuousClock.Instant
        }
        private(set) var entries: [Entry] = []

        func execute(_ action: ActionRequest) async throws -> String {
            entries.append(Entry(action: action, at: ContinuousClock.now))
            return "recorded \(action.type.rawValue)"
        }

        func all() -> [Entry] { entries }
        func types() -> [ActionType] { entries.map(\.action.type) }
    }

    private static var failures = 0
    private static var checks = 0

    static func run() async -> Int32 {
        print("VoiceMac self-test\n")

        await testRouterClauses()
        await testInAppControl()
        await testFreeTextIsNotSplit()
        await testRiskFloor()
        await testTranscriptStability()
        await testMidSentenceExecution()
        await testApplicationResolution()
        await testCommandHistoryRecording()

        print("\n\(checks - failures)/\(checks) checks passed")
        return failures == 0 ? 0 : 1
    }

    // MARK: Checks

    private static func expect(_ condition: Bool, _ description: String, detail: String = "") {
        checks += 1
        if condition {
            print("  ok    \(description)")
        } else {
            failures += 1
            print("  FAIL  \(description)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    private static func heading(_ title: String) {
        print("\n\(title)")
    }

    // MARK: Router

    private static func testRouterClauses() async {
        heading("Router — clause segmentation")
        let router = LocalCommandRouter()

        var clauses = router.parse("open chrome and search for the best bengali restaurants in kolkata")
        expect(clauses.count == 2, "two clauses from the Chrome + search command",
               detail: "got \(clauses.map(\.type.rawValue))")
        expect(clauses.first?.type == .openApp, "first clause is openApp")
        expect(clauses.first?.parameters["app"] == "chrome", "app parameter is chrome",
               detail: clauses.first?.parameters["app"] ?? "nil")
        expect(clauses.last?.type == .searchWeb, "second clause is searchWeb")
        expect(clauses.last?.parameters["query"] == "the best bengali restaurants in kolkata",
               "query is captured whole",
               detail: clauses.last?.parameters["query"] ?? "nil")
        expect(clauses.last?.dependsOnPreviousAppClause == true,
               "search depends on the app clause")
        expect(clauses.first?.isBounded == true,
               "the openApp clause is bounded because a later clause follows")

        clauses = router.parse("open chrome")
        expect(clauses.count == 1 && clauses.first?.type == .openApp,
               "\"open chrome\" is a single openApp clause")
        expect(clauses.first?.isBounded == false,
               "a trailing clause is unbounded")

        clauses = router.parse("open slack and find rahul")
        expect(clauses.map(\.type) == [.openApp, .searchInApp],
               "Slack flow produces openApp then searchInApp",
               detail: "\(clauses.map(\.type.rawValue))")

        clauses = router.parse("go to github.com")
        expect(clauses.first?.type == .openURL, "\"go to github.com\" is openURL",
               detail: clauses.first?.type.rawValue ?? "nil")
        expect(clauses.first?.parameters["url"] == "https://github.com",
               "URL is normalised", detail: clauses.first?.parameters["url"] ?? "nil")

        clauses = router.parse("open github dot com")
        expect(clauses.first?.parameters["url"] == "https://github.com",
               "spoken \"dot com\" is recognised",
               detail: clauses.first?.parameters["url"] ?? "nil")

        clauses = router.parse("take a screenshot")
        expect(clauses.first?.type == .screenshot, "screenshot is recognised")

        clauses = router.parse("set volume to 30")
        expect(clauses.first?.parameters["level"] == "30", "volume level parsed",
               detail: clauses.first?.parameters["level"] ?? "nil")

        clauses = router.parse("hey can you please open chrome")
        expect(clauses.count == 1 && clauses.first?.parameters["app"] == "chrome",
               "conversational lead-in is stripped",
               detail: "\(clauses.map(\.type.rawValue))")

        clauses = router.parse("send rahul a message saying i'll call him tomorrow")
        expect(clauses.first?.type == .sendMessage, "send is recognised",
               detail: clauses.first?.type.rawValue ?? "nil")
    }

    private static func testInAppControl() async {
        heading("Router — in-app control")
        let router = LocalCommandRouter()

        func only(_ text: String) -> ParsedClause? { router.parse(text).first }

        // Clicking
        var clause = only("click the Send button")
        expect(clause?.type == .click, "click is recognised", detail: clause?.type.rawValue ?? "nil")
        expect(clause?.parameters["target"] == "Send", "button noun is stripped from the target",
               detail: clause?.parameters["target"] ?? "nil")
        expect(clause?.parameters["role"] == "button", "role hint is set")

        clause = only("click the second tab")
        expect(clause?.parameters["ordinal"] == "2", "ordinal is parsed",
               detail: clause?.parameters["ordinal"] ?? "nil")
        expect(clause?.parameters["target"] == "tab", "target survives the ordinal",
               detail: clause?.parameters["target"] ?? "nil")

        clause = only("double click the report")
        expect(clause?.type == .doubleClick, "double click beats click in matching",
               detail: clause?.type.rawValue ?? "nil")
        expect(clause?.parameters["target"] == "report", "double-click target",
               detail: clause?.parameters["target"] ?? "nil")

        clause = only("right click the file")
        expect(clause?.type == .rightClick, "right click is recognised",
               detail: clause?.type.rawValue ?? "nil")

        clause = only("click at 500 300")
        expect(clause?.type == .clickAt, "coordinate click is recognised",
               detail: clause?.type.rawValue ?? "nil")
        expect(clause?.parameters["x"] == "500" && clause?.parameters["y"] == "300",
               "coordinates parsed", detail: "\(clause?.parameters ?? [:])")

        // Focus
        clause = only("click into the search field")
        expect(clause?.type == .focusElement, "\"click into\" focuses rather than clicks",
               detail: clause?.type.rawValue ?? "nil")
        expect(clause?.parameters["target"] == "search field",
               "focus target keeps the phrase the user actually said",
               detail: clause?.parameters["target"] ?? "nil")

        // ...and the AX matcher recovers the bare label from that phrase.
        expect(AccessibilityManager.strippingGenericNouns("search field") == "search",
               "generic UI nouns are stripped when matching elements",
               detail: AccessibilityManager.strippingGenericNouns("search field") ?? "nil")
        expect(AccessibilityManager.strippingGenericNouns("send") == nil,
               "stripping leaves a bare label alone")
        expect(AccessibilityManager.strippingGenericNouns("button") == nil,
               "stripping never reduces a query to nothing")

        // Typing, with and without a named target
        clause = only("type hello there")
        expect(clause?.type == .typeText && clause?.parameters["target"] == nil,
               "plain type has no target", detail: "\(clause?.parameters ?? [:])")
        expect(clause?.parameters["text"] == "hello there", "typed text captured",
               detail: clause?.parameters["text"] ?? "nil")

        clause = only("type hello into the message box")
        expect(clause?.parameters["text"] == "hello", "text is split from the target",
               detail: clause?.parameters["text"] ?? "nil")
        expect(clause?.parameters["target"] == "message box", "target field captured",
               detail: clause?.parameters["target"] ?? "nil")

        // "in" that is part of the text must not be read as a target.
        clause = only("type meet me in the park")
        expect(clause?.parameters["target"] == nil,
               "\"in\" inside ordinary text is not a target",
               detail: clause?.parameters["target"] ?? "nil")
        expect(clause?.parameters["text"] == "meet me in the park",
               "the whole phrase is typed",
               detail: clause?.parameters["text"] ?? "nil")

        // Menu commands
        clause = only("choose New Window from the File menu")
        expect(clause?.type == .menuCommand, "menu command is recognised",
               detail: clause?.type.rawValue ?? "nil")
        expect(clause?.parameters["menu"] == "File", "menu is scoped",
               detail: clause?.parameters["menu"] ?? "nil")
        expect(clause?.parameters["command"] == "New Window", "command captured",
               detail: clause?.parameters["command"] ?? "nil")

        // Clearing and select-all
        clause = only("clear the field")
        expect(clause?.type == .clearField, "clear field is recognised",
               detail: clause?.type.rawValue ?? "nil")

        clause = only("select all")
        expect(clause?.type == .pressKey && clause?.parameters["key"] == "command a",
               "select all maps to ⌘A rather than a new primitive",
               detail: "\(clause?.parameters ?? [:])")

        // Dependency wiring for a full in-app sentence.
        let chain = router.parse("open slack and click into the message box and type hello")
        expect(chain.map(\.type) == [.openApp, .focusElement, .typeText],
               "a three-step in-app sentence parses in order",
               detail: "\(chain.map(\.type.rawValue))")
        expect(chain.dropFirst().allSatisfy { $0.dependsOnPreviousAppClause },
               "both in-app steps depend on the app opening first")
    }

    private static func testFreeTextIsNotSplit() async {
        heading("Router — free text is not split by verbs inside it")
        let router = LocalCommandRouter()

        // "open" appears inside the query and must not start a new clause.
        var clauses = router.parse("search for how to open a jar file")
        expect(clauses.count == 1, "query containing \"open\" stays one clause",
               detail: "got \(clauses.map(\.type.rawValue))")
        expect(clauses.first?.parameters["query"] == "how to open a jar file",
               "query is intact", detail: clauses.first?.parameters["query"] ?? "nil")

        // With an explicit connector, it should split.
        clauses = router.parse("search for jar files and then open terminal")
        expect(clauses.map(\.type) == [.searchWeb, .openApp],
               "an explicit connector does split a free-text clause",
               detail: "\(clauses.map(\.type.rawValue))")
        expect(clauses.first?.parameters["query"] == "jar files",
               "the connector is not left in the query",
               detail: clauses.first?.parameters["query"] ?? "nil")

        // "and" inside a query without a following verb must not split.
        clauses = router.parse("search for restaurants and cafes in kolkata")
        expect(clauses.count == 1, "\"and\" with no following verb does not split",
               detail: "got \(clauses.count) clauses")
    }

    // MARK: Risk

    private static func testRiskFloor() async {
        heading("Safety — the action type sets the risk floor")

        let forced = ActionRequest(type: .sendMessage,
                                   parameters: ["text": "hi"],
                                   riskLevel: .safe,
                                   origin: .jev)
        expect(forced.riskLevel == .destructive,
               "a provider cannot downgrade sendMessage to safe",
               detail: forced.riskLevel.label)

        let open = ActionRequest(type: .openApp, parameters: ["app": "chrome"], origin: .localRouter)
        expect(open.riskLevel == .safe, "openApp is safe")

        let close = ActionRequest(type: .closeApp, parameters: ["app": "chrome"], origin: .localRouter)
        expect(close.riskLevel == .caution, "closeApp is caution, not safe",
               detail: close.riskLevel.label)

        expect(ActionType.searchWeb.carriesFreeText, "searchWeb carries free text")
        expect(!ActionType.openApp.carriesFreeText, "openApp does not carry free text")

        // Parameter-driven escalation: the same action type, different risk.
        let newTab = ActionRequest(type: .menuCommand,
                                   parameters: ["command": "New Tab"],
                                   origin: .localRouter)
        expect(newTab.riskLevel == .caution, "a harmless menu command stays caution",
               detail: newTab.riskLevel.label)

        let trash = ActionRequest(type: .menuCommand,
                                  parameters: ["command": "Move to Trash"],
                                  origin: .localRouter)
        expect(trash.riskLevel == .destructive,
               "\"Move to Trash\" escalates to destructive",
               detail: trash.riskLevel.label)

        let deleteItem = ActionRequest(type: .menuCommand,
                                       parameters: ["command": "Delete Account"],
                                       origin: .localRouter)
        expect(deleteItem.riskLevel == .destructive,
               "a menu command containing \"delete\" escalates",
               detail: deleteItem.riskLevel.label)

        // Whole-word matching, so ordinary commands are not over-escalated.
        let undelete = ActionRequest(type: .menuCommand,
                                     parameters: ["command": "Clear Formatting"],
                                     origin: .localRouter)
        expect(undelete.riskLevel == .caution,
               "\"Clear Formatting\" is not mistaken for a destructive clear",
               detail: undelete.riskLevel.label)
    }

    // MARK: Transcript stability

    private static func testTranscriptStability() async {
        heading("Transcript — stable prefix detection")
        let manager = TranscriptManager(stabilityWindow: 2)

        let partials = [
            "open",
            "open chrome",
            "open chrome and",
            "open chrome and search",
            "open chrome and search for",
            "open chrome and search for openai",
        ]

        var stableAt: [String: Int] = [:]
        for (index, partial) in partials.enumerated() {
            let update = await manager.ingest(interim: partial)
            if case .stablePrefixGrew(let stable, _) = update, stableAt[stable] == nil {
                stableAt[stable] = index
            }
        }

        let state = await manager.current()
        expect(stableAt["open chrome"] != nil,
               "\"open chrome\" becomes a stable prefix")
        if let at = stableAt["open chrome"] {
            expect(at <= 2, "it stabilises by the third partial, not at the end",
                   detail: "stabilised at partial index \(at)")
        }
        expect(!state.stablePrefix.contains("openai"),
               "the trailing word is withheld from the stable prefix",
               detail: state.stablePrefix)

        // A revised word must not survive into the stable prefix.
        let revising = TranscriptManager(stabilityWindow: 2)
        _ = await revising.ingest(interim: "open chrom")
        _ = await revising.ingest(interim: "open chrome")
        let revisedState = await revising.current()
        expect(!revisedState.stablePrefix.contains("chrom ")
                && revisedState.stablePrefix != "open chrom",
               "a half-heard word is not treated as stable",
               detail: revisedState.stablePrefix)

        // A final transcript stabilises everything, including the last word.
        let finalizing = TranscriptManager(stabilityWindow: 2)
        _ = await finalizing.ingest(interim: "open chrome and search for openai")
        _ = await finalizing.ingest(final: "open chrome and search for openai")
        let finalState = await finalizing.current()
        expect(finalState.stablePrefix == "open chrome and search for openai",
               "a final transcript is fully stable",
               detail: finalState.stablePrefix)
        expect(finalState.isFinal, "final flag is set")
    }

    // MARK: The headline behaviour

    private static func testMidSentenceExecution() async {
        heading("Mid-sentence execution — Chrome launches before the sentence ends")

        let recorder = RecordingExecutor()
        let latency = LatencyTracker()
        let registry = ApplicationRegistry()
        await registry.refresh()
        let accessibility = AccessibilityManager()
        let scheduler = ActionScheduler(executor: recorder, latency: latency)
        let planner = ActionPlanner(registry: registry,
                                     accessibility: accessibility,
                                     scheduler: scheduler,
                                     latency: latency)
        await planner.configure(decisionProvider: nil, extractor: nil,
                                speculativeExecution: true)
        let transcripts = TranscriptManager(stabilityWindow: 2)

        await latency.beginSession()

        let partials = [
            "open",
            "open chrome",
            "open chrome and",
            "open chrome and search",
            "open chrome and search for",
            "open chrome and search for openai",
        ]

        var openAppFiredAtPartial: Int?
        for (index, partial) in partials.enumerated() {
            let update = await transcripts.ingest(interim: partial)
            if case .stablePrefixGrew(let stable, _) = update {
                await planner.process(text: stable, isFinal: false)
            }
            // Let the scheduler's execution task run.
            try? await Task.sleep(for: .milliseconds(60))

            if openAppFiredAtPartial == nil,
               await recorder.types().contains(.openApp) {
                openAppFiredAtPartial = index
            }
        }

        let beforeFinal = await recorder.types()
        expect(beforeFinal.contains(.openApp),
               "openApp executed from a partial transcript",
               detail: "executed: \(beforeFinal.map(\.rawValue))")
        if let at = openAppFiredAtPartial {
            expect(at < partials.count - 1,
                   "it fired before the last partial arrived",
                   detail: "fired at partial \(at) of \(partials.count - 1)")
        }
        expect(!beforeFinal.contains(.searchWeb),
               "searchWeb did NOT fire early — its query was still growing",
               detail: "executed: \(beforeFinal.map(\.rawValue))")

        // Now the user stops speaking.
        _ = await transcripts.ingest(final: "open chrome and search for openai")
        await planner.process(text: "open chrome and search for openai", isFinal: true)
        try? await Task.sleep(for: .milliseconds(250))

        let afterFinal = await recorder.types()
        expect(afterFinal.contains(.searchWeb),
               "searchWeb ran once the transcript was final",
               detail: "executed: \(afterFinal.map(\.rawValue))")
        expect(afterFinal.filter { $0 == .openApp }.count == 1,
               "openApp ran exactly once despite repeated re-parsing",
               detail: "executed: \(afterFinal.map(\.rawValue))")

        // The dependency must be recorded, and the search routed at the browser.
        let entries = await recorder.all()
        if let search = entries.first(where: { $0.action.type == .searchWeb }) {
            expect(!search.action.dependencies.isEmpty,
                   "searchWeb carries a dependency on the app it follows")
            expect(search.action.parameters["bundleID"] != nil,
                   "the search is targeted at the opened browser's bundle id",
                   detail: search.action.parameters["bundleID"] ?? "nil")
        }

        let report = await latency.report()
        print("\n  latency marks:")
        for line in report.split(separator: "\n") {
            print("    \(line)")
        }
    }

    // MARK: History

    private static func testCommandHistoryRecording() async {
        heading("History — command recording")

        var builder = CommandRecordBuilder()
        expect(!builder.hasContent, "a fresh recorder has nothing to write")

        // Mid-sentence: a partial transcript, then an action starts.
        builder.noteTranscript(stable: "open chrome", full: "open chrome and", isFinal: false)

        let open = ActionRequest(type: .openApp,
                                 parameters: ["app": "chrome"],
                                 origin: .localRouter)
        builder.noteSubmitted(open)
        builder.noteStatus(open.id, .running)
        builder.noteStatus(open.id, .completed)
        builder.noteResult(open.id, success: true, message: "Opened Google Chrome", durationMs: 42)

        // Then the sentence finishes and a dependent action runs.
        builder.noteTranscript(stable: "open chrome and search for openai",
                               full: "open chrome and search for openai",
                               isFinal: true)
        let search = ActionRequest(type: .searchWeb,
                                   parameters: ["query": "openai"],
                                   dependencies: [open.id],
                                   origin: .localRouter)
        builder.noteSubmitted(search)
        builder.noteStatus(search.id, .running)
        builder.noteStatus(search.id, .completed)
        builder.noteResult(search.id, success: true, message: "Searched", durationMs: 15)

        expect(builder.hasContent, "the recorder has content once something happened")
        let record = builder.finish(outcome: "completed")

        expect(record.actions.count == 2, "both actions recorded",
               detail: "\(record.actions.count)")
        expect(record.transcript == "open chrome and search for openai",
               "final transcript stored", detail: record.transcript)
        expect(record.executedMidSentence,
               "mid-sentence execution is flagged")
        expect(record.stablePrefixAtFirstAction == "open chrome",
               "records exactly what was stable when the first action fired",
               detail: record.stablePrefixAtFirstAction ?? "nil")
        expect(record.succeededCount == 2 && record.failedCount == 0,
               "success counts are right",
               detail: "\(record.succeededCount) ok / \(record.failedCount) failed")
        expect(record.actions.last?.dependsOn.first == open.id,
               "the dependency between the two actions survives into history")
        expect(record.actions.first?.durationMs == 42, "duration recorded",
               detail: "\(record.actions.first?.durationMs ?? -1)")

        // Jev consultations are recorded even when nothing is applied, so
        // "Jev declined" is distinguishable from "Jev was never asked".
        var declined = JevConsultation(transcript: "make it bigger",
                                        reason: "local router matched nothing")
        declined.chosenAction = "none"
        declined.outcome = "declined — no applicable action"
        var withJev = CommandRecordBuilder()
        withJev.noteTranscript(stable: "make it bigger", full: "make it bigger", isFinal: true)
        withJev.noteConsultation(declined)
        let jevRecord = withJev.finish(outcome: "completed")
        expect(jevRecord.jevConsultations.count == 1,
               "a declined consultation is still recorded")
        expect(jevRecord.jevConsultations.first?.applied == false,
               "a declined consultation is not marked applied")
        expect(record.jevConsultations.isEmpty,
               "a router-only command records no consultation",
               detail: "\(record.jevConsultations.count)")

        var ranked = JevConsultation(transcript: "t", reason: "r")
        ranked.probabilities = ["openApp": 0.7, "focusApp": 0.2, "none": 0.1]
        expect(ranked.rankedOptions.first?.0 == "openApp",
               "options rank strongest first",
               detail: ranked.rankedOptions.first?.0 ?? "nil")

        // A command where nothing ran before the transcript finished.
        var late = CommandRecordBuilder()
        late.noteTranscript(stable: "take a screenshot", full: "take a screenshot", isFinal: true)
        let shot = ActionRequest(type: .screenshot, origin: .localRouter)
        late.noteSubmitted(shot)
        late.noteStatus(shot.id, .running)
        let lateRecord = late.finish(outcome: "completed")
        expect(!lateRecord.executedMidSentence,
               "an action after the final transcript is not flagged mid-sentence")

        // Round-trips through JSON, since that is how it is persisted.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let data = try? encoder.encode(record),
           let restored = try? decoder.decode(CommandRecord.self, from: data) {
            expect(restored.id == record.id && restored.actions.count == 2,
                   "a record survives a JSON round trip")
            expect(restored.stablePrefixAtFirstAction == "open chrome",
                   "mid-sentence evidence survives the round trip")
            // One line, so the JSONL file stays append-safe.
            let text = String(data: data, encoding: .utf8) ?? ""
            expect(!text.contains("\n"), "encoded record contains no newline")
        } else {
            expect(false, "a record survives a JSON round trip", detail: "encode/decode failed")
        }
    }

    // MARK: Registry

    private static func testApplicationResolution() async {
        heading("Registry — fuzzy application resolution")
        let registry = ApplicationRegistry()
        await registry.refresh()

        let count = await registry.all().count
        expect(count > 5, "applications were indexed", detail: "\(count) found")

        // Safari and Finder ship with every macOS install.
        let safari = await registry.resolve("safari")
        expect(safari != nil, "\"safari\" resolves", detail: safari?.name ?? "nil")

        let finder = await registry.resolve("finder")
        expect(finder?.bundleIdentifier == "com.apple.finder",
               "\"finder\" resolves to com.apple.finder",
               detail: finder?.bundleIdentifier ?? "nil")

        let nonsense = await registry.resolve("zzzqqqxyznotanapp")
        expect(nonsense == nil, "nonsense does not resolve to a random app",
               detail: nonsense?.name ?? "nil")

        // Alias handling, only checked when the app is actually installed.
        if await registry.all().contains(where: { $0.bundleIdentifier == "com.google.Chrome" }) {
            let chrome = await registry.resolve("chrome")
            expect(chrome?.bundleIdentifier == "com.google.Chrome",
                   "\"chrome\" resolves to Google Chrome",
                   detail: chrome?.bundleIdentifier ?? "nil")
        } else {
            print("  skip  Chrome is not installed, alias check skipped")
        }

        if await registry.all().contains(where: { $0.bundleIdentifier == "com.microsoft.VSCode" }) {
            let code = await registry.resolve("vscode")
            expect(code?.bundleIdentifier == "com.microsoft.VSCode",
                   "\"vscode\" resolves to Visual Studio Code",
                   detail: code?.bundleIdentifier ?? "nil")
        } else {
            print("  skip  VS Code is not installed, alias check skipped")
        }

        expect(Fuzzy.score(query: "chrome", candidate: "Google Chrome") > 0.75,
               "fuzzy score rewards a contained word")
        expect(Fuzzy.score(query: "chrome", candidate: "Calculator") < 0.5,
               "fuzzy score rejects an unrelated name",
               detail: String(format: "%.2f", Fuzzy.score(query: "chrome", candidate: "Calculator")))
    }
}
