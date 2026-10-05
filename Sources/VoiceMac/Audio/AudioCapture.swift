import AVFoundation
import Foundation

/// One chunk of microphone audio, already converted to the wire format.
struct AudioChunk: Sendable {
    /// 16 kHz mono signed 16-bit little-endian PCM (`linear16`).
    let pcm: Data
    /// Root-mean-square level in 0...1, for the level meter and local VAD.
    let rms: Float
    let frameCount: Int
}

/// Continuous microphone capture.
///
/// Audio is converted and emitted chunk by chunk from inside the render tap —
/// it is never accumulated into a file and uploaded afterwards. The tap runs on
/// a realtime audio thread, so it does only format conversion and a
/// non-blocking `yield`; everything downstream is async.
final class AudioCapture: @unchecked Sendable {
    enum Failure: LocalizedError {
        case permissionDenied
        case noInputDevice
        case engineStartFailed(String)
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone access denied. Enable it in System Settings › Privacy & Security › Microphone."
            case .noInputDevice:
                return "No audio input device available."
            case .engineStartFailed(let detail):
                return "Could not start audio engine: \(detail)"
            case .converterUnavailable:
                return "Could not create a 16 kHz mono audio converter for this input device."
            }
        }
    }

    /// Target wire format: what Sarvam's realtime socket expects.
    static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let lock = NSLock()

    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    /// Chunks are coalesced to ~40 ms so we are not sending 50+ tiny WebSocket
    /// frames per second, while staying far below any perceptible delay.
    private let minimumFramesPerChunk = 640          // 40 ms at 16 kHz
    private var pending = Data()
    private var pendingFrames = 0
    private var isRunning = false

    var running: Bool { lock.withLock { isRunning } }

    // MARK: Permission

    static func microphoneAuthorization() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: Lifecycle

    /// Starts capture and returns the chunk stream.
    func start() throws -> AsyncStream<AudioChunk> {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw Failure.permissionDenied
        }

        if running { stop() }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw Failure.noInputDevice
        }

        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: Self.targetSampleRate,
                                          channels: 1,
                                          interleaved: true),
              let conv = AVAudioConverter(from: inputFormat, to: target) else {
            throw Failure.converterUnavailable
        }
        // Prefer quality that still costs nothing perceptible at 16 kHz mono.
        conv.sampleRateConverterQuality = AVAudioQuality.medium.rawValue

        lock.withLock {
            self.converter = conv
            self.targetFormat = target
            self.pending = Data()
            self.pendingFrames = 0
        }

        let (stream, cont) = AsyncStream<AudioChunk>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        lock.withLock { self.continuation = cont }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            cont.finish()
            throw Failure.engineStartFailed(error.localizedDescription)
        }

        lock.withLock { isRunning = true }
        log(.audio, "stream started — input \(Int(inputFormat.sampleRate)) Hz × \(inputFormat.channelCount)ch -> 16000 Hz mono int16")
        return stream
    }

    func stop() {
        let cont: AsyncStream<AudioChunk>.Continuation? = lock.withLock {
            guard isRunning else { return nil }
            isRunning = false
            let c = continuation
            continuation = nil
            return c
        }
        guard cont != nil else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        cont?.finish()
        lock.withLock {
            converter = nil
            pending = Data()
            pendingFrames = 0
        }
        log(.audio, "stream stopped")
    }

    // MARK: Tap

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }
        guard let channel = converted.int16ChannelData else { return }

        let frames = Int(converted.frameLength)
        guard frames > 0 else { return }

        let samples = channel[0]
        let byteCount = frames * MemoryLayout<Int16>.size

        // Sum of squares for the level meter / local speech heuristic.
        var sumSquares: Double = 0
        for i in 0..<frames {
            let v = Double(samples[i]) / 32768.0
            sumSquares += v * v
        }
        let rms = Float((sumSquares / Double(frames)).squareRoot())

        let emit: AudioChunk? = lock.withLock {
            pending.append(UnsafeBufferPointer(start: samples, count: frames)
                .withMemoryRebound(to: UInt8.self) { Data($0) })
            _ = byteCount
            pendingFrames += frames

            guard pendingFrames >= minimumFramesPerChunk else { return nil }
            let chunk = AudioChunk(pcm: pending, rms: rms, frameCount: pendingFrames)
            pending = Data()
            pendingFrames = 0
            return chunk
        }

        if let emit {
            continuationSnapshot()?.yield(emit)
        }
    }

    private func continuationSnapshot() -> AsyncStream<AudioChunk>.Continuation? {
        lock.withLock { continuation }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let (conv, target) = lock.withLock { (converter, targetFormat) }
        guard let conv, let target else { return nil }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }

        var supplied = false
        var error: NSError?
        let status = conv.convert(to: out, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            log(.audio, "conversion error: \(error?.localizedDescription ?? "unknown")")
            return nil
        }
        return out.frameLength > 0 ? out : nil
    }
}
