#!/usr/bin/env python3
"""
Compute per-window latency metrics from two Recap JSONL files and write results.csv.

Reads prefill_start / first_token / decode_end events, correlates by segment_id,
and computes TTFT (prefill_ms), decode latency, tokens/sec, and peak RSS.

Usage:
    python Eval/analyze.py \\
        --local    Runs/session_<ts>.jsonl \\
        --baseline Runs/baseline_<ts>.jsonl \\
        --out      Report/results.csv
"""

import argparse
import csv
import json
import statistics
from datetime import datetime, timezone
from pathlib import Path


def load_events(path: Path) -> list:
    events = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    events.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return events


def parse_ts_ms(ts: str) -> float:
    """ISO 8601 timestamp → milliseconds since epoch."""
    return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp() * 1000


def window_metrics(events: list) -> list:
    """
    Correlate prefill_start / first_token / decode_end triples by segment_id.
    Returns one dict per completed window.

    Windows where prefill_ms <= 0 are skipped — these come from the non-streaming
    fallback path in SummarizerClient where TTFT is not independently measurable.
    """
    prefill_ts: dict     = {}
    first_token_ts: dict = {}
    results = []

    for e in events:
        name = e.get("event")
        sid  = e.get("segment_id")
        ts   = parse_ts_ms(e["ts"])

        if name == "prefill_start":
            prefill_ts[sid] = ts

        elif name == "first_token" and sid in prefill_ts:
            first_token_ts[sid] = ts

        elif name == "decode_end" and sid in first_token_ts:
            prefill_ms = first_token_ts[sid] - prefill_ts[sid]
            decode_ms  = ts - first_token_ts[sid]

            # Skip fallback-path events (prefill_ms ≤ 0 → TTFT was not measurable).
            if prefill_ms <= 0:
                prefill_ts.pop(sid, None)
                first_token_ts.pop(sid, None)
                continue

            tokens_in  = e.get("tokens_in",  0)
            tokens_out = e.get("tokens_out", 0)
            tps = (tokens_out / (decode_ms / 1000)) if decode_ms > 0 else 0.0

            results.append({
                "segment_id": sid,
                "prefill_ms": prefill_ms,
                "decode_ms":  decode_ms,
                "total_ms":   prefill_ms + decode_ms,
                "tps_out":    tps,
                "tokens_in":  tokens_in,
                "tokens_out": tokens_out,
            })
            prefill_ts.pop(sid, None)
            first_token_ts.pop(sid, None)

    return results


def p95(vals: list) -> float:
    if not vals:
        return 0.0
    s = sorted(vals)
    return s[min(int(len(s) * 0.95), len(s) - 1)]


def summarize(metrics: list, label: str) -> dict:
    if not metrics:
        print(f"  warning: no measurable windows in '{label}'")
        return {
            "run": label,
            "n_windows": 0,
            "mean_prefill_ms": 0, "p95_prefill_ms": 0,
            "mean_decode_ms":  0, "p95_decode_ms":  0,
            "mean_tps_out": 0, "mean_tokens_in": 0,
            "peak_rss_mb": 0,
        }

    prefill = [m["prefill_ms"] for m in metrics]
    decode  = [m["decode_ms"]  for m in metrics]
    tps     = [m["tps_out"]    for m in metrics if m["tps_out"] > 0]
    tin     = [m["tokens_in"]  for m in metrics]

    return {
        "run":             label,
        "n_windows":       len(metrics),
        "mean_prefill_ms": round(statistics.mean(prefill), 1),
        "p95_prefill_ms":  round(p95(prefill), 1),
        "mean_decode_ms":  round(statistics.mean(decode), 1),
        "p95_decode_ms":   round(p95(decode), 1),
        "mean_tps_out":    round(statistics.mean(tps), 2) if tps else 0.0,
        "mean_tokens_in":  round(statistics.mean(tin), 1),
        "peak_rss_mb":     0.0,  # filled in from rss_sample events below
    }


def peak_rss_mb(events: list) -> float:
    vals = [e["rss_mb"] for e in events
            if e.get("event") == "rss_sample" and "rss_mb" in e]
    return round(max(vals), 1) if vals else 0.0


FIELDS = [
    "run", "n_windows",
    "mean_prefill_ms", "p95_prefill_ms",
    "mean_decode_ms",  "p95_decode_ms",
    "mean_tps_out", "mean_tokens_in", "peak_rss_mb",
]


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--local",    required=True, help="FoundationModels session JSONL")
    ap.add_argument("--baseline", required=True, help="Ollama/vLLM replay JSONL")
    ap.add_argument("--out",      default="Report/results.csv", help="Output CSV path")
    args = ap.parse_args()

    print(f"Loading {args.local} …")
    local_events = load_events(Path(args.local))
    print(f"Loading {args.baseline} …")
    baseline_events = load_events(Path(args.baseline))

    local_row    = summarize(window_metrics(local_events),    "FoundationModels (Neural Engine)")
    baseline_row = summarize(window_metrics(baseline_events), "Ollama / vLLM")

    local_row["peak_rss_mb"]    = peak_rss_mb(local_events)
    baseline_row["peak_rss_mb"] = peak_rss_mb(baseline_events)

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        w.writerow(local_row)
        w.writerow(baseline_row)

    print(f"\nWrote {out_path}\n")

    # ── Console summary table ──────────────────────────────────────────────────
    w = 28
    print(f"{'Metric':<{w}} {'Local (FM)':>20} {'Baseline':>20}")
    print("─" * (w + 42))
    for key in FIELDS[1:]:
        lv = local_row.get(key, "—")
        bv = baseline_row.get(key, "—")
        if isinstance(lv, float):
            print(f"{key:<{w}} {lv:>20.1f} {bv:>20.1f}")
        else:
            print(f"{key:<{w}} {str(lv):>20} {str(bv):>20}")


if __name__ == "__main__":
    main()
