import Foundation

struct TranscriptState: Sendable {
    /// Utterances the provider has finalized this session.
    var committedText: String = ""
    /// The current revisable partial.
    var interimText: String = ""
    /// What the user has said so far, as best we know.
    var fullText: String = ""
    /// The leading portion of `fullText` we believe will not be revised.
    /// Only this is allowed to drive execution.
    var stablePrefix: String = ""
    /// The last text handed to the router/planner, so work is not repeated.
    var lastProcessedText: String = ""
    /// True once the provider has signalled end-of-turn.
    var isFinal: Bool = false
}

enum TranscriptUpdate: Sendable {
    /// The stable prefix extended. Safe actions may be derived from `stable`.
    case stablePrefixGrew(stable: String, full: String)
    /// Interim text changed but nothing new became stable. UI-only.
    case interimChanged(full: String)
    /// The provider revised text we had already treated as stable. Anything
    /// already executed stands; nothing new should be speculated from here
    /// without re-confirmation.
    case stablePrefixRevised(old: String, stable: String, full: String)
    /// End of turn — the full text is now authoritative.
    case finalized(full: String)
}

/// Turns a stream of revisable partials into a monotonic "safe to act on" prefix.
///
/// The core of mid-sentence execution. Two independent guards decide stability:
///
///  1. **Agreement.** A word must appear identically in the last
///     `stabilityWindow` partials (default 2).
///  2. **Trailing-word exclusion.** The final word of the newest partial is
///     never considered stable — it is the word most likely to still be
///     growing ("chrom" -> "chrome"), and acting on it is how you launch the
///     wrong app.
///
/// Together these mean "open chrome" becomes actionable roughly one partial
/// after it is spoken, while a half-heard word never is.
actor TranscriptManager {
    private var state = TranscriptState()

    /// Recent partials for the current utterance, as word arrays.
    private var history: [[String]] = []
    private let historyLimit = 8

    private var stabilityWindow: Int
    /// Words already turned into actions, so the router sees only new text.
    private var consumedWordCount = 0

    init(stabilityWindow: Int = 2) {
        self.stabilityWindow = max(1, stabilityWindow)
    }

    func configure(stabilityWindow: Int) {
        self.stabilityWindow = max(1, stabilityWindow)
    }

    func reset() {
        state = TranscriptState()
        history.removeAll()
        consumedWordCount = 0
    }

    func current() -> TranscriptState { state }

    /// Number of words of `stablePrefix` the planner has already handled.
    func consumedWords() -> Int { consumedWordCount }

    func markConsumed(words: Int) {
        consumedWordCount = max(consumedWordCount, words)
        state.lastProcessedText = Self.join(Self.words(state.stablePrefix).prefix(consumedWordCount))
    }

    /// The portion of the stable prefix the planner has not yet seen.
    func unconsumedStableText() -> String {
        let words = Self.words(state.stablePrefix)
        guard consumedWordCount < words.count else { return "" }
        return Self.join(words.dropFirst(consumedWordCount))
    }

    // MARK: Ingest

    func ingest(interim text: String) -> TranscriptUpdate {
        state.interimText = text
        state.fullText = Self.compose(committed: state.committedText, interim: text)

        history.append(Self.words(text))
        if history.count > historyLimit { history.removeFirst() }

        return recomputeStability()
    }

    func ingest(final text: String) -> TranscriptUpdate {
        state.committedText = Self.merge(committed: state.committedText, final: text)
        state.interimText = ""
        state.fullText = state.committedText

        // A final transcript is by definition not going to be revised, so the
        // whole thing is stable — including the trailing word we were
        // withholding. This is where query-bearing actions become safe.
        let previousStable = state.stablePrefix
        state.stablePrefix = state.fullText
        state.isFinal = true
        history.removeAll()

        if !previousStable.isEmpty, !Self.isWordPrefix(previousStable, of: state.fullText) {
            log(.transcript, "final revised earlier stable text", sensitive: true)
        }
        return .finalized(full: state.fullText)
    }

    /// Called on provider end-of-turn when no further final text arrives.
    func promoteInterimToFinal() -> TranscriptUpdate? {
        guard !state.interimText.isEmpty else { return nil }
        return ingest(final: state.interimText)
    }

    // MARK: Stability

    private func recomputeStability() -> TranscriptUpdate {
        let computed = computeStablePrefix()
        let previous = state.stablePrefix

        if computed.isEmpty {
            return .interimChanged(full: state.fullText)
        }

        if computed == previous {
            return .interimChanged(full: state.fullText)
        }

        // Normal case: the prefix extended.
        if Self.isWordPrefix(previous, of: computed) {
            state.stablePrefix = computed
            log(.transcript, "stable prefix: \"\(computed)\"", sensitive: true)
            return .stablePrefixGrew(stable: computed, full: state.fullText)
        }

        // The provider changed words we had already called stable.
        state.stablePrefix = computed
        // Anything past the divergence point must be re-derived.
        let shared = Self.commonWordPrefixLength(Self.words(previous), Self.words(computed))
        consumedWordCount = min(consumedWordCount, shared)
        log(.transcript, "stable prefix REVISED: \"\(previous)\" -> \"\(computed)\"", sensitive: true)
        return .stablePrefixRevised(old: previous, stable: computed, full: state.fullText)
    }

    private func computeStablePrefix() -> String {
        guard let newest = history.last else { return "" }
        guard history.count >= stabilityWindow else { return "" }

        // Guard 2: the newest partial's trailing word is still in flight.
        var candidates: [[String]] = [Array(newest.dropLast())]

        // Guard 1: require agreement with the preceding partials.
        let needed = stabilityWindow - 1
        if needed > 0 {
            let preceding = history.dropLast().suffix(needed)
            candidates.append(contentsOf: preceding)
        }

        let committedWords = Self.words(state.committedText)
        let common = Self.longestCommonWordPrefix(candidates)
        guard !common.isEmpty else { return "" }

        return Self.join(committedWords + common)
    }

    // MARK: Word helpers

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func join<S: Sequence>(_ words: S) -> String where S.Element == String {
        words.joined(separator: " ")
    }

    /// Case- and punctuation-insensitive word equality — STT flips
    /// capitalisation and trailing commas between partials constantly.
    static func sameWord(_ a: String, _ b: String) -> Bool {
        normalizeWord(a) == normalizeWord(b)
    }

    static func normalizeWord(_ w: String) -> String {
        w.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    static func longestCommonWordPrefix(_ lists: [[String]]) -> [String] {
        guard let first = lists.first else { return [] }
        guard lists.count > 1 else { return first }

        var length = first.count
        for other in lists.dropFirst() {
            length = min(length, commonWordPrefixLength(first, other))
            if length == 0 { break }
        }
        return Array(first.prefix(length))
    }

    static func commonWordPrefixLength(_ a: [String], _ b: [String]) -> Int {
        var i = 0
        while i < a.count && i < b.count && sameWord(a[i], b[i]) { i += 1 }
        return i
    }

    static func isWordPrefix(_ prefix: String, of text: String) -> Bool {
        let p = words(prefix), t = words(text)
        guard p.count <= t.count else { return false }
        return commonWordPrefixLength(p, t) == p.count
    }

    static func compose(committed: String, interim: String) -> String {
        if committed.isEmpty { return interim }
        if interim.isEmpty { return committed }
        return committed + " " + interim
    }

    /// Folds a newly final transcript into what is already committed.
    ///
    /// Providers emit more than one `transcript.final` for a single utterance:
    /// a first pass, then a corrected or extended version of the *same* speech.
    /// Blindly appending produced doubled transcripts like
    /// "Close the Chrome Close the Chrome app."
    ///
    /// A new final replaces the previous one when it is clearly a revision of
    /// it — either an extension of the same words, or close enough in wording
    /// to be the same speech re-transcribed. Otherwise it is a genuinely new
    /// segment and gets appended.
    static func merge(committed: String, final text: String) -> String {
        let incoming = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty else { return committed }
        guard !committed.isEmpty else { return incoming }

        // Split off the last committed segment; earlier segments are settled.
        let segments = committed.components(separatedBy: " ⏎ ")
        let previous = segments.last ?? committed
        let earlier = segments.dropLast().joined(separator: " ⏎ ")

        func rejoin(_ latest: String) -> String {
            earlier.isEmpty ? latest : earlier + " ⏎ " + latest
        }

        // Extension of the same words: "close the chrome" -> "close the chrome app"
        if isWordPrefix(previous, of: incoming) { return rejoin(incoming) }
        // Shorter re-transcription of what we already have.
        if isWordPrefix(incoming, of: previous) { return rejoin(previous) }

        // Same speech, different wording: "can you search youtube music" vs
        // "can we search youtube music com".
        if Fuzzy.score(query: previous, candidate: incoming) >= 0.6 {
            // Keep whichever is longer — usually the more complete pass.
            return rejoin(words(incoming).count >= words(previous).count ? incoming : previous)
        }

        return committed + " " + incoming
    }
}
