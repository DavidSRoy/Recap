import Foundation

enum PromptTemplates {
    static let systemPrompt = "You are Recap, a meeting summarizer. Return structured output only."

    static func planner(summary: String, window: String, lastBullets: [String]) -> String {
        """
        Long summary (<=500 words): \(summary.isEmpty ? "(none yet)" : summary)
        Recent 60s transcript: \(window)
        Prior bullets: \(lastBullets.isEmpty ? "(none)" : lastBullets.joined(separator: "; "))
        Rules: Set keepListening=true if no new idea beyond the summary and prior bullets. \
        Otherwise set keepListening=false and provide 1–3 concise bullets.
        """
    }

    static func summaryUpdate(summary: String, bullets: [String]) -> String {
        """
        Update the session summary to at most 500 words. Preserve decisions, action items, and open questions. Remove redundancy.
        Current summary: \(summary)
        New bullets: \(bullets.map { "- \($0)" }.joined(separator: "\n"))
        """
    }
}
