import SwiftUI

@main
struct RecapApp: App {
    private let session: SessionStore
    private let logger: MetricsLogger

    init() {
        let s = SessionStore()
        session = s
        logger = MetricsLogger(sessionId: s.sessionId)
        logger.log("app_start")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
