import Foundation

enum PromptTemplates {
    static let systemPrompt = "You are Recap, a meeting summarizer. Return structured output only."

    static func planner(summary: String, window: String, lastBullets: [String]) -> String {
        """
        Long summary: \(summary.isEmpty ? "(none yet)" : summary)
        Recent transcript: \(window)
        Prior bullets: \(lastBullets.isEmpty ? "(none)" : lastBullets.joined(separator: "; "))
        Extract up to 3 concise bullet points covering new key ideas not already in the summary or prior bullets. Return empty bullets only if the transcript is noise or silence.
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
