import Foundation
import Observation

@Observable
final class RecapModel {
    var segments: [Segment] = []
    var bullets: [String] = []
    var summary: String = ""
    var isRunning = false
    var status = "Loading model…"

    let logger: MetricsLogger
    private let session = SessionStore()
    private var streamer: ASRStreamer?

    init() {
        logger = MetricsLogger(sessionId: session.sessionId)
        // Pre-load WhisperKit so it's ready before the user hits Start.
        Task { [weak self] in
            await ASRStreamer.preload { @MainActor [weak self] msg in
                self?.status = msg
            }
        }
    }

    func startMic() {
        guard status == "Ready" else {
            print("[RecapModel] model not ready yet: \(status)")
            return
        }
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
            print("[RecapModel] model not ready yet: \(status)")
            return
        }
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
    }

    private func makeStreamer() -> ASRStreamer {
        let s = ASRStreamer()
        s.logger = logger
        s.onSegment = { [weak self] seg in self?.segments.append(seg) }
        streamer = s
        return s
    }
}
