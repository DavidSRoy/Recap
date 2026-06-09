import Darwin
import Foundation

final class RSSSampler {
    private var timer: Timer?
    private let logger: MetricsLogger
    private let intervalMs = 200

    init(logger: MetricsLogger) {
        self.logger = logger
    }

    func start() {
        stop()
        let t = Timer(timeInterval: TimeInterval(intervalMs) / 1000.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let rss = Self.residentMemoryMB()
            self.logger.log("rss_sample", ["rss_mb": rss])
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private static func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        let infoSize = MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(infoSize)
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: infoSize) { reboundPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1024.0 / 1024.0
    }
}
