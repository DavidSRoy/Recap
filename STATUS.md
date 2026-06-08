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

## Key architectural decisions

| Decision | Why |
|---|---|
| **`SFSpeechRecognizer`** instead of WhisperKit | Zero package dependencies, no model download, on-device Neural Engine |
| **Apple `FoundationModels`** instead of MLXLLM | No package complexity, no HuggingFace download, `@Generable` for type-safe structured output |
| **Zero SPM dependencies** | Both WhisperKit and mlx-swift removed; app uses only Apple frameworks |
| **New `LanguageModelSession` per call** | Avoids context accumulation hitting the 4 096-token limit |
| **`@Generable BulletOutput { bullets: [String] }`** | Removed `keepListening: Bool` — constrained decoding was biasing model toward true; empty array signals keep-listening instead |
| **Static `nextSegmentId`** | Segment IDs must be globally unique across Start/Stop cycles to avoid `ForEach` collisions |
| **`shouldStop` flag (not `Task.cancel()`)** | Cancellation was propagating into `SFSpeechRecognizer` mid-transcription |

## Known issues / limitations

- **FoundationModels content safety refusals** — Apple's filter can refuse windows containing news/geopolitical content (e.g. country names + "strikes" + "funds"). Handled gracefully: refusal resets the 60 s timer so the next segment retries immediately with fresh content.
- **Bullets accumulate without dedup** — Day 3 adds Jaccard deduplication. Until then, repeated phrases across windows will pile up in `BulletsView`.
- **`SummaryView` shows nothing** — `SummaryStore.update()` is a stub. Day 3 implements it.
- **`RSSSampler` is a stub** — logs no `rss_sample` events yet. Day 3.
- **`SessionStore` writes no `session.json`** — Day 3.

## What's next

### Day 3 — Summary + Dedup ← **start here**
- `Deduplicator` — Jaccard 3-gram similarity > 0.8, deduplicate against last 5 bullets before appending
- `SummaryStore` — call `FoundationModels` with `summaryUpdate` prompt after each bullet batch; enforce 500-word cap by truncating oldest sentences
- `RSSSampler` — sample RSS memory every 200 ms while running, log `rss_sample` events
- `SessionStore` — write `session.json` (segments + bullets + summary) on stop
- Wire `RecapModel` to call `SummaryStore.update()` after new bullets arrive

### Day 4 — Systems Optimisations
- Route all audio through the C++ `RingBuffer` (`EngineBridge`)
- Profile `LanguageModelSession` TTFT with Instruments
- Verify context window stays under 4 096 tokens per call
- `RSSSampler` confirmed flat after minute 2

### Day 5 — Evaluation
- `Eval/analyze.py` — compute mean/p95 latency, TPS, peak RSS from JSONL
- `Eval/plot.py` — two figures
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
