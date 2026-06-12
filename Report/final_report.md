# Recap: On-Device Meeting Summarisation — Final Report

## Abstract

Recap is a macOS application that transcribes audio in real time and produces a live bullet-point summary using on-device LLM inference. It targets fully private, zero-latency operation: no cloud calls, no model downloads, no third-party dependencies. Three instrumented runs (2.4 min, 13.9 min, 6.4 min) measured latency, memory, prompt size stability, and parallel-execution opportunity across Apple FoundationModels and an Ollama llama3.1:8b baseline.

---

## System Design

### Architecture

The system follows an **orchestrator–subagent** pattern. A central coordinator (`RecapModel`) owns the session loop and dispatches to two specialised agents that run concurrently.

```
Microphone / Audio file
        │  16 kHz mono PCM
        ▼
  EngineBridge (lock-free SPSC ring buffer, Obj-C++)
        │
        ▼
  ASRStreamer  ─── silence-gated batch recognition (SFSpeechRecognizer)
        │  Segment events (text + timestamps)
        ▼
  RecapModel (orchestrator)
        │  every 20 s, if ≥ 20 words in window
        ├──► SummarizerClient (planner agent)
        │         prompt: [25 s transcript] + [last 5 bullets]
        │         output: up to 3 new bullets (structured JSON)
        │
        └──► SummaryStore (summarizer agent)  ← runs in parallel, actor-serialized
                  prompt: [current summary] + [new bullets]
                  output: updated rolling prose summary (≤ 50 words)
```

**Key design decisions:**

- **Summary excluded from planner prompt.** The planner receives only the current transcript window and the last 5 bullets. The rolling summary is maintained separately and updated in parallel. This bounds planner prompt size regardless of session length and was the single most impactful change across the experiment runs.

- **Structured output.** Both agents use schema-constrained generation (`@Generable BulletOutput`, JSON schema for Ollama). No free-text parsing; output is typed at the framework level.

- **Actor-serialized summary store.** `SummaryStore` is a Swift actor. Concurrent summary updates are serialized automatically; the orchestrator unlocks immediately after the planner returns, not after the summary update completes.

- **Word-count summary cap.** The summary is truncated to ≤ 50 words at sentence boundaries after each update. This keeps the summary-update prompt size bounded regardless of how long the session runs.

- **Deduplication.** New bullets are filtered against prior bullets using edit-distance similarity before being appended. A prompt-echo filter rejects bullets that reproduce prompt scaffolding labels or contain fewer than 4 words.

### Inference backends

| Backend | Model | Structured output | RSS |
|---|---|---|---|
| Apple FoundationModels | Apple Intelligence default | `@Generable` schema | ~131 MB (app process; weights shared with OS) |
| Ollama | llama3.1:8b | JSON schema via `/v1/chat/completions` | ~9.4 GB (model server, warm) |

### Metrics

Every inference event is logged to JSONL: `prefill_start`, `first_token`, `decode_end`, `rss_sample` (200 ms interval), `summary_update`, `dedup_dropped`. The same schema is replayed through Ollama/vLLM via `Eval/replay.py` for baseline comparison without requiring macOS or raw audio.

---

## Performance Results

Results are consistent across runs 2 and 3 (run 1 is a pilot with a prompt-echo bug and a 10 s cadence).

### Latency

| Metric | FoundationModels | Ollama llama3.1:8b |
|---|---|---|
| Mean prefill (ms) | 885–911 | 376–424 |
| Mean decode (ms) | 625–689 | 1 044–1 079 |
| Mean total (ms) | 1 536–1 574 | 1 421–1 504 |
| p95 total (ms) | ~1 986 | ~1 599–1 916 |
| Prefill % of total | 57–59% | 26–28% |

Total latency is ~1.5 s for both backends. FoundationModels is faster at decode (1.6–1.7×); Ollama is faster at prefill (2–2.4×). At the 20 s window cadence, either backend completes inference well within the next window interval.

**Latency is session-age-independent.** Removing the rolling summary from the planner prompt collapsed the tokens\_in → latency correlation from R² ≈ 0.73 (run 1, summary in prompt) to R² ≈ 0.003 (runs 2–3). Latency variance is now driven by transcript content density, not session length.

### Memory

| Metric | Value |
|---|---|
| App RSS range | 120–148 MB across all runs |
| Last-5-min RSS std | 1.8–3.7% of mean |
| Ollama model server RSS | ~9.4 GB (warm, llama3.1:8b) |

App process memory is flat and session-length-independent. Segment count grows linearly throughout each run with no corresponding RSS growth. FoundationModels model weights are shared with the OS-level Apple Intelligence runtime and do not appear in app RSS.

### Prompt size

| Metric | Value |
|---|---|
| tokens\_in mean (range) | 213 (96–299) across stable runs |
| Trend over session | None — no growth in any run |
| Summary words (50-word cap) | Cap engaged by window 8 (~2.7 min); held for remaining windows |

tokens\_in is bounded by the 25 s transcript window size and the 5-bullet prior context — both architecturally capped. The summary cap additionally bounds summary-update prompt size and latency.

### Parallel summary

| Metric | Value |
|---|---|
| Summary update duration | 556–1 974 ms (mean ~1.2 s at 50-word cap) |
| Gap to next prefill | 14 346–23 152 ms (mean ~19 s) |
| Windows on critical path | 0 / 51 across all runs |

The summary update never blocks the next inference window at 20 s cadence. Gap headroom is 6–17× the mean summary duration. The parallel execution provides no user-visible latency benefit at the current cadence.

---

## Optimization Opportunities

### Latency
- **Reduce window cadence.** At 20 s the system is idle ~18.5 s per cycle. Reducing to 5–10 s would increase bullet throughput and surface the cadence floor where inference latency becomes the bottleneck.
- **Prefill caching.** The system prompt is identical across all windows. KV-cache prefix reuse (if exposed by FoundationModels) could eliminate repeated prefill of the static system prompt portion.
- **Smaller or quantized model.** Ollama prefill (424 ms) is already 2× faster than FoundationModels (911 ms) with an 8B parameter model. A 3B model or INT4-quantized 8B would reduce decode time at the cost of output quality.
- **Streaming decode.** The current implementation waits for the full structured output before updating the UI. Streaming bullet updates as tokens arrive would reduce perceived latency to TTFT (~400–900 ms).

### Memory
- **Longer session validation.** The longest run is 13.9 min with 335 segments. A 60+ min run is needed to confirm the memory plateau holds at production scale (e.g., a full meeting).
- **Segment pruning.** The `segments` array grows unbounded in memory. For long sessions, segments older than the current window could be evicted from the in-process array (they are already persisted to JSONL).

### Prompt size
- **Prior bullets window.** Currently the last 5 bullets are included in every planner prompt. Reducing to 3 or filtering to only bullets from the last N seconds could reduce tokens\_in by ~20–30% without quality loss.
- **Transcript compression.** The raw transcript window is passed verbatim. Light preprocessing (filler-word removal, sentence deduplication) could reduce window token count while preserving semantic content.

### Parallel summary
- **Cadence sweep.** Characterise the breakeven cadence — the point at which summary update duration exceeds the inter-window gap and parallelism becomes load-bearing. Based on current data (~1.2 s update, ~19 s gap), the breakeven is around 2–3 s cadence.
- **Summary-update model swap.** The summary update uses the same model as the planner. A lighter, non-structured-output call (no JSON schema constraint) may be faster for this task.

### Infrastructure
- **vLLM baseline.** A GPU-side vLLM run would complete the backend comparison (on-device Neural Engine vs local CPU via Ollama vs cloud GPU) and quantify the privacy–latency tradeoff.
- **Replay warm-up.** The `replay.py` baseline should always pre-warm the model with one dummy request before starting RSS sampling, as validated in run_20260611.
