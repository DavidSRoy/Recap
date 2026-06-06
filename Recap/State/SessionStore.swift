import Foundation

final class SessionStore {
    let sessionId: String

    init() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        sessionId = fmt.string(from: Date())
    }

    func save() {
        // Day 3: write session.json on stop
    }
}
