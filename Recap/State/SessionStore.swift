import Foundation

final class SessionStore {
    let sessionId: String
    private let runsDir: URL

    init() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        sessionId = fmt.string(from: Date())

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        runsDir = appSupport.appendingPathComponent("Recap/Runs")
        try? FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
    }

    struct Snapshot: Codable {
        let sessionId: String
        let savedAt: String
        let segments: [Segment]
        let bullets: [String]
        let summary: String
    }

    func save(segments: [Segment], bullets: [String], summary: String) {
        let snapshot = Snapshot(
            sessionId: sessionId,
            savedAt: ISO8601DateFormatter().string(from: Date()),
            segments: segments,
            bullets: bullets,
            summary: summary
        )
        let url = runsDir.appendingPathComponent("session_\(sessionId).json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
            print("[SessionStore] wrote \(url.path)")
        } catch {
            print("[SessionStore] write error: \(error)")
        }
    }
}
