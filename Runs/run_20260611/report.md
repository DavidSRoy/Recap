# Run Report — 2026-06-11

## Metadata

| Field | Value |
|---|---|
| Date | 2026-06-11 |
| Duration | 383 s (6.4 min) |
| ASR segments | 54 |
| Windows completed | 18 |
| Window cadence | 20 s |
| Audio window | 25 s |
| Summary cap | **50 words** |
| Summary in planner prompt | No |
| Local backend | Apple FoundationModels |
| Baseline backend | Ollama `llama3.1:8b` (pre-warmed) |

**vs run_20260610:** summary cap 200→50 words. All other parameters unchanged.

---

## Findings

| Claim | Verdict |
|---|---|
| E1 — Prefill is the primary bottleneck | **Confirmed** — prefill 911 ms (59% of total), R² = 0.007 |
| E2 — Memory is not a bottleneck | **Confirmed** — RSS 3.7% std over last 5 min |
| E3 — tokens\_in stabilises once summary is bounded | **Confirmed** — 50-word cap engaged by window 8; tokens\_in bounded throughout |
| E4 — Parallel summary is not on the critical path | **Confirmed** — 0/15 on critical path, 17× gap headroom |

---

## E1 — Prefill is the primary bottleneck

**Confirmed.** Prefill averages 911 ms (59% of total) vs decode 625 ms. No correlation with tokens\_in (R² = 0.007). Mean total latency 1 536 ms is consistent with run_20260610 (1 574 ms).

![Prefill scaling](figures/prefill_scaling.png)

---

## E2 — Memory is not a bottleneck

**Confirmed.** RSS held at 121–143 MB (mean 131 MB) while segment count grew to 54. Last-5-min std 4.9 MB (3.7% of mean).

![RSS plateau](figures/rss_plateau.png)

---

## E3 — tokens\_in stabilises once summary is bounded

**Confirmed.** Summary grew from 23 to 50 words (cap) by window 8 and held there for windows 9–18. tokens\_in ranged 96–299 (mean 213) with no trend throughout — consistent with the architectural result from run_20260610: the bound comes from removing the summary from the planner prompt, not from the cap itself. The cap bounds summary-update prompt size and latency.

![Tokens plateau](figures/tokens_plateau.png)

---

## E4 — Parallel summary is not on the critical path

**Confirmed.** Summary update duration 556–1 974 ms (mean 1 153 ms). Gap to next prefill 17 018–23 152 ms (mean 20 157 ms). 0/15 on critical path. Gap is 17× mean summary duration. Lower summary duration than run_20260610 (1 153 vs 2 709 ms) because the 50-word cap keeps the summary-update prompt small.

![Summary gap](figures/summary_gap.png)

---

## Backend comparison

| Metric | FoundationModels | Ollama llama3.1:8b |
|---|---|---|
| Windows | 18 | 18 |
| Mean prefill (ms) | 911 | 376 |
| Mean decode (ms) | 625 | 1 044 |
| Mean total (ms) | 1 536 | 1 421 |
| p95 total (ms) | 1 599 | 1 599 |
| RSS | 131 MB | 9 438 MB (warm) |

Ollama prefill is 2.4× faster; FoundationModels decode is 1.7× faster. Total latency within 8%; p95 identical.

---

## Appendix

### Latency — aggregate

| | FoundationModels | Ollama |
|---|---|---|
| tokens\_in mean (range) | 213 (96–299) | 221 (100–307) |
| prefill mean (range) ms | 911 (418–1 075) | 376 (305–527) |
| decode mean (range) ms | 625 (49–1 174) | 1 044 (769–1 265) |
| total mean (range) ms | 1 536 (780–2 235) | 1 421 (1 118–1 599) |
| prefill regression | 0.28 ms/token, R² = 0.007 | — |
| decode regression | 4.69 ms/token, R² = 0.499 | — |

### RSS

| | FoundationModels | Ollama (warm) |
|---|---|---|
| Mean / peak (MB) | 131 / 143 | 9 438 / 9 867 |
| Samples | 1 910 | 109 |
| Last-5-min std | 4.9 MB (3.7%) | — |

### Summary updates (15 events)

| Metric | Value |
|---|---|
| words: min / max / final | 23 / 50 / 50 |
| duration\_ms: min / max / mean | 556 / 1 974 / 1 153 |
| tokens\_in (summary prompt): min / max / mean | 133 / 226 / 190 |
| gap to next prefill: min / max / mean ms | 17 018 / 23 152 / 20 157 |
| on critical path | 0 / 15 |
