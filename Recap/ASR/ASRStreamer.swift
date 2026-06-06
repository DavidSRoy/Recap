import Foundation
import AVFoundation
import Speech

final class ASRStreamer {
    var onSegment: ((Segment) -> Void)?
    var logger: MetricsLogger?

    private let acc = AudioSampleAccumulator()
    private static var nextSegmentId = 0
    private var processingTask: Task<Void, Never>?
    private var audioEngine: AudioEngineManager?
    private var filePlayer: FilePlayer?
    private var shouldStop = false
    private var recognizer: SFSpeechRecognizer?

    // 8 s max, 700 ms silence threshold at 16 kHz
    private let maxSamples = 128_000
    private let silenceSamples = 11_200
    private let silenceRMS: Float = 0.015

    // MARK: - Authorization

    static func requestAuthorization() async {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
        }
    }

    // MARK: - Public interface

    func startMic() throws {
        shouldStop = false
        acc.reset(startMs: nowMs())
        recognizer = SFSpeechRecognizer()
        let engine = AudioEngineManager()
        let acc = self.acc
        engine.onSamples = { samples in acc.append(samples) }
        audioEngine = engine
        processingTask = Task { [weak self] in await self?.run() }
        try engine.startCapture()
        logger?.log("audio_start")
        print("[ASRStreamer] mic started")
    }

    func startFile(url: URL, realtime: Bool) throws {
        shouldStop = false
        acc.reset(startMs: nowMs())
        recognizer = SFSpeechRecognizer()
        let player = FilePlayer()
        let acc = self.acc
        player.onSamples = { samples in acc.append(samples) }
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

    private func run() async {
        print("[ASRStreamer] processing loop started")
        while !shouldStop {
            await checkAndEmit()
            guard !shouldStop else { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let (tail, startMs) = acc.drain()
        if !tail.isEmpty {
            print("[ASRStreamer] flushing \(tail.count) samples on stop")
            await transcribeAndEmit(tail, startMs: startMs)
        }
        print("[ASRStreamer] processing loop exited")
    }

    private func checkAndEmit() async {
        let count = acc.count
        guard count > 0 else { return }

        let shouldEmit: Bool
        if count >= maxSamples {
            shouldEmit = true
        } else if count >= silenceSamples {
            let snap = acc.peek()
            let tail = snap.suffix(silenceSamples)
            let sumSq = tail.reduce(Float(0)) { $0 + $1 * $1 }
            let rms = sqrt(sumSq / Float(tail.count))
            shouldEmit = rms < silenceRMS
        } else {
            shouldEmit = false
        }

        if shouldEmit {
            let (samples, startMs) = acc.drain()
            await transcribeAndEmit(samples, startMs: startMs)
        }
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

// Lock-protected accumulator: written from audio thread, read from @MainActor task.
private final class AudioSampleAccumulator: @unchecked Sendable {
    private var buffer = ContiguousArray<Float>()
    private var segStartMs = 0
    private let lock = NSLock()

    func reset(startMs: Int) {
        lock.withLock { buffer.removeAll(keepingCapacity: true); segStartMs = startMs }
    }

    func append(_ samples: [Float]) {
        lock.withLock { buffer.append(contentsOf: samples) }
    }

    func peek() -> [Float] {
        lock.withLock { Array(buffer) }
    }

    func drain() -> ([Float], Int) {
        lock.withLock {
            let result = (Array(buffer), segStartMs)
            buffer.removeAll(keepingCapacity: true)
            segStartMs = nowMs()
            return result
        }
    }

    var count: Int { lock.withLock { buffer.count } }

    private func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }
}
