import Foundation
import AVFoundation
import Speech

final class ASRStreamer {
    var onSegment: ((Segment) -> Void)?
    var logger: MetricsLogger?

    private let bridge: EngineBridge
    private static var nextSegmentId = 0
    private static let segmentIdLock = NSLock()
    private var processingTask: Task<Void, Never>?
    private var audioEngine: AudioEngineManager?
    private var filePlayer: FilePlayer?
    private var shouldStop = false
    private var recognizer: SFSpeechRecognizer?

    private let stateLock = NSLock()
    private var segStartMs = 0

    // Require ≥2 s buffered AND ≥1.5 s of trailing silence before emitting a chunk.
    // Hard cap at 8 s regardless. On max-cap drains, leave a small acoustic-context
    // overlap so the next chunk doesn't begin mid-utterance (SFSpeechRecognizer's
    // VAD drops leading audio when a buffer starts with no onset).
    private let maxSamples   = 128_000   // 8 s at 16 kHz
    private let minEmitSamples = 32_000  // 2 s
    private let silenceSamples = 24_000  // 1.5 s
    private let overlapSamples = 6_400   // 400 ms
    private let silenceRMS: Float = 0.01

    private let drainScratch: UnsafeMutablePointer<Float>
    private let peekScratch: UnsafeMutablePointer<Float>

    init(bridge: EngineBridge) {
        self.bridge = bridge
        drainScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxSamples)
        peekScratch  = UnsafeMutablePointer<Float>.allocate(capacity: silenceSamples)
    }

    deinit {
        drainScratch.deallocate()
        peekScratch.deallocate()
    }

    // MARK: - Authorization

    static func requestAuthorization() async {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
        }
    }

    // MARK: - Public interface

    func startMic() throws {
        prepareForStart()
        let engine = AudioEngineManager()
        let bridge = self.bridge
        engine.onSamples = { samples in
            samples.withUnsafeBufferPointer { ptr in
                bridge.pushPCM(ptr.baseAddress!, count: UInt(samples.count))
            }
        }
        audioEngine = engine
        processingTask = Task { [weak self] in await self?.run() }
        try engine.startCapture()
        logger?.log("audio_start")
        print("[ASRStreamer] mic started")
    }

    func startFile(url: URL, realtime: Bool) throws {
        prepareForStart()
        let player = FilePlayer()
        let bridge = self.bridge
        player.onSamples = { samples in
            samples.withUnsafeBufferPointer { ptr in
                bridge.pushPCM(ptr.baseAddress!, count: UInt(samples.count))
            }
        }
        filePlayer = player
        processingTask = Task { [weak self] in await self?.run() }
        try player.play(url: url, realtime: realtime)
        logger?.log("audio_start")
        print("[ASRStreamer] file started: \(url.lastPathComponent)")
    }

    func stop() {
        shouldStop = true
        audioEngine?.stop()
        filePlayer?.stop()
        print("[ASRStreamer] stop requested")
    }

    // MARK: - Lifecycle

    private func prepareForStart() {
        shouldStop = false
        bridge.clear()
        recognizer = SFSpeechRecognizer()
        stateLock.withLock { segStartMs = nowMs() }
    }

    private func run() async {
        print("[ASRStreamer] processing loop started")
        while !shouldStop {
            await checkAndEmit()
            guard !shouldStop else { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let (tail, startMs) = drain()
        if !tail.isEmpty {
            print("[ASRStreamer] flushing \(tail.count) samples on stop")
            await transcribeAndEmit(tail, startMs: startMs)
        }
        print("[ASRStreamer] processing loop exited")
    }

    private func checkAndEmit() async {
        let count = Int(bridge.frameCount())
        guard count > 0 else { return }

        let hitMaxCap: Bool
        let shouldEmit: Bool
        if count >= maxSamples {
            hitMaxCap = true
            shouldEmit = true
        } else if count >= minEmitSamples {
            let copied = Int(bridge.peekTail(peekScratch, maxCount: UInt(silenceSamples)))
            guard copied > 0 else { return }
            var sumSq: Float = 0
            for i in 0..<copied { let s = peekScratch[i]; sumSq += s * s }
            let rms = sqrt(sumSq / Float(copied))
            hitMaxCap = false
            shouldEmit = rms < silenceRMS
        } else {
            hitMaxCap = false
            shouldEmit = false
        }

        if shouldEmit {
            let (samples, startMs) = drain(leaveOverlap: hitMaxCap)
            await transcribeAndEmit(samples, startMs: startMs)
        }
    }

    private func drain(leaveOverlap: Bool = false) -> ([Float], Int) {
        let startMs = stateLock.withLock { segStartMs }
        let maxPop = leaveOverlap ? maxSamples - overlapSamples : maxSamples
        let copied = Int(bridge.popPCM(drainScratch, maxCount: UInt(maxPop)))
        let samples = Array(UnsafeBufferPointer(start: drainScratch, count: copied))
        let overlapMs = leaveOverlap ? (overlapSamples * 1000 / 16_000) : 0
        stateLock.withLock { segStartMs = nowMs() - overlapMs }
        return (samples, startMs)
    }

    private func transcribeAndEmit(_ samples: [Float], startMs: Int) async {
        guard !samples.isEmpty, let recognizer else { return }
        print("[ASRStreamer] transcribing \(samples.count) samples (\(samples.count / 16_000)s)")

        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            buffer.floatChannelData?[0].initialize(from: ptr.baseAddress!, count: samples.count)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.append(buffer)
        request.endAudio()

        let text = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            var done = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !done else { return }
                if let error {
                    let ns = error as NSError
                    if !(ns.domain == "kAFAssistantErrorDomain" && ns.code == 1110) {
                        print("[ASRStreamer] recognition error: \(error)")
                    }
                    done = true
                    continuation.resume(returning: "")
                } else if let result, result.isFinal {
                    done = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            print("[ASRStreamer] empty transcription result")
            return
        }

        let endMs = nowMs()
        let id = nextSegmentId()
        print("[ASRStreamer] segment \(id): \(trimmed.prefix(80))")
        logger?.log("segment_end", [
            "segment_id": id,
            "start_ms": startMs,
            "end_ms": endMs,
            "text": trimmed
        ])
        onSegment?(Segment(id: id, startMs: startMs, endMs: endMs, text: trimmed, isFinal: true))
    }

    // MARK: - Helpers

    private func nextSegmentId() -> Int {
        Self.segmentIdLock.withLock {
            let id = Self.nextSegmentId
            Self.nextSegmentId += 1
            return id
        }
    }

    private func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }
}
