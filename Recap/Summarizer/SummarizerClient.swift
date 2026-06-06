import Foundation

enum SummarizeResult {
    case keepListening
    case bullets([String])
}

final class SummarizerClient {
    func warmup() async {
        // Day 2: load MLX model and keep context alive
    }

    func summarize(window: String, summary: String, priorBullets: [String]) async -> SummarizeResult {
        // Day 2
        return .keepListening
    }
}
