# Recap — Experiment Plan

## Hypothesis

Since this application will run locally, the primary bottleneck will be **prefill** during summarization, where the whole prompt (includes transcribed audio) is used to build the initial KV cache. Memory will **not** be a bottleneck because the rolling summary stays at a relatively fixed size; it does not grow linearly with session length. However, latency will depend on the number of tokens that can be processed per second. One potential optimization is to run the summary-update agent **in parallel** with the next audio window being buffered, rather than sequentially.

## Roles

| Task | Who |
|---|---|
| Generate reference JSONL (run the app for 15 min) | David |
| FoundationModels metrics already in that JSONL | David |
| Run Ollama / vLLM baseline replay | Staff |
| Run analysis + plots | Either |

Staff never need the macOS app, raw audio, or Apple Intelligence. They only need the reference JSONL, Python ≥ 3.11, and an inference backend.

---

## Reference Data

**David generates one 15-minute reference session** using the Recap app (mic or file playback). The JSONL this produces contains:
- `segment_end` events — the full transcript
- `prefill_start` events — the exact system prompt + planner prompt sent to FoundationModels for each 10-second window (this is what staff replay against Ollama/vLLM)
- `first_token`, `decode_end` — FoundationModels latency per window
- `rss_sample` — app RSS every 200 ms
- `summary_update` — words in rolling summary + duration_ms + tokens_in after each window

Copy the session file from the app container to the repo:
```bash
cp ~/Library/Containers/com.thrillersolutions.Recap/Data/Library/\
Application\ Support/Recap/Runs/session_<ts>.jsonl \
Runs/transcript_ref.jsonl
```

**Minimum acceptance criteria before handing off:**
- `summary_update` events show `words` reaching ≥ 400 (summary cap engaged)
- ≥ 20 `prefill_start` events (≥ 20 summarization windows)
- `tokens_in` in `prefill_start` events is stable or slightly declining in the last 5 windows

---

## Conditions

| ID | Backend | Model | Command |
|---|---|---|---|
| `local` | Apple FoundationModels | Apple Intelligence default | (already in reference JSONL) |
| `ollama-8b` | Ollama | `llama3.1:8b` | see Step 2 |
| `vllm-3b` | vLLM (GPU server) | `meta-llama/Llama-3.2-3B-Instruct` | see Step 2 |

---

## Execution Steps

### Step 0 — Setup (Staff, once)

```bash
git clone <repo>
cd Recap

# Mac
bash Eval/setup_mac.sh
pip install -r Eval/requirements.txt

# GPU server
bash Eval/setup_gpu.sh
pip install -r Eval/requirements.txt
```

### Step 1 — Baseline replay (Staff)

```bash
# Mac / Ollama (must have ollama serve running)
python Eval/replay.py \
  --input   Runs/transcript_ref.jsonl \
  --output  Runs/baseline_ollama_8b.jsonl \
  --model   llama3.1:8b

# GPU / vLLM
python Eval/replay.py \
  --input    Runs/transcript_ref.jsonl \
  --output   Runs/baseline_vllm_3b.jsonl \
  --base-url http://<gpu-ip>:8000/v1 \
  --api-key  EMPTY \
  --backend  vllm \
  --model    meta-llama/Llama-3.2-3B-Instruct
```

`replay.py` samples the backend process RSS every 200 ms and writes `rss_sample` events into the output JSONL automatically.

### Step 2 — Analysis (Either)

```bash
python Eval/analyze.py \
  --local    Runs/transcript_ref.jsonl \
  --baseline Runs/baseline_ollama_8b.jsonl \
  --out      Report/results.csv

python Eval/plot.py \
  --local    Runs/transcript_ref.jsonl \
  --baseline Runs/baseline_ollama_8b.jsonl \
  --outdir   Report/figures
```

---

## Claims and Success Criteria

### E1 — Prefill is the primary bottleneck

**Metric:** `prefill_ms` and `decode_ms` per window; scatter of `prefill_ms` vs `tokens_in`

**How to read:** Plot `prefill_ms` vs `tokens_in` for both conditions. Fit a line. If R² > 0.85, prefill time is driven by input length, not by decode throughput.

**Success:**
- `prefill_ms > decode_ms` in > 80% of windows across both conditions
- Linear regression of `prefill_ms ~ tokens_in` has R² > 0.85
- Slope is positive and roughly equal across conditions (same input-processing cost)

**Figure:** `Report/figures/prefill_scaling.png` — scatter + regression line, one series per condition

---

### E2 — Memory does not grow linearly with session length

**Metric:** `rss_sample.rss_mb` and `rss_sample.segment_count` over session time

**How to read:** Plot RSS (left axis) and segment_count (right axis) vs time. RSS should plateau even as segment_count grows linearly.

**Success:**
- RSS standard deviation in the **last 5 minutes** < 15% of the mean in that period
- RSS does **not** correlate with `segment_count` (Pearson r < 0.3 after the first 2 minutes)
- FoundationModels peak RSS < 200 MB; Ollama/vLLM peak RSS reported separately (server process)

**Figure:** `Report/figures/rss_plateau.png` — dual-axis: RSS and segment_count vs session time

---

### E3 — tokens_in stabilizes once the summary cap engages

**Metric:** `prefill_start.tokens_in` per window over session time; `summary_update.words` per window

**How to read:** Plot `tokens_in` and `summary_update.words` on the same time axis. The hypothesis predicts that once `words` stops growing (summary cap engaged), `tokens_in` stops growing too.

**Success:**
- `summary_update.words` reaches ≤ 50 and stays within ± 10 words for the last 5 windows
- `tokens_in` growth rate in the last 5 windows is < 5 tokens/window

**Figure:** `Report/figures/tokens_plateau.png` — `tokens_in` and `summary.words` vs window index, dual axis

---

### E4 — Parallel summary update provides negligible benefit

**Metric:** `summary_update.duration_ms` vs inter-window gap (time from `summary_update` completion to next `prefill_start`)

**How to read:** For each window, compute:
```
gap_ms = next_prefill_start.ts − this_summary_update.ts
```
If `gap_ms > 0` consistently, the summary update finishes before the next window fires — it is **not** on the critical path, and parallelizing it would save nothing.

**Success:**
- `gap_ms > 0` in > 80% of windows
- Mean `gap_ms` > mean `summary_update.duration_ms` (summary fits inside the inter-window idle time)

**Figure:** `Report/figures/summary_gap.png` — bar chart per window: `summary_update.duration_ms` (filled) and `gap_ms` (outline), showing overlap or headroom

---

## What needs to be built before running

The following analysis extensions are not yet in `analyze.py` / `plot.py`. These need to be added before Step 2 produces meaningful output for E1–E4:

| Item | File | Status |
|---|---|---|
| E1 scatter: `prefill_ms` vs `tokens_in` + regression | `plot.py` | TODO |
| E2 dual-axis: RSS + `segment_count` vs time | `plot.py` | TODO |
| E3 dual-axis: `tokens_in` + `summary.words` vs window | `plot.py` | TODO |
| E4 bar chart: `summary_update.duration_ms` vs `gap_ms` | `plot.py` | TODO |
| E4 gap computation in CSV | `analyze.py` | TODO |
| RSS sampling in `replay.py` | `replay.py` | **Done** |
| `summary_update.duration_ms` logged by app | `SummaryStore.swift` | **Done** |
| `rss_sample.segment_count` + `bullet_count` logged | `RSSSampler.swift` | **Done** |
| Prompt-echo bullet filter | `RecapModel.swift` | **Done** |

---

## Known issues

**Prior-bullets echo:** In early sessions the model occasionally generated `"Prior bullets"` as a bullet text (echoing the prompt label). This was stored and re-injected into subsequent prompts, inflating `tokens_in`. A filter now rejects bullets that match prompt scaffolding labels or are < 4 words. Regenerate the reference JSONL after this fix is deployed.

**FoundationModels RSS underreports model weight cost:** The model weights are shared with the OS-level Apple Intelligence runtime and do not appear in the app's `rss_sample` readings. The reported ~136 MB is the app's heap + stack only. This is a known limitation; note it when comparing RSS figures between conditions.

**`tokens_in` is a word-count approximation:** Both the Swift app (`prompt.split(separator: " ").count`) and `replay.py` use word count, not a tokenizer. This is consistent across conditions and sufficient for trend analysis, but absolute values should not be compared to reported context-window sizes in tokens.
