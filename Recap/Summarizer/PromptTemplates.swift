import Foundation

enum PromptTemplates {
    static let systemPrompt = "You are Recap, a podcast and meeting transcription assistant. Transcripts may include news, business, or current-events discussions. Your only task is to extract factual bullet-point summaries of the spoken content. Return structured output only."

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
        Write a concise flowing prose summary of the conversation so far. Integrate the new bullets into the existing summary, removing redundancy. Keep it under 500 words.
        Do NOT use Markdown headers, bold, bullet points, or section labels. Do NOT include placeholders like "[Insert Date]" or "[Insert Name]". Do NOT invent participants, agendas, locations, or times that were not actually mentioned. If only a small amount of content exists, write only a short paragraph — do not pad with structure.
        Current summary: \(summary.isEmpty ? "(none yet)" : summary)
        New bullets:
        \(bullets.map { "- \($0)" }.joined(separator: "\n"))
        Updated summary (plain prose only):
        """
    }
}
