#!/usr/bin/env python3
"""Plot latency and throughput from results.csv."""
import argparse
import csv
from pathlib import Path


def plot(csv_path: Path, outdir: Path):
    # TODO Day 5: produce latency CDF and tps bar chart PNGs
    outdir.mkdir(parents=True, exist_ok=True)
    with open(csv_path) as f:
        rows = list(csv.DictReader(f))
    print(f"Loaded {len(rows)} rows from {csv_path}")
    print(f"Figures would go to {outdir}/")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("csv", type=Path)
    parser.add_argument("--outdir", type=Path, required=True)
    args = parser.parse_args()
    plot(args.csv, args.outdir)
