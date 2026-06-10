#!/usr/bin/env python3
"""
Generate two figures from Recap JSONL files:

  ttft.png — TTFT per 60-second window, local FoundationModels vs baseline.
  rss.png  — Resident set size over session time (local only).

Usage:
    python Eval/plot.py \\
        --local    Runs/session_<ts>.jsonl \\
        --baseline Runs/baseline_<ts>.jsonl \\
        --outdir   Report/figures
"""

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.ticker as ticker
except ImportError:
    sys.exit("matplotlib required — run: pip install -r Eval/requirements.txt")


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


def parse_ms(ts: str) -> float:
    return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp() * 1000


def ttft_series(events: list) -> tuple:
    """
    Returns (wall_times_s, prefill_ms_list) relative to the first audio_start event.
    Skips windows with prefill_ms <= 0 (fallback path, TTFT unmeasurable).
    """
    t0 = next(
        (parse_ms(e["ts"]) for e in events if e.get("event") == "audio_start"),
        None,
    )
    prefill_ts: dict = {}
    wall, ms_vals = [], []

    for e in events:
        name = e.get("event")
        ts   = parse_ms(e["ts"])
        sid  = e.get("segment_id")

        if t0 is None and name == "prefill_start":
            t0 = ts  # fallback anchor if no audio_start

        if name == "prefill_start":
            prefill_ts[sid] = ts
        elif name == "first_token" and sid in prefill_ts:
            prefill_ms = ts - prefill_ts.pop(sid)
            if prefill_ms > 0:
                wall.append((ts - t0) / 1000)
                ms_vals.append(prefill_ms)

    return wall, ms_vals


def rss_series(events: list) -> tuple:
    """Returns (wall_times_s, rss_mb_list) relative to audio_start."""
    t0 = next(
        (parse_ms(e["ts"]) for e in events if e.get("event") == "audio_start"),
        None,
    )
    times, rss = [], []
    for e in events:
        if e.get("event") == "rss_sample" and "rss_mb" in e:
            ts = parse_ms(e["ts"])
            if t0 is None:
                t0 = ts
            times.append((ts - t0) / 1000)
            rss.append(e["rss_mb"])
    return times, rss


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--local",    required=True, help="FoundationModels session JSONL")
    ap.add_argument("--baseline", required=True, help="Baseline (Ollama/vLLM) JSONL")
    ap.add_argument("--outdir",   default="Report/figures")
    args = ap.parse_args()

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    local_events    = load_events(Path(args.local))
    baseline_events = load_events(Path(args.baseline))

    # ── Figure 1: TTFT per window ──────────────────────────────────────────────
    fig, ax = plt.subplots(figsize=(9, 4))

    lw, lm = ttft_series(local_events)
    bw, bm = ttft_series(baseline_events)

    if lw:
        ax.scatter(lw, lm, label="FoundationModels (Neural Engine)",
                   marker="o", s=70, zorder=3, color="#1f77b4")
    if bw:
        ax.scatter(bw, bm, label="Ollama / vLLM",
                   marker="^", s=70, zorder=3, color="#ff7f0e")

    if not lw and not bw:
        print("Warning: no TTFT data found in either JSONL — ttft.png will be empty")

    ax.set_xlabel("Session time (s)")
    ax.set_ylabel("TTFT (ms)")
    ax.set_title("Time to First Token per 60-second Window")
    ax.legend()
    ax.grid(True, alpha=0.3)
    ax.yaxis.set_minor_locator(ticker.AutoMinorLocator())
    fig.tight_layout()

    p = outdir / "ttft.png"
    fig.savefig(p, dpi=150)
    print(f"Saved {p}")
    plt.close(fig)

    # ── Figure 2: RSS over time (local only) ──────────────────────────────────
    times, rss = rss_series(local_events)
    if not times:
        print("No rss_sample events in local JSONL — skipping rss.png")
        return

    fig, ax = plt.subplots(figsize=(9, 3))
    ax.plot(times, rss, linewidth=1.2, color="#1f77b4")
    ax.set_xlabel("Session time (s)")
    ax.set_ylabel("RSS (MB)")
    ax.set_title("Resident Set Size — FoundationModels (Neural Engine)")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()

    p = outdir / "rss.png"
    fig.savefig(p, dpi=150)
    print(f"Saved {p}")
    plt.close(fig)


if __name__ == "__main__":
    main()
