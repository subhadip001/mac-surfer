import Foundation

/// Points on the voice -> action path that we time.
enum LatencyMark: String, CaseIterable, Sendable {
    case micStart = "mic_start"
    case firstAudioSent = "first_audio_sent"
    case sttConnected = "stt_connected"
    case firstSttInterim = "first_stt_interim"
    case stablePrefixDetected = "stable_prefix_detected"
    case localIntentDetected = "local_intent_detected"
    case jevRequestStart = "jev_request_start"
    case jevResponseReceived = "jev_response_received"
    case firstActionStart = "action_start"
    case firstActionCompleted = "action_completed"
    case finalTranscript = "final_transcript"
}

struct LatencySnapshot: Sendable {
    var marks: [LatencyMark: TimeInterval] = [:]   // ms since micStart
    var sessionStart: Date?

    /// The headline metric: voice start -> the first thing the Mac actually did.
    var timeToFirstAction: TimeInterval? { marks[.firstActionStart] }
    var timeToFirstTranscript: TimeInterval? { marks[.firstSttInterim] }
    var timeToFirstDecision: TimeInterval? {
        // Whichever decision path fired first.
        [marks[.localIntentDetected], marks[.jevResponseReceived]]
            .compactMap { $0 }.min()
    }
    var totalCommandLatency: TimeInterval? { marks[.firstActionCompleted] }

    func ms(_ mark: LatencyMark) -> String {
        guard let v = marks[mark] else { return "—" }
        return String(format: "%.0f ms", v)
    }
}

/// Records monotonic timings per listening session.
///
/// Marks are "first wins": re-recording `firstActionStart` for the second action
/// in a sentence would destroy the metric we care most about.
actor LatencyTracker {
    private var start: ContinuousClock.Instant?
    private var snapshot = LatencySnapshot()

    /// Last completed session, kept so the debug panel still has data at idle.
    private(set) var previous: LatencySnapshot?

    func beginSession() {
        if snapshot.marks.isEmpty == false { previous = snapshot }
        start = ContinuousClock.now
        snapshot = LatencySnapshot(marks: [:], sessionStart: Date())
        snapshot.marks[.micStart] = 0
    }

    func mark(_ mark: LatencyMark) {
        guard let start else { return }
        guard snapshot.marks[mark] == nil else { return }  // first wins
        let elapsed = ContinuousClock.now - start
        let millis = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        snapshot.marks[mark] = millis
        log(.latency, "\(mark.rawValue): \(String(format: "%.0f", millis)) ms")
    }

    func current() -> LatencySnapshot { snapshot }

    func endSession() {
        previous = snapshot
        if let tfa = snapshot.timeToFirstAction {
            log(.latency, "VOICE START -> FIRST ACTION: \(String(format: "%.0f", tfa)) ms")
        }
        start = nil
    }

    func report() -> String {
        let s = snapshot.marks.isEmpty ? (previous ?? snapshot) : snapshot
        var out = ""
        for mark in LatencyMark.allCases where s.marks[mark] != nil {
            out += "\(mark.rawValue.padding(toLength: 24, withPad: " ", startingAt: 0)) \(s.ms(mark))\n"
        }
        return out
    }
}
