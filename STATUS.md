# Recap — Session Status

## What's been built

### Day 0 ✅ Bootstrap
- Xcode project scaffolded, repo pushed to `github.com/DavidSRoy/Recap` (private)
- `MetricsLogger` writes JSONL to `~/Library/Containers/.../Recap/Runs/session_<ts>.jsonl`
- Full repo structure in place (see `PLAN.md`)

### Day 1 ✅ Audio → Transcript
- `AudioEngineManager` — 16 kHz mono mic tap via `AVAudioConverter`
- `FilePlayer` — reads audio file in 100 ms chunks at real-time pace, same pipeline as mic
- `ASRStreamer` — silence-gated chunking (700 ms / 8 s max), emits `Segment` on each chunk
- `TranscriptView` — live scrolling list of segments
- JSONL events: `audio_start`, `segment_end`

### Day 2 ✅ Window + Bullets
- `WindowBuilder` — 60 s sliding window, evicts expired segments
- `SummarizerClient` — Apple `FoundationModels` (`@Generable BulletOutput`), new session per call
- `BulletsView` — accumulates bullet batches across windows
- JSONL events: `prefill_start`, `first_token`, `decode_end`
- Trigger: every 60 s when window has ≥ 20 words

### Day 3 ✅ Summary + Dedup
- `Deduplicator` — character 3-gram Jaccard similarity > 0.8 against the last 5 bullets
- `SummaryStore` — calls `LanguageModelSession` with `summaryUpdate`; 500-word cap enforced by keeping trailing sentences
- `RSSSampler` — 200 ms `Timer` on main runloop logging `rss_sample` events
- `SessionStore.save(segments:bullets:summary:)` — writes pretty-printed `session_<id>.json` on stop
- `RecapModel` wires it all together; all UI-state mutations now hop to `MainActor.run` so successive summarize cycles reach SwiftUI reliably
- Summary prompt tightened: no markdown, no `[Insert Date]` placeholders, no invented agendas
- `BulletsView` wrapped in `ScrollView` (was clipped at `maxHeight: 200`)

### Day 4 🟡 Systems Optimisations (partial)
- **C++ lock-free SPSC `RingBuffer`** at `Recap/Engine/` with `push`, `pop`, `peekTail`, `size`, `clear`. Atomic head/tail.
- **`MetricsCollector`** at `Recap/Engine/` — `nowNs()` (mach_absolute_time) and `rssMb()` (mach_task_basic_info).
- **Obj-C++ `EngineBridge`** at `Recap/EngineBridge/` — exposes `pushPCM`, `popPCM`, `peekTail`, `frameCount`, `clear`, `nowNs`, `rssMb`.
- **`Recap-Bridging-Header.h`** + `SWIFT_OBJC_BRIDGING_HEADER` set on Recap target (Debug + Release).
- **`EngineBridge: @unchecked Sendable`** — safe given SPSC contract.
- **`ASRStreamer`** rewritten — old `AudioSampleAccumulator` (NSLock + Swift array) is gone; PCM now flows through the ring buffer. Pre-allocated `UnsafeMutablePointer<Float>` scratch buffers for drain/peek (zero hot-path allocation).
- **`RSSSampler`** now reads `bridge.rssMb()` (single implementation in C++).
- **Context window** — last session had `tokens_in: 59`, prior peak 404. Comfortably under 4 096.
- **Still TODO before Day 4 is "done"** —
  - Replace `respond(to:generating:)` with `streamResponse(...)` so `first_token` and `decode_end` are actually distinct timestamps (currently they share — TTFT and decode latency are conflated).
  - Verify RSS plateau with a 3+ min continuous mic run.
  - Optional: Instruments TTFT profile.

## Key architectural decisions

| Decision | Why |
|---|---|
| **`SFSpeechRecognizer`** instead of WhisperKit | Zero package dependencies, no model download, on-device Neural Engine |
| **Apple `FoundationModels`** instead of MLXLLM | No package complexity, no HuggingFace download, `@Generable` for type-safe structured output |
| **Zero SPM dependencies** | Both WhisperKit and mlx-swift removed; app uses only Apple frameworks |
| **New `LanguageModelSession` per call** | Avoids context accumulation hitting the 4 096-token limit |
| **`@Generable BulletOutput { bullets: [String] }`** | Removed `keepListening: Bool` — constrained decoding was biasing model toward true; empty array signals keep-listening instead |
| **C++ SPSC `RingBuffer` for audio** | Lock-free atomics, zero hot-path allocation; producer = audio thread, consumer = ASR loop |
| **Single shared `EngineBridge`** | Both `ASRStreamer` and `RSSSampler` use it — one C++ implementation of `rssMb`/`nowNs` |
| **`MainActor.run` around bullet/summary writes** | Successive summarize cycles weren't reaching the UI; explicit hops fix observation |
| **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** | Set in build settings; nudges the project toward main-actor-by-default |

## Known issues / limitations

- **Summary still hallucinates.** The 2026-06-08 21:44 session produced a summary mentioning "podcast", "feedback from users", "automatic punctuation" — none of which appeared in the transcript. The Day-3 prompt forbade markdown templates but didn't forbid invention. Needs a stricter "only use facts from the bullets, third-person framing" prompt.
- **TTFT vs decode latency conflated.** `respond(to:generating:)` returns the full structured response in one call, so `first_token` and `decode_end` share a timestamp. Fix: switch to `streamResponse(...)`.
- **`MetricsOverlay` is empty.** UI is wired into `ContentView` but `body` returns `EmptyView()`. No live metric readout yet.
- **FoundationModels content safety refusals** — Apple's filter can refuse windows containing news/geopolitical content. Handled gracefully: refusal resets the 60 s timer for an immediate retry.
- **`SessionStore` only writes one `session.json` per run lifecycle.** Multiple Start/Stop cycles within one app session overwrite the file with the last run's data.

## What's next

### Day 4 (finish) — Systems Optimisations
- Switch `SummarizerClient.summarize` to `streamResponse(...)` so `first_token` fires on the first partial, giving real TTFT vs decode separation
- 3+ min continuous mic run; confirm RSS plateau in the second half
- Tighten summary prompt to stop hallucinating outside the bullets
- (Optional) Implement live `MetricsOverlay`
- (Optional) Instruments TTFT profile

### Day 5 — Evaluation
- `Eval/analyze.py` — mean/p95 latency, TPS, peak RSS from JSONL (one-line per cycle, chunked by `audio_start`)
- `Eval/plot.py` — two figures (latency over time, RSS over time)
- `Eval/vllm_client.py` — replay same prompts against vLLM endpoint
- `Report/results.csv`

### Day 6 — Demo + Report
- 90–120 s screen recording
- `Report/report.md` with Abstract, Design, Implementation, Optimisations, Evaluation, Results, Limitations
- `README.md` with build steps and reproduce commands

## How to run

```bash
# Build and run
open Recap.xcodeproj   # then ⌘R

# Permissions required on first launch
# • Microphone
# • Speech Recognition (on-device)
# • Apple Intelligence must be enabled in System Settings

# Check JSONL output
ls ~/Library/Containers/com.thrillersolutions.Recap/Data/Library/Application\ Support/Recap/Runs/
```
