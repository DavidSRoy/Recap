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
    private var lastSummarizeMs = 0
    private var isSummarizing = false

    init() {
        logger = MetricsLogger(sessionId: session.sessionId)
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
        bullets = []
        let s = makeStreamer()
        do {
            try s.startMic()
            isRunning = true
            status = "Listening…"
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
        bullets = []
        let s = makeStreamer()
        do {
            try s.startFile(url: url, realtime: realtime)
            isRunning = true
            status = "Playing file…"
        } catch {
            status = "File error: \(error)"
            print("[RecapModel] file error: \(error)")
        }
    }

    func stop() {
        streamer?.stop()
        streamer = nil
        isRunning = false
        status = "Ready"
        lastSummarizeMs = 0
        isSummarizing = false
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
            case .bullets(let newBullets):
                self.bullets.append(contentsOf: newBullets)
            }
            self.isSummarizing = false
        }
    }
}
