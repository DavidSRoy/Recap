import Foundation

final class WindowBuilder {
    private var segments: [Segment] = []
    private let windowMs = 60_000

    func add(_ seg: Segment) {
        segments.append(seg)
    }

    func currentWindow(nowMs: Int) -> (text: String, tokenCount: Int) {
        let cutoff = nowMs - windowMs
        segments = segments.filter { $0.endMs >= cutoff }
        let text = segments.map(\.text).joined(separator: " ")
        return (text, text.split(separator: " ").count)
    }
}
