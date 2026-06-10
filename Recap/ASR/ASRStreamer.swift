import Foundation
import AVFoundation
import Speech

final class ASRStreamer {
    var onSegment: ((Segment) -> Void)?
    var logger: MetricsLogger?

    private let bridge: EngineBridge
    private let maxFrames = 128_000        // 8 s buffer cap matches maxSamples
    private static var nextSegmentId = 0
    private var processingTask: Task<Void, Never>?
    private var audioEngine: AudioEngineManager?
    private var filePlayer: FilePlayer?
    private var shouldStop = false
    private var recognizer: SFSpeechRecognizer?
    private var segStartMs = 0
    private let segStartLock = NSLock()

    // Pre-allocated drain/peek scratch buffers — avoid hot-path allocation.
    private let drainScratch: UnsafeMutablePointer<Float>
    private let peekScratch: UnsafeMutablePointer<Float>

    // 8 s max chunk; require ≥2 s buffered AND ≥1.5 s of trailing silence before chunking.
    // Tight earlier thresholds were chopping podcast audio into 0.7 s blobs that
    // SFSpeechRecognizer couldn't transcribe coherently.
    private let maxSamples = 128_000        // 8 s
    private let minEmitSamples = 32_000     // 2 s — don't emit shorter than this on silence
    private let silenceSamples = 24_000     // 1.5 s — trailing-silence window
    private let silenceRMS: Float = 0.01

    init(bridge: EngineBridge) {
        self.bridge = bridge
        self.drainScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
        self.peekScratch = UnsafeMutablePointer<Float>.allocate(capacity: 24_000)
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
        shouldStop = false
        resetBuffer()
        recognizer = SFSpeechRecognizer()
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
        shouldStop = false
        resetBuffer()
        recognizer = SFSpeechRecognizer()
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

    // MARK: - Processing loop

    private func resetBuffer() {
        bridge.clear()
        setSegStartMs(nowMs())
    }

    private func setSegStartMs(_ value: Int) {
        segStartLock.withLock { segStartMs = value }
    }

    private func readSegStartMs() -> Int {
        segStartLock.withLock { segStartMs }
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

        let shouldEmit: Bool
        if count >= maxSamples {
            shouldEmit = true
        } else if count >= minEmitSamples {
            let copied = Int(bridge.peekTail(peekScratch, maxCount: UInt(silenceSamples)))
            guard copied > 0 else { return }
            var sumSq: Float = 0
            for i in 0..<copied {
                let s = peekScratch[i]
                sumSq += s * s
            }
            let rms = sqrt(sumSq / Float(copied))
            shouldEmit = rms < silenceRMS
        } else {
            shouldEmit = false
        }

        if shouldEmit {
            let (samples, startMs) = drain()
            await transcribeAndEmit(samples, startMs: startMs)
        }
    }

    private func drain() -> ([Float], Int) {
        let startMs = readSegStartMs()
        let copied = Int(bridge.popPCM(drainScratch, maxCount: UInt(maxFrames)))
        let samples = Array(UnsafeBufferPointer(start: drainScratch, count: copied))
        setSegStartMs(nowMs())
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
                    print("[ASRStreamer] recognition error: \(error)")
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
        let id = Self.nextSegmentId
        Self.nextSegmentId += 1
        print("[ASRStreamer] segment \(id): \(trimmed.prefix(80))")

        logger?.log("segment_end", [
            "segment_id": id,
            "start_ms": startMs,
            "end_ms": endMs,
            "text": trimmed
        ])

        let seg = Segment(id: id, startMs: startMs, endMs: endMs, text: trimmed, isFinal: true)
        onSegment?(seg)
    }

    private func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }
}
