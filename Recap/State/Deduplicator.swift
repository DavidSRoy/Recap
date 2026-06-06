import Foundation

final class Deduplicator {
    private var recentBullets: [String] = []
    private let windowSize = 5
    private let threshold = 0.8

    func isDuplicate(_ bullet: String) -> Bool {
        // Day 3: Jaccard 3-gram similarity > threshold against recentBullets
        return false
    }

    func record(_ bullet: String) {
        recentBullets.append(bullet)
        if recentBullets.count > windowSize { recentBullets.removeFirst() }
    }
}
