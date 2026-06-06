import Foundation

final class RSSSampler {
    private var timer: Timer?
    private let logger: MetricsLogger

    init(logger: MetricsLogger) {
        self.logger = logger
    }

    func start() {
        // Day 3: sample every 200 ms via EngineBridge.rssMb()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
