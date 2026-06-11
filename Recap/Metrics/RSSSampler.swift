import Foundation

final class RSSSampler {
    private var timer: Timer?
    private let logger: MetricsLogger
    private let bridge: EngineBridge
    private let intervalMs = 200

    // Optional hook so callers can inject in-memory counts without coupling RSSSampler to RecapModel.
    var extraMetrics: (() -> [String: Any])?

    init(logger: MetricsLogger, bridge: EngineBridge) {
        self.logger = logger
        self.bridge = bridge
    }

    func start() {
        stop()
        let t = Timer(timeInterval: TimeInterval(intervalMs) / 1000.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let rss = self.bridge.rssMb()
            var payload: [String: Any] = ["rss_mb": rss]
            if let extra = self.extraMetrics?() { payload.merge(extra) { _, new in new } }
            self.logger.log("rss_sample", payload)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
