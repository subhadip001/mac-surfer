import Foundation

/// Lightweight energy-based voice activity detection.
///
/// Sarvam's realtime socket already performs server-side VAD and emits
/// `vad.speech_start` / `vad.speech_end`, which is authoritative for
/// end-of-turn. This local detector exists for two cheaper jobs:
///   * driving the listening overlay's level meter without a network round trip
///   * knowing locally whether the user has said anything at all yet, so the
///     UI can distinguish "listening, silence" from "listening, speaking"
struct VoiceActivityDetector {
    /// Adaptive noise floor, so a noisy room does not read as constant speech.
    private var noiseFloor: Float = 0.005
    private var consecutiveSpeechFrames = 0
    private var consecutiveSilenceFrames = 0

    /// Speech must exceed the noise floor by this factor.
    var speechMultiplier: Float = 3.0
    /// Frames of speech before we flip to `speaking` (debounce against clicks).
    var speechFramesToTrigger = 3
    /// Frames of silence before we flip back (hangover, so pauses mid-sentence
    /// do not read as end-of-turn).
    var silenceFramesToRelease = 12

    private(set) var isSpeaking = false
    private(set) var peak: Float = 0

    /// Feed one `AudioChunk`'s RMS. Returns true when the speaking state flips.
    @discardableResult
    mutating func consume(rms: Float) -> Bool {
        peak = max(peak * 0.92, rms)

        let threshold = max(noiseFloor * speechMultiplier, 0.012)
        let wasSpeaking = isSpeaking

        if rms > threshold {
            consecutiveSpeechFrames += 1
            consecutiveSilenceFrames = 0
            if consecutiveSpeechFrames >= speechFramesToTrigger { isSpeaking = true }
        } else {
            consecutiveSilenceFrames += 1
            consecutiveSpeechFrames = 0
            // Only adapt the floor while quiet, or speech would raise it.
            noiseFloor = noiseFloor * 0.95 + rms * 0.05
            if consecutiveSilenceFrames >= silenceFramesToRelease { isSpeaking = false }
        }

        return wasSpeaking != isSpeaking
    }

    mutating func reset() {
        consecutiveSpeechFrames = 0
        consecutiveSilenceFrames = 0
        isSpeaking = false
        peak = 0
    }
}
