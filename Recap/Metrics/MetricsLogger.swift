import Foundation

final class MetricsLogger: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let queue = DispatchQueue(label: "recap.metrics", qos: .utility)

    // Optional live observer — receives every event on the main actor.
    var onEvent: (@MainActor (String, [String: Any]) -> Void)?

    init(sessionId: String) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let runsDir = appSupport.appendingPathComponent("Recap/Runs")
        try? FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
        let fileURL = runsDir.appendingPathComponent("session_\(sessionId).jsonl")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        fileHandle = (try? FileHandle(forWritingTo: fileURL)) ?? FileHandle.standardError
        fileHandle.seekToEndOfFile()
        print("[MetricsLogger] \(fileURL.path)")
    }

    nonisolated func log(_ event: String, _ payload: [String: Any] = [:]) {
        queue.async { [fileHandle] in
            var dict: [String: Any] = [
                "ts": ISO8601DateFormatter.recap.string(from: Date()),
                "event": event
            ]
            payload.forEach { dict[$0.key] = $0.value }
            guard let data = try? JSONSerialization.data(withJSONObject: dict),
                  let line = String(data: data, encoding: .utf8)
            else { return }
            fileHandle.write(Data((line + "\n").utf8))
        }
        if let onEvent {
            Task { @MainActor in onEvent(event, payload) }
        }
    }

    deinit {
        queue.sync { [fileHandle] in
            try? fileHandle.close()
        }
    }
}

private extension ISO8601DateFormatter {
    static let recap: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
