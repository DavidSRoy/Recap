import Foundation
import AVFoundation
import WhisperKit

final class ASRStreamer {
    var onSegment: ((Segment) -> Void)?
    var logger: MetricsLogger?

    private let acc = AudioSampleAccumulator()
    private var segmentId = 0
    private var whisperKit: WhisperKit?
    private var processingTask: Task<Void, Never>?
    private var audioEngine: AudioEngineManager?
    private var filePlayer: FilePlayer?

    // 8 s max, 700 ms silence threshold at 16 kHz
    private let maxSamples = 128_000
    private let silenceSamples = 11_200
    private let silenceRMS: Float = 0.015

    func startMic() throws {
        acc.reset(startMs: nowMs())
        let engine = AudioEngineManager()
        let acc = self.acc
        engine.onSamples = { samples in acc.append(samples) }
        audioEngine = engine
        processingTask = Task { [weak self] in await self?.run() }
        try engine.startCapture()
        logger?.log("audio_start")
    }

    func startFile(url: URL, realtime: Bool) throws {
        acc.reset(startMs: nowMs())
        let player = FilePlayer()
        let acc = self.acc
        player.onSamples = { samples in acc.append(samples) }
        filePlayer = player
        processingTask = Task { [weak self] in await self?.run() }
        try player.play(url: url, realtime: realtime)
        logger?.log("audio_start")
    }

    func stop() {
        processingTask?.cancel()
        audioEngine?.stop()
        filePlayer?.stop()
    }

    // MARK: - Processing loop

    private func run() async {
        do {
            whisperKit = try await WhisperKit(model: "openai_whisper-tiny.en")
        } catch {
            print("[ASRStreamer] WhisperKit load failed: \(error)")
            return
        }

        while !Task.isCancelled {
            await checkAndEmit()
            try? await Task.sleep(nanoseconds: 50_000_000)  // poll every 50 ms
        }

        // flush remainder on stop
        let (tail, startMs) = acc.drain()
        if !tail.isEmpty { await transcribeAndEmit(tail, startMs: startMs) }
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
        guard let wk = whisperKit, !samples.isEmpty else { return }
        do {
            let results = try await wk.transcribe(audioArray: samples)
            guard let first = results.first else { return }
            let text = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }

            let endMs = nowMs()
            let id = segmentId
            segmentId += 1

            logger?.log("segment_end", [
                "segment_id": id,
                "start_ms": startMs,
                "end_ms": endMs,
                "text": text
            ])

            let seg = Segment(id: id, startMs: startMs, endMs: endMs, text: text, isFinal: true)
            onSegment?(seg)
        } catch {
            print("[ASRStreamer] transcription error: \(error)")
        }
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
