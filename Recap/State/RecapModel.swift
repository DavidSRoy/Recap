import Foundation
import Observation

@Observable
final class RecapModel {
    var segments: [Segment] = []
    var bullets: [String] = []
    var summary: String = ""
    var isRunning = false

    let logger: MetricsLogger
    private let session = SessionStore()
    private var streamer: ASRStreamer?

    init() {
        logger = MetricsLogger(sessionId: session.sessionId)
    }

    func startMic() {
        let s = makeStreamer()
        do {
            try s.startMic()
            isRunning = true
        } catch {
            print("[RecapModel] mic error: \(error)")
        }
    }

    func startFile(url: URL, realtime: Bool = true) {
        let s = makeStreamer()
        do {
            try s.startFile(url: url, realtime: realtime)
            isRunning = true
        } catch {
            print("[RecapModel] file error: \(error)")
        }
    }

    func stop() {
        streamer?.stop()
        streamer = nil
        isRunning = false
    }

    private func makeStreamer() -> ASRStreamer {
        let s = ASRStreamer()
        s.logger = logger
        s.onSegment = { [weak self] seg in self?.segments.append(seg) }
        streamer = s
        return s
    }
}
