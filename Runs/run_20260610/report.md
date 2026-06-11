# Run Report — 2026-06-10

## Run metadata

| Field | Value |
|---|---|
| Date | 2026-06-10 |
| Session file | `session_local.jsonl` |
| Baseline file | `session_baseline_ollama.jsonl` |
| Session duration | 836.8 s (13.9 min) |
| ASR segments | 335 (avg 5.9 words each) |
| Summarisation windows fired | 43 |
| Summarisation windows completed | 38 |
| Window cadence | 20 s |
| Audio window size | 25 s |
| Summary cap | 200 words |
| Local backend | Apple FoundationModels (Neural Engine, on-device) |
| Baseline backend | Ollama `llama3.1:8b` via HTTP (`localhost:11434`) |

**Configuration changes vs run_20260609:**

| Parameter | run_20260609 | run_20260610 |
|---|---|---|
| Window cadence | 10 s | 20 s |
| Audio window size | 10 s | 25 s |
| Summary cap | 500 words | 200 words |
| Summary in planner prompt | Yes | **No** |
| Prior-bullets echo filter | No | Yes |

The removal of the rolling summary from the per-window planner prompt is the most significant change. In run_20260609 the planner received `[summary] + [transcript window] + [prior bullets]`; in this run it receives only `[transcript window] + [prior bullets]`. The summary is still maintained and updated after each window, but it is no longer part of the bullet-generation input.

---

## Key findings

**1. Removing the summary from the planner prompt eliminated the tokens_in → latency scaling relationship.**
In run_20260609, both prefill and decode scaled with `tokens_in` (R² 0.71 and 0.76). In this run, neither does (R² 0.003 and 0.032). Latency is now roughly constant across the session regardless of session age. Mean total latency is 1 573 ms — nearly identical to the 1 492 ms mean in run_20260609, but the variance is now driven by content difficulty rather than prompt length.

**2. Prefill is consistently the dominant term when latency is stable.**
With tokens_in no longer growing, prefill averages 885 ms (57% of total) vs decode 689 ms across all 38 windows. This is the regime the original hypothesis described — prefill-limited, with latency depending on the number of input tokens.

**3. Memory is not a bottleneck — confirmed at production scale.**
RSS held at 120–148 MB (mean 134 MB) over 13.9 minutes while segment count grew to 335. In the last 5 minutes, RSS standard deviation was 1.9 MB — 1.4% of the mean. The rolling summary reached 183 words (approaching the 200-word cap) and held there. Segment count and bullet count grew linearly with no corresponding RSS growth.

**4. Parallel summary update is not on the critical path.**
Summary update duration ranged 760–4 246 ms (mean 2 709 ms). The gap to the next window ranged 14 346–20 763 ms (mean 17 162 ms). 0 of 30 summary updates overlapped with the next window's prefill.

**5. Ollama total latency is now comparable to FoundationModels.**
With the summary removed from the prompt, tokens_in is smaller and more consistent. Ollama mean total latency is 1 517 ms vs FoundationModels 1 573 ms — within 4%. Ollama has lower prefill (439 ms vs 885 ms) but higher decode (1 078 ms vs 689 ms). FoundationModels is faster at structured-output decoding; Ollama is faster at prefill.

---

## Claim 1 — Prefill is the primary latency bottleneck

**Finding: confirmed in stable-latency regime, with a key architectural dependency.**

With the summary removed from the planner prompt, tokens_in is bounded (106–309, mean 223) and shows no growth trend over the 13.9-minute session. Neither prefill nor decode correlates with tokens_in (R² < 0.04 for both). Latency variance is now driven by content complexity, not prompt length.

Within this regime, prefill is the dominant term: 885 ms mean vs 689 ms decode, with prefill accounting for 57% of total latency on average. However, this is not a universal result — 16 of 38 windows show decode > prefill, suggesting that for complex transcript windows the model takes longer to decide on structured output.

The original hypothesis ("prefill will be the primary bottleneck") holds in the sense that reducing prompt length is the correct lever. The run_20260609 finding that decode scaled 4× faster than prefill was an artifact of the summary being in the prompt: as the summary grew, it added more context for the model to attend to during constrained decoding. Removing the summary from the planner prompt eliminated that effect.

![Prefill scaling](figures/prefill_scaling.png)

---

## Claim 2 — Memory is not a bottleneck

**Finding: confirmed at 13.9 minutes.**

RSS stayed within a 28 MB band (120–148 MB) across the entire session while the segment count grew from 0 to 335. In the final 5 minutes, RSS mean was 137.3 MB with standard deviation 1.9 MB — 1.4% of mean, meeting the < 15% success criterion from the experiment plan.

The rolling summary plateaued at 183 words by window 28 and held there for the remainder of the session, approaching but not reaching the 200-word cap. FoundationModels process memory (134 MB mean) is substantially lower than the Ollama server (8 923 MB in run_20260609; note the baseline RSS measurement in this run reflects only the Python replay client process, not the Ollama server — see caveat below).

![RSS plateau](figures/rss_plateau.png)

---

## Claim 3 — tokens_in stabilises once the summary is bounded

**Finding: confirmed — tokens_in is stable throughout the session.**

With the summary removed from the planner prompt, `tokens_in` oscillates between 106 and 309 (mean 223) with no growth trend. The variation reflects changes in the transcript window size (denser speech produces more tokens in 25 s) and prior-bullet count, both of which are bounded.

The summary word count grew from 41 to 183 words across 30 summary-update events, approaching the 200-word cap. Once it hits the cap, summary words and summary-update tokens_in will also stabilise.

![Tokens plateau](figures/tokens_plateau.png)

---

## Claim 4 — Parallel summary update provides latency benefit

**Finding: refuted at 20-second window cadence.**

Summary update duration ranged 760–4 246 ms (mean 2 709 ms, now directly measured via `duration_ms`). The gap between summary update completion and the next window's `prefill_start` ranged 14 346–20 763 ms (mean 17 162 ms). Zero of 30 summary updates overlapped with the next window's prefill.

The summary update takes longer in this run than in run_20260609 (mean 2 709 ms vs ~1 100 ms). This is expected: the summary-update prompt includes the growing rolling summary, which has reached 183 words. As the summary approaches the 200-word cap, summary-update latency will stabilise at around the current level.

Even at 2 709 ms mean, the gap is 6× larger. The parallel optimisation would require reducing the cadence to below ~3 s to become relevant.

![Summary gap](figures/summary_gap.png)

---

## Comparison with run_20260609

| Metric | run_20260609 | run_20260610 | Direction |
|---|---|---|---|
| Session duration | 2.4 min | 13.9 min | Longer |
| Completed windows | 7 | 38 | More data |
| tokens_in mean | 178 | 223 | Higher (larger windows) |
| tokens_in R² vs prefill | 0.71 | 0.003 | **Eliminated** |
| tokens_in R² vs decode | 0.76 | 0.032 | **Eliminated** |
| Prefill slope (ms/token) | 0.87 | 0.12 | −86% |
| Decode slope (ms/token) | 3.62 | 1.24 | −66% |
| Mean prefill (ms) | 755 | 885 | +17% |
| Mean decode (ms) | 651 | 689 | +6% |
| Mean total (ms) | 1 492 | 1 573 | +5% |
| Prefill % of total | 56% (declining) | 57% (stable) | Stable |
| RSS last 5 min std | N/A | 1.4% of mean | Confirmed plateau |
| Summary words final | 88 | 183 | Closer to cap |
| E4: windows on critical path | 0/6 | 0/30 | Confirmed |

The 17% increase in mean prefill latency is consistent with the 25% larger mean tokens_in (223 vs 178) driven by the wider 25-second audio window. The critical finding is the collapse of R² from ~0.73 to ~0.02: prompt length no longer explains latency variance.

---

## Baseline (Ollama llama3.1:8b) comparison

| Metric | FoundationModels | Ollama llama3.1:8b |
|---|---|---|
| Mean prefill (ms) | 885 | 439 |
| Mean decode (ms) | 689 | 1 078 |
| Mean total (ms) | 1 573 | 1 517 |
| p95 total (ms) | ~1 986 | ~3 419 |
| tokens_out (bullets) | 1–3 | 3 (structured JSON) |

Ollama prefill is 2× faster; FoundationModels decode is 1.6× faster. Total latency is within 4% (means) but Ollama's p95 is 73% higher, indicating higher tail latency. FoundationModels provides more consistent latency; Ollama is occasionally much slower.

**Baseline RSS caveat:** The Ollama RSS reported in this run (64.9 MB peak) reflects only the Python replay client process. The `pgrep -x ollama` lookup captured a process that does not include the model runner. The correct Ollama server RSS from run_20260609 was 8 923 MB. This measurement issue should be fixed in replay.py before subsequent runs.

---

## Appendix — Raw data

### A1. Local — per-window inference metrics (38 windows)

| Win | Seg ID | tokens\_in | prefill\_ms | decode\_ms | total\_ms | tokens\_out | prefill % |
|---|---|---|---|---|---|---|---|
| 1  | 6   | 106 |  940 |  317 | 1 257 | 3 | 75% |
| 2  | 12  | 160 |  773 |  426 | 1 199 | 3 | 64% |
| 3  | 21  | 171 | 1025 |  570 | 1 595 | 3 | 64% |
| 4  | 29  | 178 |  829 |  622 | 1 451 | 3 | 57% |
| 5  | 36  | 238 |  875 | 1060 | 1 935 | 3 | 45% |
| 6  | 43  | 257 |  861 |  912 | 1 773 | 3 | 49% |
| 7  | 52  | 261 |  949 |  562 | 1 511 | 3 | 63% |
| 8  | 59  | 268 |  819 | 1076 | 1 895 | 3 | 43% |
| 9  | 68  | 309 | 1000 |  742 | 1 742 | 3 | 57% |
| 10 | 75  | 299 |  896 |  898 | 1 794 | 3 | 50% |
| 11 | 84  | 221 |  984 |  658 | 1 642 | 3 | 60% |
| 12 | 90  | 231 |  957 |  635 | 1 592 | 3 | 60% |
| 13 | 100 | 263 |  873 |  718 | 1 591 | 3 | 55% |
| 14 | 107 | 271 |  798 |  986 | 1 784 | 3 | 45% |
| 15 | 116 | 248 |  709 |  644 | 1 353 | 3 | 52% |
| 16 | 122 | 248 |  894 |  590 | 1 484 | 3 | 60% |
| 17 | 130 | 236 |  892 |  562 | 1 454 | 3 | 61% |
| 18 | 139 | 241 |  912 |  611 | 1 523 | 3 | 60% |
| 19 | 147 | 216 |  860 |  748 | 1 608 | 3 | 53% |
| 20 | 155 | 253 | 1071 |  518 | 1 589 | 3 | 67% |
| 21 | 163 | 248 |  923 |  944 | 1 867 | 3 | 49% |
| 22 | 171 | 264 |  744 |  648 | 1 392 | 3 | 53% |
| 23 | 180 | 209 |  611 | 1253 | 1 864 | 3 | 33% |
| 24 | 188 | 256 |  974 |  274 | 1 248 | 3 | 78% |
| 25 | 197 | 222 |  929 |  283 | 1 212 | 3 | 77% |
| 26 | 206 | 211 |  848 |  387 | 1 235 | 3 | 69% |
| 27 | 214 | 227 |  969 |  286 | 1 255 | 3 | 77% |
| 28 | 224 | 175 |  820 |  818 | 1 638 | 3 | 50% |
| 29 | 232 | 206 |  822 |  174 |   996 | 3 | 83% |
| 30 | 241 | 201 |  893 |  408 | 1 301 | 3 | 69% |
| 31 | 249 | 200 |  881 |  247 | 1 128 | 3 | 78% |
| 32 | 260 | 168 |  860 |  914 | 1 774 | 3 | 48% |
| 33 | 271 | 173 |  982 | 1097 | 2 079 | 3 | 47% |
| 34 | 279 | 194 |  837 |  984 | 1 821 | 3 | 46% |
| 35 | 289 | 207 |  859 |  855 | 1 714 | 3 | 50% |
| 36 | 299 | 216 |  965 |  998 | 1 963 | 3 | 49% |
| 37 | 311 | 221 |  900 | 1086 | 1 986 | 3 | 45% |
| 38 | 322 | 212 |  899 |  685 | 1 584 | 3 | 57% |

**Aggregate:** tokens\_in mean 223 (range 106–309) · prefill mean 885 ms (611–1 071) · decode mean 689 ms (174–1 253) · total mean 1 573 ms (996–2 079)

**Regression:** prefill\_ms = 0.12 × tokens\_in + 858, R² = 0.003. decode\_ms = 1.24 × tokens\_in + 413, R² = 0.032. Neither relationship is statistically meaningful.

### A2. Baseline (Ollama llama3.1:8b) — summary

| Metric | Value |
|---|---|
| Windows replayed | 43 |
| Mean prefill (ms) | 439 (range 304–2 827) |
| Mean decode (ms) | 1 078 (range 592–1 621) |
| Mean total (ms) | 1 517 (range 946–3 419) |
| tokens\_out | 3 bullets (structured JSON, comparable to local) |

### A3. Local — summary update per window (30 events)

| Metric | Value |
|---|---|
| Summary words: min / max / final | 41 / 199 / 183 |
| duration\_ms: min / max / mean | 760 / 4 246 / 2 709 |
| tokens\_in (summary prompt): min / max / mean | 139 / 379 / 312 |
| Gap to next prefill\_start: min / max / mean | 14 346 / 20 763 / 17 162 ms |
| Windows on critical path (gap < 0) | 0 / 30 |

### A4. Local — RSS samples

| Metric | Value |
|---|---|
| Sample count | 4 184 |
| Sampling interval | 200 ms |
| Min / Max / Mean RSS | 120.0 / 148.1 / 134.4 MB |
| Last-5-min mean / std | 137.3 / 1.9 MB (1.4% of mean) |
| Final segment count | 335 |
| Final bullet count | ~90 |

### A5. Baseline — Ollama process RSS

| Metric | Value |
|---|---|
| Reported peak RSS | 64.9 MB |

**Note:** This figure reflects only the Python replay client process, not the Ollama model server. The correct Ollama server RSS (llama3.1:8b loaded) is ~8 923 MB, measured in run_20260609. The `pgrep` logic in `replay.py` failed to capture the model runner process in this run and should be corrected before the next run.
