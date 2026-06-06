import Combine
import Foundation

@MainActor
final class SummaryStore: ObservableObject {
    @Published private(set) var summary: String = ""
    private let maxWords = 500

    func update(with bullets: [String]) async {
        // Day 3: call SummarizerClient.summarize for summary update prompt
    }
}
