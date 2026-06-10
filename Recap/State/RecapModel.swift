import Foundation
import Observation

@Observable
final class RecapModel {
    var segments: [Segment] = []
    var bullets: [String] = []
    var summary: String = ""
    var isRunning = false
    var status = "Starting…"

    // Live metrics for the overlay.
    var lastTTFTMs: Int?
    var lastTotalMs: Int?
    var lastTokensIn: Int?
    var lastTokensOut: Int?
    var currentRssMb: Double?

    let logger: MetricsLogger
    private let session = SessionStore()
    private var streamer: ASRStreamer?
    private let windowBuilder = WindowBuilder()
    private let summarizerClient = SummarizerClient()
    private let deduplicator = Deduplicator()
    private let summaryStore = SummaryStore()
    private let bridge: EngineBridge
    private let rssSampler: RSSSampler
    private var lastSummarizeMs = 0
    private var isSummarizing = false
    private var lastPrefillStartMs: [Int: Int] = [:]
    private var lastFirstTokenMs: [Int: Int] = [:]

    init() {
        logger = MetricsLogger(sessionId: session.sessionId)
        // 20 s of 16 kHz mono headroom for the ring buffer.
        bridge = EngineBridge(capacity: 320_000)
        rssSampler = RSSSampler(logger: logger, bridge: bridge)
        Task { [weak self] in
            await ASRStreamer.requestAuthorization()
            await self?.summarizerClient.warmup()
            self?.status = "Ready"
        }
        logger.onEvent = { [weak self] event, payload in
            self?.handleMetricEvent(event, payload: payload)
        }
    }

    @MainActor
    private func handleMetricEvent(_ event: String, payload: [String: Any]) {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        switch event {
        case "rss_sample":
            if let rss = payload["rss_mb"] as? Double { currentRssMb = rss }
        case "prefill_start":
            if let sid = payload["segment_id"] as? Int { lastPrefillStartMs[sid] = now }
        case "first_token":
            if let sid = payload["segment_id"] as? Int, let start = lastPrefillStartMs[sid] {
                lastTTFTMs = now - start
                lastFirstTokenMs[sid] = now
            }
        case "decode_end":
            if let sid = payload["segment_id"] as? Int, let start = lastPrefillStartMs[sid] {
                lastTotalMs = now - start
                lastPrefillStartMs[sid] = nil
                lastFirstTokenMs[sid] = nil
            }
            if let tin = payload["tokens_in"] as? Int { lastTokensIn = tin }
            if let tout = payload["tokens_out"] as? Int { lastTokensOut = tout }
        default:
            break
        }
    }

    func startMic() {
        guard status == "Ready" else {
            print("[RecapModel] not ready: \(status)")
            return
        }
        resetForRun()
        let s = makeStreamer()
        do {
            try s.startMic()
            isRunning = true
            status = "Listening…"
            rssSampler.start()
        } catch {
            status = "Mic error: \(error)"
            print("[RecapModel] mic error: \(error)")
        }
    }

    func startFile(url: URL, realtime: Bool = true) {
        guard status == "Ready" else {
            print("[RecapModel] not ready: \(status)")
            return
        }
        resetForRun()
        let s = makeStreamer()
        do {
            try s.startFile(url: url, realtime: realtime)
            isRunning = true
            status = "Playing file…"
            rssSampler.start()
        } catch {
            status = "File error: \(error)"
            print("[RecapModel] file error: \(error)")
        }
    }

    func stop() {
        streamer?.stop()
        streamer = nil
        rssSampler.stop()
        session.save(segments: segments, bullets: bullets, summary: summary)
        isRunning = false
        status = "Ready"
        lastSummarizeMs = 0
        isSummarizing = false
    }

    private func resetForRun() {
        bullets = []
        summary = ""
        deduplicator.reset()
        Task { await summaryStore.reset() }
    }

    private func makeStreamer() -> ASRStreamer {
        let s = ASRStreamer(bridge: bridge)
        s.logger = logger
        s.onSegment = { [weak self] seg in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.segments.append(seg)
                self.windowBuilder.add(seg)
                self.maybeSummarize(segmentId: seg.id)
            }
        }
        streamer = s
        return s
    }

    private func maybeSummarize(segmentId: Int) {
        guard !isSummarizing else { return }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        guard nowMs - lastSummarizeMs >= 60_000 else { return }
        let (text, wordCount) = windowBuilder.currentWindow(nowMs: nowMs)
        guard wordCount >= 20 else { return }

        lastSummarizeMs = nowMs
        isSummarizing = true

        let priorBullets = Array(bullets.suffix(5))

        Task { [weak self] in
            guard let self else { return }
            let result = await self.summarizerClient.summarize(
                window: text,
                summary: await self.summaryStore.current,
                priorBullets: priorBullets,
                segmentId: segmentId,
                logger: self.logger
            )
            switch result {
            case .keepListening:
                await MainActor.run { self.isSummarizing = false }
            case .refused:
                // Safety filter fired — reset timer so next segment retries immediately
                await MainActor.run {
                    self.lastSummarizeMs = 0
                    self.isSummarizing = false
                }
            case .bullets(let newBullets, _, _):
                let kept = newBullets.filter { !self.deduplicator.isDuplicate($0) }
                kept.forEach { self.deduplicator.record($0) }
                let dropped = newBullets.count - kept.count
                if dropped > 0 {
                    self.logger.log("dedup_dropped", [
                        "segment_id": segmentId,
                        "dropped": dropped,
                        "kept": kept.count
                    ])
                }
                if kept.isEmpty {
                    await MainActor.run { self.isSummarizing = false }
                    return
                }
                // Unlock immediately — summary update runs in parallel via actor serialization.
                await MainActor.run {
                    self.bullets.append(contentsOf: kept)
                    self.status = self.isRunning ? "Listening…" : "Ready"
                    self.isSummarizing = false
                }
                Task { [weak self] in
                    guard let self else { return }
                    await self.summaryStore.update(newBullets: kept, logger: self.logger)
                    let updated = await self.summaryStore.current
                    await MainActor.run { self.summary = updated }
                }
            }
        }
    }
}
