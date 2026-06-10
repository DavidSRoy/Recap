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
        Write a third-person prose summary describing what the speaker is discussing. Use only facts that appear in the bullets and the current summary — do NOT add background, audience, domain knowledge, motivations, or product features that are not explicitly stated. If a detail is not in the bullets, leave it out.

        Style: plain prose, third-person ("The speaker describes…"), no Markdown headers, no bold, no bullet points, no section labels, no placeholders like "[Insert Date]". Keep it under 500 words and as short as the content allows — if there is little content, write one or two sentences only. Never invent participants, agendas, locations, dates, or features.

        Current summary: \(summary.isEmpty ? "(none yet)" : summary)

        New bullets to integrate:
        \(bullets.map { "- \($0)" }.joined(separator: "\n"))

        Updated summary (plain prose, third-person, facts only):
        """
    }
}
