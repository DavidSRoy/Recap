import Foundation
import FoundationModels

@Generable
struct BulletOutput {
    @Guide(description: "Up to 3 concise bullet points capturing the key new ideas from the transcript. Return an empty array only if the transcript is pure noise, filler words, or contains nothing substantive.")
    var bullets: [String]
}

enum SummarizeResult {
    case keepListening
    case bullets([String], prefillMs: Int, decodeMs: Int)
    case refused
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

        // Log system + prompt so vllm_client.py can replay exact inputs.
        logger?.log("prefill_start", [
            "segment_id": segmentId,
            "system": PromptTemplates.systemPrompt,
            "prompt": prompt
        ])
        print("[SummarizerClient] summarizing window (\(window.split(separator: " ").count) words)")

        let prefillStartMs = nowMs()

        do {
            let stream = session.streamResponse(to: prompt, generating: BulletOutput.self)
            var firstTokenMs = 0
            var firstTokenFired = false
            var lastBullets: [String] = []

            for try await snapshot in stream {
                if !firstTokenFired {
                    firstTokenMs = nowMs()
                    logger?.log("first_token", ["segment_id": segmentId])
                    firstTokenFired = true
                }
                // snapshot: ResponseStream<BulletOutput>.Snapshot
                // .content gives BulletOutput.PartiallyGenerated; .bullets grows as tokens arrive.
                lastBullets = snapshot.content.bullets ?? lastBullets
            }

            if !firstTokenFired { firstTokenMs = nowMs() }
            let decodeEndMs = nowMs()

            logger?.log("decode_end", [
                "segment_id": segmentId,
                "tokens_in": prompt.split(separator: " ").count,
                "tokens_out": lastBullets.count
            ])

            guard !lastBullets.isEmpty else {
                print("[SummarizerClient] keepListening (empty bullets)")
                return .keepListening
            }
            print("[SummarizerClient] \(lastBullets.count) bullets: \(lastBullets.first ?? "")")
            return .bullets(
                lastBullets,
                prefillMs: firstTokenMs - prefillStartMs,
                decodeMs: decodeEndMs - firstTokenMs
            )
        } catch {
            // streamResponse can be rate-limited in background tasks — fall back to respond().
            if isRateLimit(error) {
                print("[SummarizerClient] stream rate-limited, falling back to respond()")
                return await respondFallback(
                    session: session, prompt: prompt,
                    prefillStartMs: prefillStartMs, segmentId: segmentId, logger: logger
                )
            }
            return classify(error)
        }
    }

    // Non-streaming fallback. first_token and decode_end share a timestamp (TTFT unmeasurable).
    private func respondFallback(
        session: LanguageModelSession,
        prompt: String,
        prefillStartMs: Int,
        segmentId: Int,
        logger: MetricsLogger?
    ) async -> SummarizeResult {
        do {
            let response = try await session.respond(to: prompt, generating: BulletOutput.self)
            let endMs = nowMs()
            logger?.log("first_token", ["segment_id": segmentId])
            let bullets = response.content.bullets
            logger?.log("decode_end", [
                "segment_id": segmentId,
                "tokens_in": prompt.split(separator: " ").count,
                "tokens_out": bullets.count
            ])
            guard !bullets.isEmpty else { return .keepListening }
            // prefillMs=0 signals TTFT was not measurable on this call.
            return .bullets(bullets, prefillMs: 0, decodeMs: endMs - prefillStartMs)
        } catch {
            return classify(error)
        }
    }

    private func isRateLimit(_ error: Error) -> Bool {
        let lower = "\(error)".lowercased()
        return lower.contains("ratelimit") || lower.contains("rate limit") || lower.contains("throttl")
    }

    private func classify(_ error: Error) -> SummarizeResult {
        let desc = "\(error)"
        let lower = desc.lowercased()
        let isRefusal = lower.hasPrefix("refusal(")
            || lower.contains("generationerror.refusal")
            || lower.contains(".refusal(")
        if isRefusal {
            print("[SummarizerClient] refused: \(error)")
            return .refused
        }
        print("[SummarizerClient] error: \(error)")
        return .keepListening
    }

    private func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }
}
