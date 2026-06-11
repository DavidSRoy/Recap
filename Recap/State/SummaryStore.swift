import Foundation
import FoundationModels

actor SummaryStore {
    private(set) var current: String = ""
    private let maxWords = 200

    func reset() { current = "" }

    // Integrates newBullets into the running summary. Actor serializes concurrent callers
    // so back-to-back window cycles never race on the underlying text.
    func update(newBullets: [String], logger: MetricsLogger?) async {
        guard !newBullets.isEmpty else { return }
        guard case .available = SystemLanguageModel.default.availability else {
            current = enforceWordCap(fallback(current, newBullets))
            logUpdate(logger, durationMs: 0, tokensIn: 0)
            return
        }

        let session = LanguageModelSession(instructions: PromptTemplates.systemPrompt)
        let prompt = PromptTemplates.summaryUpdate(summary: current, bullets: newBullets)
        let startMs = nowMs()

        do {
            let response = try await session.respond(to: prompt)
            let updated = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            current = enforceWordCap(updated)
        } catch {
            print("[SummaryStore] error: \(error) — falling back to append")
            current = enforceWordCap(fallback(current, newBullets))
        }
        logUpdate(logger, durationMs: nowMs() - startMs, tokensIn: prompt.split(separator: " ").count)
    }

    private func logUpdate(_ logger: MetricsLogger?, durationMs: Int, tokensIn: Int) {
        let words = current.split(separator: " ").count
        logger?.log("summary_update", ["words": words, "duration_ms": durationMs, "tokens_in": tokensIn])
        print("[SummaryStore] updated summary (\(words) words, \(durationMs)ms)")
    }

    private func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    private func fallback(_ current: String, _ bullets: [String]) -> String {
        let appended = bullets.joined(separator: ". ")
        return current.isEmpty ? appended : current + " " + appended
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
