import Foundation
import FoundationModels

@Generable
struct BulletOutput {
    @Guide(description: "True when the transcript contains no new insights beyond the summary and prior bullets")
    var keepListening: Bool
    @Guide(description: "1 to 3 concise bullet points capturing new key ideas. Empty array when keepListening is true.")
    var bullets: [String]
}

enum SummarizeResult {
    case keepListening
    case bullets([String])
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
            logger?.log("decode_end", [
                "segment_id": segmentId,
                "tokens_in": tokensIn,
                "tokens_out": response.content.bullets.count
            ])

            if response.content.keepListening {
                print("[SummarizerClient] keepListening")
                return .keepListening
            }
            let newBullets = response.content.bullets
            guard !newBullets.isEmpty else { return .keepListening }
            print("[SummarizerClient] \(newBullets.count) bullets: \(newBullets.first ?? "")")
            return .bullets(newBullets)
        } catch {
            print("[SummarizerClient] error: \(error)")
            return .keepListening
        }
    }
}
