import Foundation

final class RSSSampler {
    private var timer: Timer?
    private let logger: MetricsLogger
    private let bridge: EngineBridge
    private let intervalMs = 200

    init(logger: MetricsLogger, bridge: EngineBridge) {
        self.logger = logger
        self.bridge = bridge
    }

    func start() {
        stop()
        let t = Timer(timeInterval: TimeInterval(intervalMs) / 1000.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let rss = self.bridge.rssMb()
            self.logger.log("rss_sample", ["rss_mb": rss])
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
