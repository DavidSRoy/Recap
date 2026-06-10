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
    private var currentRequest: SFSpeechAudioBufferRecognitionRequest?
    private var currentTask: SFSpeechRecognitionTask?

    private let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    // Feed audio to the recognizer in 250 ms chunks so it always has fresh frames.
    private let feedFrameChunk = 4_000
    // Detect a "segment boundary" when two consecutive recognized words have at least this much pause between them.
    private let pauseThresholdSeconds: TimeInterval = 0.7

    // Mutated under stateLock.
    private let stateLock = NSLock()
    private var lastEmittedWordIndex = 0
    private var segStartMs = 0
    private var recognizerSessionStartMs = 0

    private let drainScratch: UnsafeMutablePointer<Float>

    init(bridge: EngineBridge) {
        self.bridge = bridge
        self.drainScratch = UnsafeMutablePointer<Float>.allocate(capacity: feedFrameChunk)
    }

    deinit { drainScratch.deallocate() }

    // MARK: - Authorization

    static func requestAuthorization() async {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
        }
    }

    // MARK: - Public interface

    func startMic() throws {
        try prepareForStart()
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
        try prepareForStart()
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

    private func prepareForStart() throws {
        shouldStop = false
        bridge.clear()
        recognizer = SFSpeechRecognizer()
        let now = nowMs()
        stateLock.withLock {
            segStartMs = now
            recognizerSessionStartMs = now
            lastEmittedWordIndex = 0
        }
        try startRecognitionRequest()
    }

    private func startRecognitionRequest() throws {
        guard let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        if #available(macOS 13.0, *) { req.addsPunctuation = true }

        let task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            self?.handleRecognitionUpdate(result: result, error: error)
        }
        currentRequest = req
        currentTask = task
        print("[ASRStreamer] recognition request started")
    }

    private func run() async {
        print("[ASRStreamer] processing loop started")
        while !shouldStop {
            feedAudioIfAvailable()
            guard !shouldStop else { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // Drain any remaining audio after stop.
        feedAudioIfAvailable(drain: true)
        currentRequest?.endAudio()
        // Give the recognizer ~250 ms to finalise the tail.
        try? await Task.sleep(nanoseconds: 250_000_000)
        currentRequest = nil
        currentTask = nil
        print("[ASRStreamer] processing loop exited")
    }

    private func feedAudioIfAvailable(drain: Bool = false) {
        guard let req = currentRequest else { return }
        while true {
            let count = Int(bridge.frameCount())
            if count == 0 { return }
            if !drain && count < feedFrameChunk { return }
            let toRead = min(count, feedFrameChunk)
            let copied = Int(bridge.popPCM(drainScratch, maxCount: UInt(toRead)))
            guard copied > 0 else { return }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(copied)) else { return }
            buffer.frameLength = AVAudioFrameCount(copied)
            buffer.floatChannelData?[0].initialize(from: drainScratch, count: copied)
            req.append(buffer)
            if !drain { return }
        }
    }

    // MARK: - Recognition callback

    private func handleRecognitionUpdate(result: SFSpeechRecognitionResult?, error: Error?) {
        if let error {
            let ns = error as NSError
            // Code 1110 = "No speech detected" — common during silence, not noteworthy.
            if !(ns.domain == "kAFAssistantErrorDomain" && ns.code == 1110) {
                print("[ASRStreamer] recognition error: \(error)")
            }
            return
        }
        guard let result else { return }
        let words = result.bestTranscription.segments

        var pendingEmits: [[SFTranscriptionSegment]] = []
        stateLock.withLock {
            guard !words.isEmpty else { return }
            guard words.count >= lastEmittedWordIndex else {
                // Recognizer reset (e.g., dropped old segments) — restart counter
                lastEmittedWordIndex = 0
                return
            }

            // Walk from the last emitted index, splitting on pause >= threshold.
            var cursor = lastEmittedWordIndex
            while cursor < words.count {
                var cutEnd = words.count
                if cursor < words.count - 1 {
                    for i in cursor..<(words.count - 1) {
                        let cur = words[i]
                        let next = words[i + 1]
                        let gap = next.timestamp - (cur.timestamp + cur.duration)
                        if gap >= pauseThresholdSeconds {
                            cutEnd = i + 1
                            break
                        }
                    }
                }
                if cutEnd < words.count {
                    pendingEmits.append(Array(words[cursor..<cutEnd]))
                    cursor = cutEnd
                } else if result.isFinal {
                    // No more pauses found and recognizer is wrapping up — emit the tail.
                    pendingEmits.append(Array(words[cursor..<words.count]))
                    cursor = words.count
                } else {
                    break
                }
            }
            lastEmittedWordIndex = cursor
        }

        for emit in pendingEmits {
            emitSegment(words: emit)
        }
    }

    private func emitSegment(words: [SFTranscriptionSegment]) {
        let text = words.map { $0.substring }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Word timestamps are relative to the recognizer session start.
        let firstWordOffsetMs = Int((words.first?.timestamp ?? 0) * 1000)
        let lastWord = words.last!
        let lastWordOffsetMs = Int((lastWord.timestamp + lastWord.duration) * 1000)
        let (sessionStart, _) = stateLock.withLock { (recognizerSessionStartMs, segStartMs) }
        let startMs = sessionStart + firstWordOffsetMs
        let endMs = sessionStart + lastWordOffsetMs

        let id = nextSegmentId()
        print("[ASRStreamer] segment \(id): \(text.prefix(80))")
        logger?.log("segment_end", [
            "segment_id": id,
            "start_ms": startMs,
            "end_ms": endMs,
            "text": text
        ])
        onSegment?(Segment(id: id, startMs: startMs, endMs: endMs, text: text, isFinal: true))
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
