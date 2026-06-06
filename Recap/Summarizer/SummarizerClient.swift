import Foundation
import FoundationModels

@Generable
struct BulletOutput {
    @Guide(description: "Up to 3 concise bullet points capturing the key new ideas from the transcript. Return an empty array only if the transcript is pure noise, filler words, or contains nothing substantive.")
    var bullets: [String]
}

enum SummarizeResult {
    case keepListening
    case bullets([String])
    case refused          // safety filter triggered — caller should retry sooner
}

final class SummarizerClient {
    func warmup() async {
        guard case .available = SystemLanguageModel.default.availability else { return }
        let session = LanguageModelSession(instructions: PromptTemplates.systemPrompt)
        _ = try? await session.respond(to: "Hello")
        print("[SummarizerClient] warmed up")
    }

    func summarize(
        window: String,
        summary: String,
        priorBullets: [String],
        segmentId: Int,
        logger: MetricsLogger?
    ) async -> SummarizeResult {
        guard case .available = SystemLanguageModel.default.availability else {
            print("[SummarizerClient] model unavailable")
            return .keepListening
        }

        let session = LanguageModelSession(instructions: PromptTemplates.systemPrompt)
        let prompt = PromptTemplates.planner(summary: summary, window: window, lastBullets: priorBullets)

        logger?.log("prefill_start", ["segment_id": segmentId])
        print("[SummarizerClient] summarizing window (\(window.split(separator: " ").count) words)")

        do {
            let response = try await session.respond(to: prompt, generating: BulletOutput.self)

            logger?.log("first_token", ["segment_id": segmentId])

            let tokensIn = prompt.split(separator: " ").count
            let newBullets = response.content.bullets
            logger?.log("decode_end", [
                "segment_id": segmentId,
                "tokens_in": tokensIn,
                "tokens_out": newBullets.count
            ])

            guard !newBullets.isEmpty else {
                print("[SummarizerClient] keepListening (empty bullets)")
                return .keepListening
            }
            print("[SummarizerClient] \(newBullets.count) bullets: \(newBullets.first ?? "")")
            return .bullets(newBullets)
        } catch {
            let isRefusal = "\(error)".contains("refusal") || "\(error)".contains("Refusal")
            print("[SummarizerClient] \(isRefusal ? "refused" : "error"): \(error)")
            return isRefusal ? .refused : .keepListening
        }
    }
}
