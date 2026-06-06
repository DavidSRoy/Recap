import Foundation
import AVFoundation
import WhisperKit

final class ASRStreamer {
    var onSegment: ((Segment) -> Void)?
    var logger: MetricsLogger?

    private let acc = AudioSampleAccumulator()
    private var segmentId = 0
    private var processingTask: Task<Void, Never>?
    private var audioEngine: AudioEngineManager?
    private var filePlayer: FilePlayer?

    // 8 s max, 700 ms silence threshold at 16 kHz
    private let maxSamples = 128_000
    private let silenceSamples = 11_200
    private let silenceRMS: Float = 0.015

    // MARK: - Static pre-load

    private static var sharedKit: WhisperKit?
    private static var loadTask: Task<WhisperKit?, Never>?

    /// Call at app launch so the model is warm before first recording.
    static func preload(onStatus: (@MainActor (String) -> Void)? = nil) async {
        if sharedKit != nil { return }

        if let existing = loadTask {
            _ = await existing.value
            return
        }

        let task = Task<WhisperKit?, Never> {
            let modelName = WhisperKit.recommendedModels().default
            await onStatus?("Loading \(modelName)…")
            print("[ASRStreamer] loading \(modelName)")
            do {
                let kit = try await WhisperKit(model: modelName, verbose: false)
                print("[ASRStreamer] model ready")
                await onStatus?("Ready")
                return kit
            } catch {
                print("[ASRStreamer] load error: \(error)")
                await onStatus?("Model load failed — check console")
                return nil
            }
        }
        loadTask = task
        sharedKit = await task.value
    }

    // MARK: - Public interface

    func startMic() throws {
        acc.reset(startMs: nowMs())
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
        acc.reset(startMs: nowMs())
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
        processingTask?.cancel()
        audioEngine?.stop()
        filePlayer?.stop()
        print("[ASRStreamer] stopped")
    }

    // MARK: - Processing loop

    private func run() async {
        // Use pre-loaded kit, or load now as fallback
        let wk: WhisperKit
        if let cached = Self.sharedKit {
            wk = cached
        } else {
            print("[ASRStreamer] model not pre-loaded, loading now…")
            await Self.preload()
            guard let loaded = Self.sharedKit else {
                print("[ASRStreamer] no model available — aborting")
                return
            }
            wk = loaded
        }

        print("[ASRStreamer] processing loop started")
        while !Task.isCancelled {
            await checkAndEmit(wk: wk)
            try? await Task.sleep(nanoseconds: 50_000_000)  // poll every 50 ms
        }

        // flush remainder on stop
        let (tail, startMs) = acc.drain()
        if !tail.isEmpty { await transcribeAndEmit(tail, startMs: startMs, wk: wk) }
    }

    private func checkAndEmit(wk: WhisperKit) async {
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
            await transcribeAndEmit(samples, startMs: startMs, wk: wk)
        }
    }

    private func transcribeAndEmit(_ samples: [Float], startMs: Int, wk: WhisperKit) async {
        guard !samples.isEmpty else { return }
        print("[ASRStreamer] transcribing \(samples.count) samples (\(samples.count/16000)s)")
        do {
            let results = try await wk.transcribe(audioArray: samples)
            let text = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                print("[ASRStreamer] empty transcription")
                return
            }

            let endMs = nowMs()
            let id = segmentId
            segmentId += 1
            print("[ASRStreamer] segment \(id): \(text.prefix(60))")

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
