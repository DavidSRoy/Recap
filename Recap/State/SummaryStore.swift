import Foundation
import FoundationModels

final class SummaryStore {
    private let maxWords = 500

    func update(currentSummary: String, newBullets: [String]) async -> String {
        guard !newBullets.isEmpty else { return currentSummary }
        guard case .available = SystemLanguageModel.default.availability else {
            return enforceWordCap(fallback(currentSummary, newBullets))
        }

        let session = LanguageModelSession(instructions: PromptTemplates.systemPrompt)
        let prompt = PromptTemplates.summaryUpdate(summary: currentSummary, bullets: newBullets)

        do {
            let response = try await session.respond(to: prompt)
            let updated = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            print("[SummaryStore] updated summary (\(updated.split(separator: " ").count) words)")
            return enforceWordCap(updated)
        } catch {
            print("[SummaryStore] error: \(error) — falling back to append")
            return enforceWordCap(fallback(currentSummary, newBullets))
        }
    }

    private func fallback(_ current: String, _ bullets: [String]) -> String {
        let appended = bullets.joined(separator: ". ")
        if current.isEmpty { return appended }
        return current + " " + appended
    }

    private func enforceWordCap(_ text: String) -> String {
        let words = text.split(separator: " ")
        guard words.count > maxWords else { return text }

        let sentences = splitSentences(text)
        guard !sentences.isEmpty else {
            return words.suffix(maxWords).joined(separator: " ")
        }

        var kept: [String] = []
        var wordCount = 0
        for sentence in sentences.reversed() {
            let w = sentence.split(separator: " ").count
            if wordCount + w > maxWords { break }
            kept.insert(sentence, at: 0)
            wordCount += w
        }
        if kept.isEmpty {
            return words.suffix(maxWords).joined(separator: " ")
        }
        return kept.joined(separator: " ")
    }

    private func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, _, _, _ in
            if let s = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                sentences.append(s)
            }
        }
        return sentences
    }
}
