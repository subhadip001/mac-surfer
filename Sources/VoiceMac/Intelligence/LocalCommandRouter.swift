import Foundation

/// One command clause found in the transcript, with the word range it occupies.
///
/// The word range is the clause's identity: the planner uses `startWordIndex`
/// to recognise a clause it has already dispatched, even as later words keep
/// arriving and the text is re-parsed from scratch.
struct ParsedClause: Sendable {
    let startWordIndex: Int
    let endWordIndex: Int
    let type: ActionType
    var parameters: [String: String]
    /// True when a later clause follows, which proves this clause's text has
    /// stopped growing. Free-text actions require this (or a final transcript).
    let isBounded: Bool
    let text: String
    /// Set when this clause should wait for a preceding app-targeting clause.
    var dependsOnPreviousAppClause: Bool
}

/// Deterministic command matching. No network, no model.
///
/// This is the whole reason "open chrome" can launch before the sentence ends:
/// it is a pure function over the stable transcript prefix, so it costs
/// microseconds and can be re-run on every partial. Jev is consulted only for
/// text this router cannot claim.
struct LocalCommandRouter: Sendable {

    private enum Verb {
        case open, close, focus, searchWeb, searchInApp, screenshot
        case mute, unmute, volumeUp, volumeDown, setVolume
        case copy, paste, selectAll, scroll, typeText, pressKey, sendMessage
        case click, doubleClick, rightClick, focusElement, menuCommand, clearField

        /// Clauses whose object is free text that keeps growing while spoken.
        /// Inside these, a later verb only starts a new clause if a connector
        /// precedes it — otherwise "search for how to open a jar file" would
        /// split at "open".
        var objectIsFreeText: Bool {
            switch self {
            case .searchWeb, .searchInApp, .typeText, .sendMessage: return true
            default: return false
            }
        }
    }

    /// Spoken ordinals for "click the second button".
    private static let ordinals: [String: Int] = [
        "first": 1, "1st": 1, "second": 2, "2nd": 2, "third": 3, "3rd": 3,
        "fourth": 4, "4th": 4, "fifth": 5, "5th": 5, "sixth": 6, "6th": 6,
        "seventh": 7, "7th": 7, "eighth": 8, "8th": 8, "ninth": 9, "9th": 9,
        "tenth": 10, "10th": 10, "last": -1,
    ]

    /// Longest phrases first so "search for" wins over "search".
    private static let verbPhrases: [([String], Verb)] = {
        let table: [([String], Verb)] = [
            (["take", "a", "screenshot"], .screenshot),
            (["take", "screenshot"], .screenshot),
            (["capture", "the", "screen"], .screenshot),
            (["capture", "screen"], .screenshot),
            (["screenshot"], .screenshot),

            (["search", "the", "web", "for"], .searchWeb),
            (["search", "google", "for"], .searchWeb),
            (["search", "online", "for"], .searchWeb),
            (["search", "for"], .searchWeb),
            (["google", "for"], .searchWeb),
            (["look", "up"], .searchWeb),
            (["google"], .searchWeb),
            (["search"], .searchWeb),

            (["find"], .searchInApp),

            (["switch", "to"], .focus),
            (["bring", "up"], .focus),
            (["focus", "on"], .focus),
            (["go", "to"], .focus),
            (["activate"], .focus),
            (["focus"], .focus),

            (["fire", "up"], .open),
            (["open", "up"], .open),
            (["open"], .open),
            (["launch"], .open),
            (["start"], .open),

            (["quit"], .close),
            (["close"], .close),
            (["exit"], .close),

            (["turn", "the", "volume", "up"], .volumeUp),
            (["turn", "up", "the", "volume"], .volumeUp),
            (["volume", "up"], .volumeUp),
            (["louder"], .volumeUp),
            (["turn", "the", "volume", "down"], .volumeDown),
            (["turn", "down", "the", "volume"], .volumeDown),
            (["volume", "down"], .volumeDown),
            (["quieter"], .volumeDown),
            (["set", "the", "volume", "to"], .setVolume),
            (["set", "volume", "to"], .setVolume),

            (["unmute"], .unmute),
            (["mute"], .mute),

            (["select", "all"], .selectAll),
            (["copy"], .copy),
            (["paste"], .paste),
            (["scroll"], .scroll),

            (["type"], .typeText),
            (["write"], .typeText),
            (["enter"], .typeText),

            // Longest first so "double click" is not matched as "click".
            (["double", "click", "on"], .doubleClick),
            (["double", "click"], .doubleClick),
            (["double", "tap"], .doubleClick),
            (["right", "click", "on"], .rightClick),
            (["right", "click"], .rightClick),
            (["control", "click"], .rightClick),
            (["secondary", "click"], .rightClick),

            (["clear", "the", "field"], .clearField),
            (["clear", "field"], .clearField),
            (["clear"], .clearField),

            (["click", "into"], .focusElement),
            (["click", "in"], .focusElement),
            (["focus", "the"], .focusElement),
            (["put", "the", "cursor", "in"], .focusElement),
            (["put", "cursor", "in"], .focusElement),

            (["choose"], .menuCommand),
            (["select"], .menuCommand),

            (["click", "on"], .click),
            (["tap", "on"], .click),
            (["click"], .click),
            (["tap"], .click),
            (["push"], .click),

            (["press"], .pressKey),
            (["send"], .sendMessage),
        ]
        return table.sorted { $0.0.count > $1.0.count }
    }()

    /// In-app actions that only make sense once a preceding app clause has
    /// finished bringing that app to the front.
    private static let dependsOnApp: Set<ActionType> = [
        .searchWeb, .searchInApp, .click, .doubleClick, .rightClick,
        .focusElement, .menuCommand, .clearField, .typeText, .sendMessage,
        .scroll, .pressKey,
    ]

    private static let connectors: Set<String> = [
        "and", "then", "also", "after", "that", "next", "plus",
    ]

    /// Words after which a command verb is really a noun.
    ///
    /// "Send" and "Search" are both verbs in this grammar and extremely common
    /// UI labels. A determiner or preposition immediately before one means it
    /// is naming a thing, not starting a command: "click the **Send** button",
    /// "click into the **search** field".
    private static let nounSignals: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those",
        "my", "your", "our", "its", "any", "every",
        "into", "in", "on", "to", "from", "of", "with", "at", "by",
    ]

    private static let leadingFiller: Set<String> = [
        "hey", "ok", "okay", "please", "can", "you", "could", "would", "i",
        "want", "to", "need", "lets", "let", "us", "um", "uh", "just", "now",
        "voicemac", "computer",
    ]

    private static let objectNoise: Set<String> = [
        "the", "a", "an", "my", "some", "please", "app", "application",
    ]

    /// Spoken names that are websites rather than installed apps.
    private static let knownSites: [String: String] = [
        "youtube": "https://www.youtube.com",
        "gmail": "https://mail.google.com",
        "google": "https://www.google.com",
        "github": "https://github.com",
        "twitter": "https://twitter.com",
        "x": "https://x.com",
        "reddit": "https://www.reddit.com",
        "wikipedia": "https://www.wikipedia.org",
        "google maps": "https://maps.google.com",
        "maps": "https://maps.google.com",
        "google drive": "https://drive.google.com",
        "drive": "https://drive.google.com",
        "google docs": "https://docs.google.com",
        "docs": "https://docs.google.com",
        "sheets": "https://docs.google.com/spreadsheets",
        "linkedin": "https://www.linkedin.com",
        "instagram": "https://www.instagram.com",
        "facebook": "https://www.facebook.com",
        "netflix": "https://www.netflix.com",
        "amazon": "https://www.amazon.in",
        "flipkart": "https://www.flipkart.com",
        "zomato": "https://www.zomato.com",
        "swiggy": "https://www.swiggy.com",
        "hotstar": "https://www.hotstar.com",
        "stackoverflow": "https://stackoverflow.com",
        "stack overflow": "https://stackoverflow.com",
        "chatgpt": "https://chatgpt.com",
        "openai": "https://openai.com",
        "claude": "https://claude.ai",
    ]

    private static let tlds: Set<String> = [
        "com", "in", "org", "net", "io", "ai", "co", "dev", "app", "me",
        "gov", "edu", "xyz", "so", "sh",
    ]

    // MARK: Parse

    /// Parses the whole text into clauses. Deterministic and side-effect free,
    /// so it is safe to call on every partial transcript.
    func parse(_ text: String) -> [ParsedClause] {
        let originalWords = TranscriptManager.words(text)
        guard !originalWords.isEmpty else { return [] }

        let normalized = originalWords.map { TranscriptManager.normalizeWord($0) }

        // Skip conversational lead-in, but never skip a word that is itself a verb.
        var cursor = 0
        while cursor < normalized.count,
              Self.leadingFiller.contains(normalized[cursor]),
              Self.matchVerb(normalized, at: cursor) == nil {
            cursor += 1
        }

        // Pass 1: locate clause boundaries.
        struct Boundary { let verb: Verb; let verbStart: Int; let objectStart: Int }
        var boundaries: [Boundary] = []
        var index = cursor
        var activeIsFreeText = false

        while index < normalized.count {
            guard let (verb, length) = Self.matchVerb(normalized, at: index) else {
                index += 1
                continue
            }

            if let previous = boundaries.last {
                // A clause needs at least one object word before the next one
                // can start. Without this, "click Send" splits into an empty
                // click plus a sendMessage.
                let objectWordsSoFar = index - previous.objectStart
                if objectWordsSoFar <= 0 {
                    index += 1
                    continue
                }

                // A determiner or preposition before the verb means it is being
                // used as a noun: "click the Send button".
                if index > 0, Self.nounSignals.contains(normalized[index - 1]) {
                    index += 1
                    continue
                }

                // Inside a free-text object, require an explicit connector
                // before treating a verb as the start of a new command.
                if activeIsFreeText {
                    let precededByConnector = Self.connectors.contains(normalized[index - 1])
                    if !precededByConnector {
                        index += 1
                        continue
                    }
                }
            }

            boundaries.append(Boundary(verb: verb, verbStart: index, objectStart: index + length))
            activeIsFreeText = verb.objectIsFreeText
            index += length
        }

        guard !boundaries.isEmpty else { return [] }

        // Pass 2: each clause's object runs to the next clause's verb.
        var clauses: [ParsedClause] = []
        var sawAppClause = false

        for (position, boundary) in boundaries.enumerated() {
            let objectEnd = position + 1 < boundaries.count
                ? boundaries[position + 1].verbStart
                : normalized.count

            var objectWords = Array(originalWords[min(boundary.objectStart, objectEnd)..<objectEnd])
            // Drop a trailing connector that belongs to the next clause.
            while let last = objectWords.last,
                  Self.connectors.contains(TranscriptManager.normalizeWord(last)) {
                objectWords.removeLast()
            }

            let isBounded = position + 1 < boundaries.count
            let object = TranscriptManager.join(objectWords)

            guard var clause = buildClause(verb: boundary.verb,
                                            object: object,
                                            objectWords: objectWords,
                                            startWordIndex: boundary.verbStart,
                                            endWordIndex: objectEnd,
                                            isBounded: isBounded) else { continue }

            // "open chrome and search for X" — the search belongs to Chrome,
            // and must not run until Chrome is actually up.
            if sawAppClause, Self.dependsOnApp.contains(clause.type) {
                clause.dependsOnPreviousAppClause = true
            }
            if clause.type == .openApp || clause.type == .focusApp || clause.type == .openURL {
                sawAppClause = true
            }

            clauses.append(clause)
        }

        return clauses
    }

    // MARK: Clause construction

    private func buildClause(verb: Verb,
                             object: String,
                             objectWords: [String],
                             startWordIndex: Int,
                             endWordIndex: Int,
                             isBounded: Bool) -> ParsedClause? {

        func clause(_ type: ActionType,
                    _ parameters: [String: String]) -> ParsedClause {
            ParsedClause(startWordIndex: startWordIndex,
                         endWordIndex: endWordIndex,
                         type: type,
                         parameters: parameters,
                         isBounded: isBounded,
                         text: object,
                         dependsOnPreviousAppClause: false)
        }

        switch verb {
        case .screenshot:
            return clause(.screenshot, [:])
        case .mute:
            return clause(.mute, [:])
        case .unmute:
            return clause(.unmute, [:])
        case .volumeUp:
            return clause(.setVolume, ["direction": "up"])
        case .volumeDown:
            return clause(.setVolume, ["direction": "down"])
        case .copy:
            return clause(.copy, [:])
        case .paste:
            return clause(.paste, [:])

        case .setVolume:
            guard let level = Self.firstNumber(in: objectWords) else { return nil }
            return clause(.setVolume, ["level": String(level)])

        case .scroll:
            let direction = Self.scrollDirection(objectWords) ?? "down"
            return clause(.scroll, ["direction": direction])

        case .open, .focus:
            let target = Self.cleanObject(objectWords)
            guard !target.isEmpty else { return nil }

            if let url = Self.detectURL(target) {
                return clause(.openURL, ["url": url])
            }
            if let site = Self.knownSites[Fuzzy.normalize(target)] {
                // Only a site if it is not also an installed app; the planner
                // re-checks the registry before committing to this.
                return clause(.openApp, ["app": target, "urlFallback": site])
            }
            return clause(verb == .open ? .openApp : .focusApp, ["app": target])

        case .close:
            let target = Self.cleanObject(objectWords)
            guard !target.isEmpty else { return nil }
            return clause(.closeApp, ["app": target])

        case .searchWeb:
            let query = Self.cleanQuery(objectWords)
            guard !query.isEmpty else { return nil }
            return clause(.searchWeb, ["query": query])

        case .searchInApp:
            let query = Self.cleanQuery(objectWords)
            guard !query.isEmpty else { return nil }
            return clause(.searchInApp, ["query": query])

        case .selectAll:
            return clause(.pressKey, ["key": "command a"])

        case .typeText:
            // "type hello into the message box" splits into text and target.
            let (body, target) = Self.splitTrailingTarget(objectWords)
            let text = Self.cleanQuery(body)
            guard !text.isEmpty else { return nil }
            var parameters = ["text": text]
            if let target, !target.isEmpty { parameters["target"] = target }
            return clause(.typeText, parameters)

        case .clearField:
            let target = Self.cleanObject(objectWords)
            return clause(.clearField, target.isEmpty ? [:] : ["target": target])

        case .focusElement:
            let target = Self.cleanObject(objectWords)
            guard !target.isEmpty else { return nil }
            return clause(.focusElement, ["target": target])

        case .menuCommand:
            // "choose New Window from the File menu"
            let (command, menu) = Self.splitMenuScope(objectWords)
            let cleaned = Self.cleanObject(command)
            guard !cleaned.isEmpty else { return nil }
            var parameters = ["command": cleaned]
            if let menu { parameters["menu"] = menu }
            return clause(.menuCommand, parameters)

        case .click, .doubleClick, .rightClick:
            // "click at 500 300"
            if let point = Self.coordinates(in: objectWords), verb == .click {
                return clause(.clickAt, ["x": String(point.0), "y": String(point.1)])
            }

            var words = objectWords
            var parameters: [String: String] = [:]

            // "click the second button" / "click the Send button"
            if let ordinal = Self.leadingOrdinal(&words) {
                parameters["ordinal"] = String(ordinal)
            }
            if let last = words.last,
               ["button", "buttons"].contains(TranscriptManager.normalizeWord(last)) {
                parameters["role"] = "button"
                words.removeLast()
            }

            let target = Self.cleanObject(words)
            guard !target.isEmpty else { return nil }
            parameters["target"] = target

            let type: ActionType = verb == .doubleClick ? .doubleClick
                : verb == .rightClick ? .rightClick : .click
            return clause(type, parameters)

        case .pressKey:
            let key = Self.cleanObject(objectWords)
            guard !key.isEmpty else { return nil }
            return clause(.pressKey, ["key": key])

        case .sendMessage:
            // Deliberately parsed but always routed through confirmation.
            let body = Self.cleanQuery(objectWords)
            guard !body.isEmpty else { return nil }
            return clause(.sendMessage, ["text": body])
        }
    }

    // MARK: Matching helpers

    private static func matchVerb(_ words: [String], at index: Int) -> (Verb, Int)? {
        for (phrase, verb) in verbPhrases {
            guard index + phrase.count <= words.count else { continue }
            if Array(words[index..<(index + phrase.count)]) == phrase {
                return (verb, phrase.count)
            }
        }
        return nil
    }

    private static func cleanObject(_ words: [String]) -> String {
        var cleaned = words.filter { !objectNoise.contains(TranscriptManager.normalizeWord($0)) }
        if cleaned.isEmpty { cleaned = words }
        return TranscriptManager.join(cleaned)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
    }

    /// Queries keep their articles — "the best bengali restaurants" is the query.
    private static func cleanQuery(_ words: [String]) -> String {
        var cleaned = words
        while let first = cleaned.first,
              ["for", "about", "on"].contains(TranscriptManager.normalizeWord(first)) {
            cleaned.removeFirst()
        }
        while let last = cleaned.last,
              ["please", "thanks"].contains(TranscriptManager.normalizeWord(last)) {
            cleaned.removeLast()
        }
        return TranscriptManager.join(cleaned)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,!?"))
    }

    /// Splits "hello there into the message box" into ("hello there", "message box").
    ///
    /// Only the *last* occurrence is treated as the target, so text that itself
    /// contains "in" survives: "type meet me in the park" has no target.
    static func splitTrailingTarget(_ words: [String]) -> ([String], String?) {
        let markers: Set<String> = ["into", "in"]
        let fieldNouns: Set<String> = [
            "field", "box", "bar", "area", "input", "textbox", "textfield",
            "composer", "editor", "search", "message", "address", "url",
        ]

        var index = words.count - 1
        while index > 0 {
            let word = TranscriptManager.normalizeWord(words[index])
            if markers.contains(word) {
                let tail = Array(words[(index + 1)...])
                // Require the tail to name something field-like; otherwise "in"
                // is just part of the sentence.
                let tailWords = Set(tail.map { TranscriptManager.normalizeWord($0) })
                if !tail.isEmpty, !tailWords.isDisjoint(with: fieldNouns) {
                    return (Array(words[..<index]), cleanObject(tail))
                }
            }
            index -= 1
        }
        return (words, nil)
    }

    /// Splits "New Window from the File menu" into ("New Window", "File").
    static func splitMenuScope(_ words: [String]) -> ([String], String?) {
        let normalized = words.map { TranscriptManager.normalizeWord($0) }
        guard let menuIndex = normalized.lastIndex(of: "menu") else {
            return (words, nil)
        }

        // Walk back over "from the <name> menu" / "in the <name> menu".
        var start = menuIndex - 1
        var menuWords: [String] = []
        while start >= 0 {
            let word = normalized[start]
            if ["from", "in", "under", "the", "on"].contains(word) { break }
            menuWords.insert(words[start], at: 0)
            start -= 1
            if menuWords.count >= 3 { break }
        }
        guard !menuWords.isEmpty else { return (words, nil) }

        // Drop the connector words preceding the menu name.
        var commandEnd = start
        while commandEnd > 0,
              ["from", "in", "under", "the", "on"].contains(normalized[commandEnd]) {
            commandEnd -= 1
        }
        let command = Array(words[..<max(commandEnd + 1, 0)])
        return (command.isEmpty ? words : command,
                cleanObject(menuWords))
    }

    /// "click at 500 300" -> (500, 300)
    static func coordinates(in words: [String]) -> (Int, Int)? {
        let numbers = words.compactMap { Int(TranscriptManager.normalizeWord($0)) }
        guard numbers.count >= 2 else { return nil }
        return (numbers[0], numbers[1])
    }

    /// Consumes a leading ordinal and returns it: "second button" -> 2.
    static func leadingOrdinal(_ words: inout [String]) -> Int? {
        var index = 0
        while index < words.count,
              ["the", "a", "an"].contains(TranscriptManager.normalizeWord(words[index])) {
            index += 1
        }
        guard index < words.count,
              let ordinal = ordinals[TranscriptManager.normalizeWord(words[index])] else {
            return nil
        }
        words.removeSubrange(0...index)
        return ordinal
    }

    private static func firstNumber(in words: [String]) -> Int? {
        let spelled: [String: Int] = [
            "zero": 0, "ten": 10, "twenty": 20, "thirty": 30, "forty": 40,
            "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80,
            "ninety": 90, "hundred": 100, "max": 100, "full": 100, "half": 50,
        ]
        for word in words {
            let normalized = TranscriptManager.normalizeWord(word)
            if let value = Int(normalized) { return min(max(value, 0), 100) }
            if let value = spelled[normalized] { return value }
        }
        return nil
    }

    private static func scrollDirection(_ words: [String]) -> String? {
        for word in words.map({ TranscriptManager.normalizeWord($0) }) {
            switch word {
            case "up": return "up"
            case "down": return "down"
            case "top", "beginning": return "top"
            case "bottom", "end": return "bottom"
            default: continue
            }
        }
        return nil
    }

    /// Recognises both "github.com" and the spoken form "github dot com".
    static func detectURL(_ text: String) -> String? {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespaces)
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            return lowered
        }

        let spokenJoined = lowered
            .replacingOccurrences(of: " dot ", with: ".")
            .replacingOccurrences(of: " slash ", with: "/")
            .replacingOccurrences(of: " ", with: "")

        guard spokenJoined.contains(".") else { return nil }
        let host = spokenJoined.split(separator: "/").first.map(String.init) ?? spokenJoined
        guard let tld = host.split(separator: ".").last.map(String.init),
              tlds.contains(tld),
              host.split(separator: ".").count >= 2 else { return nil }

        return "https://" + spokenJoined
    }
}
