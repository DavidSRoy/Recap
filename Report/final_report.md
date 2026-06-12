# Recap: On-Device Meeting Summarisation — Final Report

## Abstract

A common problem in long meetings or lectures is losing track of the current topic and the important points made earlier — and the time it takes to regain that context. Recap is a macOS application that addresses this by listening to audio in real time, transcribing it on-device, and generating a live rolling bullet-point summary of what is being discussed. It runs entirely locally using Apple's Neural Engine: no cloud calls, no model downloads, no third-party dependencies.

Three instrumented runs (2.4 min, 13.9 min, 6.4 min) measured latency, memory, prompt size stability, and parallel-execution opportunity across Apple FoundationModels and an Ollama llama3.1:8b baseline. The central finding is that end-to-end inference latency (~1.5 s per window) is session-age-independent when the rolling summary is excluded from the planner prompt — a key architectural decision that collapsed the tokens\_in → latency correlation from R² ≈ 0.73 to R² ≈ 0.003.

---

## System Design

### Motivation

End-to-end latency is critical for this application: the bullet points the user sees must be relevant to what is being said right now, not to what was said two minutes ago. Running locally on the Neural Engine avoids the round-trip latency of a cloud call and keeps all audio and transcripts private. The core audio pipeline is written in C++ via an Obj-C++ bridge to allow granular control over memory layout and ring-buffer behaviour — areas where Swift's overhead is less predictable.

### Agentic design

The system uses an **orchestrator–subagent** pattern. A central coordinator (`RecapModel`) owns the session loop and dispatches to two LLM calls on a fixed 20-second timer:

- **Bullet extraction** (`SummarizerClient`) — given the last 25 seconds of transcript and the 5 most recent bullets, extracts up to 3 new bullet points. Invocation is gated on a 20-word minimum in the transcript window; if the model finds nothing substantive it returns an empty array and the window is skipped.
- **Summary update** (`SummaryStore`) — given the new bullets, compresses them into a rolling prose summary capped at 50 words. Runs concurrently with the next audio window being buffered.

Neither call involves autonomous decision-making about when to run — both are triggered mechanically by the orchestrator. The proposal envisioned a dedicated planning agent that would decide whether to summarise; in practice that collapsed into a word-count gate and a structured-output call that either produces bullets or doesn't.

### Architecture

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

- **Summary excluded from planner prompt.** The planner receives only the current transcript window and the last 5 bullets — not the rolling summary. The summary is maintained in parallel as a user-facing artifact but does not feed back into the planner. This bounds planner prompt size regardless of session length. It was the single most impactful change across the experiment runs (see Results).

- **Structured output.** Both agents use schema-constrained generation (`@Generable BulletOutput`, JSON schema for Ollama). No free-text parsing; output is typed at the framework level.


- **Word-count summary cap.** The summary is truncated to ≤ 50 words at sentence boundaries after each update, bounding summary-update prompt size and latency. I experimented with 500, 200, and 50 as limits, but 50 is what makes sense in practice, as anything longer is too long to read.

- **Deduplication.** New bullets are filtered against prior bullets using edit-distance similarity. A prompt-echo filter additionally rejects bullets that reproduce prompt scaffolding labels or contain fewer than 4 words.

### Inference backends

| Backend | Model | Structured output | RSS |
|---|---|---|---|
| Apple FoundationModels | Apple Intelligence default | `@Generable` schema | ~131 MB (app process; weights shared with OS) |
| Ollama | llama3.1:8b | JSON schema via `/v1/chat/completions` | ~9.4 GB (model server, warm) |

### Metrics

Every inference event is logged to JSONL: `prefill_start`, `first_token`, `decode_end`, `rss_sample` (200 ms interval), `summary_update`, `dedup_dropped`. The same schema is replayed through Ollama via `Eval/replay.py` for baseline comparison without requiring macOS or raw audio.

### Prefill and decode measurement

Prefill and decode are not directly observable from the FoundationModels API. They are approximated from wall-clock timestamps:

- **Prefill** = time from request submission to first streaming chunk (TTFT)
- **Decode** = time from first streaming chunk to stream completion

This is consistent with standard LLM benchmarking conventions. Three caveats apply: (1) structured-output constrained decoding may buffer the first chunk until a valid partial JSON structure forms, making TTFT a slight overestimate of true prefill time; (2) Swift async/await scheduling adds a small constant overhead to TTFT; (3) when `streamResponse` falls back to the non-streaming `respond()` path, only total latency is recorded and prefill is reported as 0.

---

## Performance Results

### Experiment

**Hypothesis.** Because the application runs locally, prefill is expected to be the primary latency bottleneck: the full prompt must be processed to build the KV cache before the first token can be generated, and that cost scales with prompt length. Memory is not expected to be a bottleneck because the rolling summary stays at a bounded size — it should not grow linearly with session length. A consequence is that if prompt size is bounded, latency should also be stable across a session regardless of how long it has been running. A proposed optimisation — running the summary update concurrently with the next audio window — was expected to reduce end-to-end latency.

**What we varied.** The central independent variable is whether the rolling summary is included in the bullet-extraction prompt. In the initial design the prompt contained `[summary] + [transcript] + [prior bullets]`; as the session ages the summary grows, causing the prompt to grow and latency to scale with session duration. The hypothesis was that removing the summary from this prompt would decouple latency from session age. The summary cap was also varied (500 → 200 → 50 words) to control how quickly the cap engages and to bound summary-update latency.

**What we kept constant.** Audio content (same speaker and recording conditions across runs), window cadence (20 s), audio window size (25 s), prior-bullet context (last 5 bullets), inference backend (Apple FoundationModels, with Ollama llama3.1:8b as a held-out baseline replayed from the same JSONL on identical prompts).

**Runs.**

| Run | Duration | Windows | Summary in prompt | Summary cap | Notes |
|---|---|---|---|---|---|
| run_20260609 | 2.4 min | 7 | **Yes** | 500 words | Pilot; prompt-echo bug present |
| run_20260610 | 13.9 min | 38 | No | 200 words | Summary removed from prompt |
| run_20260611 | 6.4 min | 18 | No | **50 words** | Cap reduced to force early engagement |

At 50 words the cap engaged by window 8 (~2.7 min) in run 3 and held for the remaining 10 windows. Each run's JSONL was replayed through Ollama to produce a matched baseline without re-running audio.

### Latency

| Metric | FoundationModels | Ollama llama3.1:8b |
|---|---|---|
| Mean prefill (ms) | 885–911 | 376–424 |
| Mean decode (ms) | 625–689 | 1 044–1 079 |
| Mean total (ms) | 1 536–1 574 | 1 421–1 504 |
| p95 total (ms) | ~1 986 | ~1 599–1 916 |
| Prefill % of total | 57–59% | 26–28% |

Total latency is ~1.5 s for both backends. FoundationModels is faster at decode (1.6–1.7×); Ollama is faster at prefill (2–2.4×). At the 20 s window cadence, either backend completes inference well within the next window interval.

**Latency is session-age-independent.** Removing the rolling summary from the planner prompt collapsed the tokens\_in → latency correlation from R² ≈ 0.73 (run 1, summary in prompt) to R² ≈ 0.003 (runs 2–3). In run 1, both prefill and decode grew linearly with tokens\_in as the summary accumulated; decode scaled 4× faster than prefill (3.62 vs 0.87 ms/token), likely because constrained structured-output decoding attends over the full context at each step. After the architectural change, latency variance is driven by transcript content density, not session length.

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
| Summary words (50-word cap run) | Cap engaged by window 8 (~2.7 min); held for remaining windows |

tokens\_in is bounded by the 25 s transcript window size and the 5-bullet prior context — both architecturally capped. The summary cap additionally bounds summary-update prompt size and latency. Notably, tokens\_in was stable even before the cap engaged: since the summary is not in the planner prompt, prompt size depends only on speech density in the current window and the prior-bullet count, both of which are independent of session age.

### Parallel summary

| Metric | Value |
|---|---|
| Summary update duration | 556–1 974 ms (mean ~1.2 s at 50-word cap) |
| Gap to next prefill | 14 346–23 152 ms (mean ~19 s) |
| Windows on critical path | 0 / 51 across all runs |

The summary update never blocks the next inference window at 20 s cadence. Gap headroom is 6–17× the mean summary duration. Parallelising the summarizer (as proposed) provides no user-visible latency benefit at this cadence — the summarizer already completes well before the next window fires. The breakeven cadence where parallelism would become load-bearing is approximately 2–3 s.

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
