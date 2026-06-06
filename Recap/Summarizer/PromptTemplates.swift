import Foundation

enum PromptTemplates {
    static func planner(summary: String, window: String, lastBullets: [String]) -> String {
        """
        System: You are Recap. Output either KEEP_LISTENING or 1-3 concise bullets. No preamble.
        Long summary (<=500 words): \(summary)
        Recent 60s transcript: \(window)
        Prior bullets: \(lastBullets.joined(separator: "; "))
        Rules: Do not repeat prior bullets. If no new idea, output exactly KEEP_LISTENING.
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
