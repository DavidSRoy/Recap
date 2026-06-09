import Foundation

final class Deduplicator {
    private var recentBullets: [String] = []
    private let windowSize = 5
    private let threshold = 0.8

    func isDuplicate(_ bullet: String) -> Bool {
        let grams = Self.trigrams(bullet)
        guard !grams.isEmpty else { return false }
        for prior in recentBullets {
            let priorGrams = Self.trigrams(prior)
            guard !priorGrams.isEmpty else { continue }
            let intersection = grams.intersection(priorGrams).count
            let union = grams.union(priorGrams).count
            if union == 0 { continue }
            let jaccard = Double(intersection) / Double(union)
            if jaccard > threshold { return true }
        }
        return false
    }

    func record(_ bullet: String) {
        recentBullets.append(bullet)
        if recentBullets.count > windowSize { recentBullets.removeFirst() }
    }

    func reset() {
        recentBullets.removeAll()
    }

    private static func trigrams(_ text: String) -> Set<String> {
        let normalized = text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " "
        }
        let chars = Array(String(String.UnicodeScalarView(normalized)))
        guard chars.count >= 3 else { return [] }
        var grams = Set<String>()
        grams.reserveCapacity(chars.count - 2)
        for i in 0...(chars.count - 3) {
            grams.insert(String(chars[i..<i+3]))
        }
        return grams
    }
}
