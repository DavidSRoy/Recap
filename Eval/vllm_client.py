#!/usr/bin/env python3
"""Replay session windows against a vLLM endpoint, logging identical JSONL schema."""
import argparse
import json
from pathlib import Path


def replay(log_path: Path, endpoint: str, out: Path):
    # TODO Day 5: parse windows from JSONL, POST to vLLM /v1/completions,
    # log prefill_start / first_token / decode_end in same schema
    print(f"Replaying {log_path} → {endpoint}")
    out.parent.mkdir(parents=True, exist_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    parser.add_argument("--endpoint", default="http://localhost:8000/v1")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    replay(args.log, args.endpoint, args.out)
