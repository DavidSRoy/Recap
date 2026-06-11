#!/usr/bin/env python3
"""
Generate figures from Recap JSONL files.

  ttft.png            — TTFT per window, local vs baseline
  rss.png             — App RSS over session time (local only)
  prefill_scaling.png — E1: prefill_ms vs tokens_in scatter + regression
  rss_plateau.png     — E2: RSS + cumulative segment count vs time
  tokens_plateau.png  — E3: tokens_in + summary words vs window index
  summary_gap.png     — E4: summary-update duration vs gap to next window

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


# ── I/O helpers ───────────────────────────────────────────────────────────────

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


def t0_of(events: list) -> float:
    t = next((parse_ms(e["ts"]) for e in events if e.get("event") == "audio_start"), None)
    if t is None:
        t = next((parse_ms(e["ts"]) for e in events if e.get("event") == "prefill_start"), None)
    return t or parse_ms(events[0]["ts"])


# ── Data extractors ───────────────────────────────────────────────────────────

def ttft_series(events: list) -> tuple:
    t0 = t0_of(events)
    prefill_ts: dict = {}
    wall, ms_vals = [], []
    for e in events:
        name, ts, sid = e.get("event"), parse_ms(e["ts"]), e.get("segment_id")
        if name == "prefill_start":
            prefill_ts[sid] = ts
        elif name == "first_token" and sid in prefill_ts:
            pm = ts - prefill_ts.pop(sid)
            if pm > 0:
                wall.append((ts - t0) / 1000)
                ms_vals.append(pm)
    return wall, ms_vals


def decode_series(events: list) -> tuple:
    """Returns (wall_s, decode_ms_list) relative to t0."""
    t0 = t0_of(events)
    first_ts: dict = {}
    wall, ms_vals = [], []
    for e in events:
        name, ts, sid = e.get("event"), parse_ms(e["ts"]), e.get("segment_id")
        if name == "first_token":
            first_ts[sid] = ts
        elif name == "decode_end" and sid in first_ts:
            dm = ts - first_ts.pop(sid)
            if dm > 0:
                wall.append((ts - t0) / 1000)
                ms_vals.append(dm)
    return wall, ms_vals


def rss_series(events: list) -> tuple:
    t0 = t0_of(events)
    times, rss = [], []
    for e in events:
        if e.get("event") == "rss_sample" and "rss_mb" in e:
            times.append((parse_ms(e["ts"]) - t0) / 1000)
            rss.append(e["rss_mb"])
    return times, rss


def prefill_vs_tokens(events: list) -> tuple:
    """Returns (tokens_in_list, prefill_ms_list) per window, ordered by window."""
    prefill_ts: dict = {}
    first_ts: dict   = {}
    rows = []
    for e in events:
        name, ts, sid = e.get("event"), parse_ms(e["ts"]), e.get("segment_id")
        if name == "prefill_start":
            prefill_ts[sid] = ts
        elif name == "first_token" and sid in prefill_ts:
            first_ts[sid] = ts
        elif name == "decode_end" and sid in first_ts:
            pm = first_ts.pop(sid) - prefill_ts.pop(sid)
            tin = e.get("tokens_in", 0)
            if pm > 0 and tin > 0:
                rows.append((tin, pm))
    rows.sort()
    if not rows:
        return [], []
    tokens, prefills = zip(*rows)
    return list(tokens), list(prefills)


def tokens_and_words_series(events: list) -> tuple:
    """Returns (window_indices, tokens_in_list, summary_words_list)."""
    decode_events  = [e for e in events if e.get("event") == "decode_end"]
    summary_events = [e for e in events if e.get("event") == "summary_update"]
    indices, tokens, words = [], [], []
    for i, d in enumerate(decode_events):
        tin = d.get("tokens_in", 0)
        w   = summary_events[i]["words"] if i < len(summary_events) else None
        if tin > 0:
            indices.append(i + 1)
            tokens.append(tin)
            words.append(w)
    return indices, tokens, words


def segment_count_series(events: list) -> tuple:
    """Returns (wall_s, cumulative_segment_count) from segment_end events."""
    t0 = t0_of(events)
    times, counts = [], []
    count = 0
    for e in sorted(events, key=lambda x: parse_ms(x["ts"])):
        if e.get("event") == "segment_end":
            count += 1
            times.append((parse_ms(e["ts"]) - t0) / 1000)
            counts.append(count)
    return times, counts


def summary_gap_series(events: list) -> tuple:
    """
    For each window returns (window_index, su_duration_ms, gap_ms).
    su_duration_ms ≈ summary_update.ts - decode_end.ts (approximation until
    SummaryStore logs duration_ms directly).
    gap_ms = next prefill_start.ts - summary_update.ts  (negative = on critical path).
    """
    decode_events   = [e for e in events if e.get("event") == "decode_end"]
    summary_events  = [e for e in events if e.get("event") == "summary_update"]
    prefill_events  = [e for e in events if e.get("event") == "prefill_start"]

    rows = []
    for i, (d, s) in enumerate(zip(decode_events, summary_events)):
        # Prefer logged duration_ms if present (new schema), else approximate.
        if "duration_ms" in s:
            su_ms = s["duration_ms"]
        else:
            su_ms = parse_ms(s["ts"]) - parse_ms(d["ts"])

        gap_ms = None
        if i + 1 < len(prefill_events):
            gap_ms = parse_ms(prefill_events[i + 1]["ts"]) - parse_ms(s["ts"])

        rows.append((i + 1, su_ms, gap_ms))
    return rows


# ── Pure-Python linear regression ─────────────────────────────────────────────

def linreg(xs: list, ys: list) -> tuple:
    """Returns (slope, intercept, r_squared)."""
    n = len(xs)
    if n < 2:
        return 0, 0, 0
    mx, my = sum(xs) / n, sum(ys) / n
    ss_xy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    ss_xx = sum((x - mx) ** 2 for x in xs)
    ss_yy = sum((y - my) ** 2 for y in ys)
    if ss_xx == 0:
        return 0, my, 0
    slope = ss_xy / ss_xx
    intercept = my - slope * mx
    r2 = (ss_xy ** 2 / (ss_xx * ss_yy)) if ss_yy > 0 else 0
    return slope, intercept, r2


# ── Figure functions ──────────────────────────────────────────────────────────

def fig_ttft(local_events, baseline_events, outdir):
    lw, lm = ttft_series(local_events)
    bw, bm = ttft_series(baseline_events)

    fig, ax = plt.subplots(figsize=(9, 4))
    if lw:
        ax.scatter(lw, lm, label="FoundationModels", marker="o", s=70, zorder=3, color="#1f77b4")
    if bw:
        ax.scatter(bw, bm, label="Ollama / vLLM",    marker="^", s=70, zorder=3, color="#ff7f0e")
    ax.set_xlabel("Session time (s)")
    ax.set_ylabel("TTFT (ms)")
    ax.set_title("Time to First Token per Window")
    ax.legend()
    ax.grid(True, alpha=0.3)
    ax.yaxis.set_minor_locator(ticker.AutoMinorLocator())
    fig.tight_layout()
    _save(fig, outdir / "ttft.png")


def fig_rss(local_events, outdir):
    times, rss = rss_series(local_events)
    if not times:
        print("No rss_sample events — skipping rss.png")
        return
    fig, ax = plt.subplots(figsize=(9, 3))
    ax.plot(times, rss, linewidth=1.2, color="#1f77b4")
    ax.set_xlabel("Session time (s)")
    ax.set_ylabel("RSS (MB)")
    ax.set_title("App Resident Set Size — FoundationModels")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    _save(fig, outdir / "rss.png")


def fig_prefill_scaling(local_events, baseline_events, outdir):
    """E1 — prefill_ms vs tokens_in scatter + regression."""
    lt, lp = prefill_vs_tokens(local_events)
    bt, bp = prefill_vs_tokens(baseline_events)

    fig, ax = plt.subplots(figsize=(8, 5))

    for tokens, prefills, label, color, marker in [
        (lt, lp, "FoundationModels", "#1f77b4", "o"),
        (bt, bp, "Ollama / vLLM",    "#ff7f0e", "^"),
    ]:
        if not tokens:
            continue
        ax.scatter(tokens, prefills, label=label, marker=marker, s=80, zorder=3, color=color)
        slope, intercept, r2 = linreg(tokens, prefills)
        if r2 > 0:
            xs = [min(tokens), max(tokens)]
            ys = [slope * x + intercept for x in xs]
            ax.plot(xs, ys, color=color, linewidth=1.4, linestyle="--",
                    label=f"{label} fit (R²={r2:.2f})")

    ax.set_xlabel("Input tokens (words)")
    ax.set_ylabel("Prefill latency / TTFT (ms)")
    ax.set_title("E1 — Prefill Latency Scales with Input Length")
    ax.legend(fontsize=8)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    _save(fig, outdir / "prefill_scaling.png")


def fig_rss_plateau(local_events, outdir):
    """E2 — RSS (left axis) + cumulative segment count (right axis) vs session time."""
    rtimes, rss = rss_series(local_events)
    stimes, scounts = segment_count_series(local_events)

    if not rtimes:
        print("No rss_sample events — skipping rss_plateau.png")
        return

    fig, ax1 = plt.subplots(figsize=(9, 4))
    ax1.plot(rtimes, rss, linewidth=1.2, color="#1f77b4", label="RSS (MB)")
    ax1.set_xlabel("Session time (s)")
    ax1.set_ylabel("RSS (MB)", color="#1f77b4")
    ax1.tick_params(axis="y", labelcolor="#1f77b4")
    ax1.grid(True, alpha=0.2)

    if stimes:
        ax2 = ax1.twinx()
        ax2.step(stimes, scounts, linewidth=1.2, color="#2ca02c",
                 linestyle="--", where="post", label="Segments in memory")
        ax2.set_ylabel("Cumulative segments", color="#2ca02c")
        ax2.tick_params(axis="y", labelcolor="#2ca02c")

    ax1.set_title("E2 — RSS vs Segment Count (memory plateau test)")
    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = (ax2.get_legend_handles_labels() if stimes else ([], []))
    ax1.legend(lines1 + lines2, labels1 + labels2, loc="lower right", fontsize=8)
    fig.tight_layout()
    _save(fig, outdir / "rss_plateau.png")


def fig_tokens_plateau(local_events, outdir):
    """E3 — tokens_in (left) + summary word count (right) vs window index."""
    indices, tokens, words = tokens_and_words_series(local_events)
    if not indices:
        print("No decode_end events — skipping tokens_plateau.png")
        return

    fig, ax1 = plt.subplots(figsize=(8, 4))
    ax1.plot(indices, tokens, marker="o", linewidth=1.4, color="#1f77b4",
             label="tokens_in (prompt size)")
    ax1.set_xlabel("Window index")
    ax1.set_ylabel("Input tokens (words)", color="#1f77b4")
    ax1.tick_params(axis="y", labelcolor="#1f77b4")
    ax1.grid(True, alpha=0.2)

    word_vals = [w for w in words if w is not None]
    word_idx  = [indices[i] for i, w in enumerate(words) if w is not None]
    if word_vals:
        ax2 = ax1.twinx()
        ax2.plot(word_idx, word_vals, marker="s", linewidth=1.4, color="#d62728",
                 linestyle="--", label="Summary words")
        ax2.axhline(500, color="#d62728", linewidth=0.8, linestyle=":", alpha=0.5,
                    label="500-word cap")
        ax2.set_ylabel("Summary word count", color="#d62728")
        ax2.tick_params(axis="y", labelcolor="#d62728")

    ax1.set_title("E3 — Prompt Size and Summary Growth per Window")
    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = (ax2.get_legend_handles_labels() if word_vals else ([], []))
    ax1.legend(lines1 + lines2, labels1 + labels2, loc="upper left", fontsize=8)
    fig.tight_layout()
    _save(fig, outdir / "tokens_plateau.png")


def fig_summary_gap(local_events, outdir):
    """E4 — summary-update duration vs gap to next window (critical-path test)."""
    rows = summary_gap_series(local_events)
    rows_with_gap = [(i, su, gap) for i, su, gap in rows if gap is not None]
    if not rows_with_gap:
        print("Not enough windows for E4 — skipping summary_gap.png")
        return

    indices = [r[0] for r in rows_with_gap]
    su_ms   = [r[1] for r in rows_with_gap]
    gap_ms  = [r[2] for r in rows_with_gap]

    x = range(len(indices))
    width = 0.35

    fig, ax = plt.subplots(figsize=(8, 4))
    bars1 = ax.bar([i - width/2 for i in x], su_ms,  width, label="Summary update (ms)", color="#ff7f0e", alpha=0.85)
    bars2 = ax.bar([i + width/2 for i in x], gap_ms, width, label="Gap to next window (ms)", color="#1f77b4", alpha=0.85)

    ax.axhline(0, color="black", linewidth=0.6)
    ax.set_xticks(list(x))
    ax.set_xticklabels([f"W{i}" for i in indices])
    ax.set_xlabel("Window")
    ax.set_ylabel("Time (ms)")
    ax.set_title("E4 — Summary Update vs Gap to Next Window\n"
                 "(positive gap = summary not on critical path)")
    ax.legend(fontsize=8)
    ax.grid(True, alpha=0.2, axis="y")

    on_cp = sum(1 for g in gap_ms if g < 0)
    ax.text(0.98, 0.97,
            f"On critical path: {on_cp}/{len(gap_ms)} windows",
            transform=ax.transAxes, ha="right", va="top", fontsize=8,
            bbox=dict(boxstyle="round,pad=0.3", facecolor="white", alpha=0.7))

    fig.tight_layout()
    _save(fig, outdir / "summary_gap.png")


# ── Utility ───────────────────────────────────────────────────────────────────

def _save(fig, path: Path):
    fig.savefig(path, dpi=150)
    print(f"Saved {path}")
    plt.close(fig)


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--local",    required=True)
    ap.add_argument("--baseline", required=True)
    ap.add_argument("--outdir",   default="Report/figures")
    args = ap.parse_args()

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    local    = load_events(Path(args.local))
    baseline = load_events(Path(args.baseline))

    fig_ttft(local, baseline, outdir)
    fig_rss(local, outdir)
    fig_prefill_scaling(local, baseline, outdir)
    fig_rss_plateau(local, outdir)
    fig_tokens_plateau(local, outdir)
    fig_summary_gap(local, outdir)


if __name__ == "__main__":
    main()
