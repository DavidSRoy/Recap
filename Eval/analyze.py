#!/usr/bin/env python3
"""Analyze JSONL session logs and produce results.csv."""
import argparse
import csv
import json
from datetime import datetime
from pathlib import Path


def parse_events(path: Path) -> list[dict]:
    events = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                events.append(json.loads(line))
    return events


def ts_to_ms(ts: str) -> float:
    dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    return dt.timestamp() * 1000


def analyze(paths: list[Path], out: Path):
    # TODO Day 5: implement full latency/tps/rss analysis
    print(f"Analyzing {len(paths)} session(s)…")
    rows = []
    for path in paths:
        events = parse_events(path)
        print(f"  {path.name}: {len(events)} events")
        rows.append({
            "run": path.stem,
            "model": "local",
            "mean_latency_ms": 0,
            "p95_latency_ms": 0,
            "tps_out": 0,
            "peak_rss_mb": 0,
        })
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)
    print(f"Wrote {out}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("logs", nargs="+", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    analyze(args.logs, args.out)
