import Foundation
import Observation

@Observable
final class RecapModel {
    var segments: [Segment] = []
    var bullets: [String] = []
    var summary: String = ""
    var isRunning = false
    var status = "Starting…"

    let logger: MetricsLogger
    private let session = SessionStore()
    private var streamer: ASRStreamer?
    private let windowBuilder = WindowBuilder()
    private let summarizerClient = SummarizerClient()
    private let deduplicator = Deduplicator()
    private let summaryStore = SummaryStore()
    private let rssSampler: RSSSampler
    private var lastSummarizeMs = 0
    private var isSummarizing = false

    init() {
        logger = MetricsLogger(sessionId: session.sessionId)
        rssSampler = RSSSampler(logger: logger)
        Task { [weak self] in
            await ASRStreamer.requestAuthorization()
            await self?.summarizerClient.warmup()
            self?.status = "Ready"
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
    }

    private func makeStreamer() -> ASRStreamer {
        let s = ASRStreamer()
        s.logger = logger
        s.onSegment = { [weak self] seg in
            guard let self else { return }
            self.segments.append(seg)
            self.windowBuilder.add(seg)
            self.maybeSummarize(segmentId: seg.id)
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

        let currentSummary = summary
        let priorBullets = Array(bullets.suffix(5))

        Task { [weak self] in
            guard let self else { return }
            let result = await self.summarizerClient.summarize(
                window: text,
                summary: currentSummary,
                priorBullets: priorBullets,
                segmentId: segmentId,
                logger: self.logger
            )
            switch result {
            case .keepListening:
                break
            case .refused:
                // Safety filter fired — reset timer so next segment retries immediately
                self.lastSummarizeMs = 0
            case .bullets(let newBullets):
                let kept = newBullets.filter { !self.deduplicator.isDuplicate($0) }
                kept.forEach { self.deduplicator.record($0) }
                if !kept.isEmpty {
                    self.bullets.append(contentsOf: kept)
                    let updated = await self.summaryStore.update(
                        currentSummary: self.summary,
                        newBullets: kept
                    )
                    self.summary = updated
                }
                let dropped = newBullets.count - kept.count
                if dropped > 0 {
                    self.logger.log("dedup_dropped", [
                        "segment_id": segmentId,
                        "dropped": dropped,
                        "kept": kept.count
                    ])
                }
            }
            self.isSummarizing = false
        }
    }
}
