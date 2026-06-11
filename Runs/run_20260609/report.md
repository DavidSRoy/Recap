# Run Report — 2026-06-09

## Run metadata

| Field | Value |
|---|---|
| Date | 2026-06-09 |
| Session file | `session_local.jsonl` |
| Baseline file | `session_baseline_ollama.jsonl` |
| Session duration | 141 s (2.4 min) |
| ASR segments produced | 27 (avg 7.5 words each) |
| Summarisation windows fired | 7 |
| Window cadence | 10 s |
| Local backend | Apple FoundationModels (Neural Engine, on-device) |
| Baseline backend | Ollama `llama3.1:8b` via HTTP (`localhost:11434`) |

---

## Key findings

**1. Total latency scales with prompt length — decode faster than prefill.**
Prefill and decode both grow linearly with `tokens_in`, but decode grows 4× faster (3.62 ms/token vs 0.87 ms/token, R² ≈ 0.75 for both). Prefill dominates at short prompts (< ~150 tokens, 66–71% of total latency) but decode overtakes it by window 4 (192 tokens) and stays dominant. The original hypothesis frames this as a prefill bottleneck; the more accurate statement is that *any reduction in prompt length reduces total latency, with the largest gains coming from shortening decode*.

**2. Memory is not a bottleneck — confirmed by this run.**
App RSS stayed flat at 117–136 MB (mean 129 MB) across the full session while segment count grew continuously. The rolling summary plateaued at 88 words by window 3 and held there. FoundationModels uses 65× less process memory than Ollama llama3.1:8b (129 MB vs 8 923 MB), because model weights are shared with the OS-level Apple Intelligence runtime rather than loaded privately.

**3. Parallel summary update provides no benefit at 10-second window cadence.**
Summary update completed in 693–1 486 ms; the gap to the next window was 6 948–50 274 ms in every case. Not on the critical path.

> **Run caveat:** 2.4 minutes is too short to confirm steady-state memory or full summary-cap engagement. Memory and `tokens_in` plateau findings are directional. A 15-minute run is needed to validate at scale.

---

## Claim 1 — Prefill is the primary latency bottleneck

**Finding: partially supported, but decode overtakes prefill as prompt length grows.**

Prefill dominates in the first three windows (66–71% of total latency). After window 3, decode overtakes prefill and accounts for 52–55% of total latency through the end of the session. Crucially, decode scales *faster* with input token count than prefill does:

| Metric | Slope (ms / input token) | R² |
|---|---|---|
| Prefill latency | 0.87 | 0.71 |
| Decode latency | 3.62 | 0.76 |

Both are correlated with `tokens_in`, but the decode slope is 4× steeper. This was unexpected. The most likely explanation is that FoundationModels' constrained structured-output generation attends over the full input context during each decode step (O(n) per token in attention), so longer prompts slow down both phases — not just prefill.

**Practical implication:** The hypothesis frames this as a prefill problem, but the right characterisation is: *total per-window latency scales linearly with input token count, with decode growing faster than prefill under structured-output constraints.* Reducing prompt length (tighter summary cap, fewer prior bullets) reduces both phases.

![Prefill scaling](figures/prefill_scaling.png)

---

## Claim 2 — Memory is not a bottleneck

**Finding: confirmed within the limits of this run.**

App RSS stayed flat at 117–136 MB (mean 129 MB) over the full session while the segment count grew monotonically from 1 to 27. There is no visible correlation between RSS and segment count. The app's in-memory data structures (segment list, bullet list, rolling summary) do not drive meaningful heap growth at this session length.

The rolling summary itself plateaued at 88 words by window 3 and held there through window 7 — well below the 500-word cap. The cap has not yet engaged in this run, but the plateau behaviour is already visible.

For the baseline, Ollama's combined process RSS held steady at 8 919–8 925 MB (mean 8 923 MB). This represents the loaded model weights and is effectively constant — it does not grow with session length.

![RSS plateau](figures/rss_plateau.png)

---

## Claim 3 — tokens_in will plateau once the summary cap engages

**Finding: directionally supported, with a known confound in this run.**

Summary words plateaued at 88 by window 3. Despite this, `tokens_in` continued growing from 58 to 262 tokens across all seven windows. The growth after window 3 is attributable to **prior-bullets prompt contamination**: in this run the model occasionally generated the string `"Prior bullets"` as a bullet (echoing the prompt scaffold label), which was stored and re-injected into subsequent prompts, inflating the prior-bullets section.

A filter was added after this run to reject bullets matching prompt scaffolding labels. The expectation for the next run is that `tokens_in` will plateau alongside summary words once both the summary and the (now-clean) prior-bullets list stabilise.

![Tokens plateau](figures/tokens_plateau.png)

---

## Claim 4 — Parallel summary update provides latency benefit

**Finding: refuted at 10-second window cadence.**

Summary update (the second LLM call that maintains the rolling prose summary) completed in 693–1 486 ms. The gap between summary completion and the next window's `prefill_start` was 6 948–50 274 ms. The summary update is not on the critical path in any of the six measured windows.

At 10-second window cadence, parallelising the summary update would provide zero user-visible benefit. The optimisation would only become relevant if the window cadence were reduced to ~2 seconds or less (where the gap could drop below the summary update duration).

![Summary gap](figures/summary_gap.png)

---

## Tokens-out comparability caveat

`tokens_out` is **not comparable** between conditions in this run. FoundationModels returns structured `BulletOutput` and `tokens_out` records the number of bullets (1–3). Ollama returns free-form text and `tokens_out` records the number of SSE delta chunks received (~30–67 per window). The reported TPS figures in `results.csv` reflect this difference and should not be compared directly across conditions.

---

## Summary table

| Claim | Verdict | Confidence |
|---|---|---|
| Prefill is the primary bottleneck | Partial — decode overtakes at 192+ tokens | Low (7 windows, 2.4 min) |
| Memory is not a bottleneck | Confirmed | Medium (RSS flat, summary bounded) |
| tokens_in will plateau | Directional — confounded by echo bug (now fixed) | Low (needs longer run) |
| Parallel summary provides benefit | Refuted — gap 5–35× summary duration | High (effect size is large) |

---

## Appendix — Raw data

### A1. Local — per-window inference metrics

| Window | Segment ID | tokens\_in | prefill\_ms | decode\_ms | total\_ms | tokens\_out | prefill % |
|---|---|---|---|---|---|---|---|
| 1 | 2  | 58  | 691 | 310 | 1 001 | 3 | 69% |
| 2 | 6  | 95  | 665 | 272 |   937 | 3 | 71% |
| 3 | 9  | 141 | 692 | 352 | 1 044 | 1 | 66% |
| 4 | 19 | 192 | 739 | 900 | 1 639 | 3 | 45% |
| 5 | 21 | 245 | 794 | 898 | 1 692 | 3 | 47% |
| 6 | 24 | 262 | 799 | 856 | 1 655 | 3 | 48% |
| 7 | 26 | 252 | 906 | 972 | 1 878 | 2 | 48% |

**Regression:** prefill\_ms = 0.87 × tokens\_in + 591, R² = 0.71. decode\_ms = 3.62 × tokens\_in − 351, R² = 0.76.

### A2. Baseline (Ollama llama3.1:8b) — per-window inference metrics

| Window | Segment ID | tokens\_in | prefill\_ms | decode\_ms | total\_ms | tokens\_out\* |
|---|---|---|---|---|---|---|
| 1 | 2  | 61  | 341 |   77 |   418 |  5 |
| 2 | 6  | 98  | 388 |  769 | 1 157 | 41 |
| 3 | 9  | 144 | 553 | 1 078 | 1 631 | 57 |
| 4 | 19 | 195 | 553 |  555 | 1 108 | 30 |
| 5 | 21 | 248 | 718 | 1 122 | 1 840 | 59 |
| 6 | 24 | 265 | 802 | 1 285 | 2 087 | 67 |
| 7 | 26 | 255 | 556 |  916 | 1 472 | 48 |

\* SSE delta chunk count, not comparable to local `tokens_out`.

### A3. Local — summary update per window

| Window | Summary words | Approx duration (ms) | Gap to next prefill (ms) | On critical path |
|---|---|---|---|---|
| 1 | 22  |   693 | 17 101 | No |
| 2 | 55  | 1 000 | 10 729 | No |
| 3 | 86  | 1 322 | 50 274 | No |
| 4 | 89  | 1 486 |  6 948 | No |
| 5 | 88  | 1 344 | 17 876 | No |
| 6 | 88  | 1 375 | 10 796 | No |

Duration is approximated as `summary_update.ts − decode_end.ts`. Direct logging of `duration_ms` was added after this run.

### A4. Local — RSS samples

| Metric | Value |
|---|---|
| Sample count | 705 |
| Sampling interval | 200 ms |
| Min RSS | 117.7 MB |
| Max RSS | 136.1 MB |
| Mean RSS | 129.3 MB |
| Std dev RSS | — |

### A5. Baseline — Ollama process RSS

| Metric | Value |
|---|---|
| Sample count | 43 |
| Min RSS | 8 919.4 MB |
| Max RSS | 8 924.7 MB |
| Mean RSS | 8 923.1 MB |

Samples both Ollama daemon and runner processes (PIDs identified via `pgrep`). Represents loaded model weights; constant throughout the session.

### A6. ASR segments

| Metric | Value |
|---|---|
| Total segments | 27 |
| Avg length | 7.5 words |
| Dedup dropped | 3 bullets |
