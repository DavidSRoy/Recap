#!/usr/bin/env python3
"""Replay session windows against an Ollama endpoint, logging identical JSONL schema."""
import argparse
import json
import subprocess
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import urllib.request
import urllib.error


def ts_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def epoch_to_ts(t: float) -> str:
    return datetime.fromtimestamp(t, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def ollama_pids() -> list[int]:
    """Return PIDs of all running ollama processes."""
    try:
        out = subprocess.check_output(["pgrep", "-x", "ollama"], text=True)
        return [int(p) for p in out.split() if p.strip()]
    except subprocess.CalledProcessError:
        return []


def sample_rss_mb(pids: list[int]) -> float:
    """Sum RSS (MB) across given PIDs using `ps`. Returns 0.0 if none found."""
    if not pids:
        return 0.0
    try:
        out = subprocess.check_output(
            ["ps", "-o", "rss=", "-p", ",".join(str(p) for p in pids)],
            text=True, stderr=subprocess.DEVNULL,
        )
        total_kb = sum(int(x) for x in out.split() if x.strip())
        return round(total_kb / 1024, 1)
    except Exception:
        return 0.0


class RssSampler:
    """Samples Ollama RSS every interval_ms and appends rss_sample events to a list."""

    def __init__(self, events: list, interval_ms: int = 200):
        self._events = events
        self._interval = interval_ms / 1000
        self._stop = threading.Event()
        self._pids = ollama_pids()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        if not self._pids:
            print("  [rss] no ollama process found — skipping RSS sampling")
            return
        print(f"  [rss] sampling ollama PIDs {self._pids} every {int(self._interval*1000)} ms")
        self._thread.start()

    def stop(self):
        self._stop.set()
        self._thread.join(timeout=1)

    def _run(self):
        while not self._stop.is_set():
            mb = sample_rss_mb(self._pids)
            self._events.append({"event": "rss_sample", "ts": ts_now(), "rss_mb": mb})
            self._stop.wait(self._interval)


def load_windows(log_path: Path) -> list:
    windows = []
    for line in log_path.read_text().splitlines():
        if not line.strip():
            continue
        e = json.loads(line)
        if e.get("event") == "prefill_start":
            windows.append(e)
    return windows


def chat_streaming(endpoint: str, model: str, system: str, prompt: str):
    """
    POST to /v1/chat/completions with stream=True.
    Yields (first_token_time, full_text, tokens_out).
    """
    url = endpoint.rstrip("/") + "/chat/completions"
    payload = json.dumps({
        "model": model,
        "stream": True,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user",   "content": prompt},
        ],
        "temperature": 0.0,
    }).encode()

    req = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    first_token_time = None
    full_text = ""
    tokens_out = 0

    decode_end_time = None
    with urllib.request.urlopen(req, timeout=120) as resp:
        for raw_line in resp:
            line = raw_line.decode().strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            chunk = json.loads(data)
            delta = chunk["choices"][0]["delta"].get("content", "")
            if delta:
                if first_token_time is None:
                    first_token_time = time.time()
                full_text += delta
                tokens_out += 1
                decode_end_time = time.time()

    if decode_end_time is None:
        decode_end_time = time.time()
    return first_token_time, decode_end_time, full_text, tokens_out


def replay(log_path: Path, endpoint: str, model: str, out: Path):
    windows = load_windows(log_path)
    print(f"Loaded {len(windows)} windows from {log_path.name}")

    out.parent.mkdir(parents=True, exist_ok=True)
    events = []

    def emit(event: dict):
        events.append(event)

    sampler = RssSampler(events)
    sampler.start()

    for w in windows:
        sid     = w["segment_id"]
        system  = w["system"]
        prompt  = w["prompt"]
        tokens_in = len(prompt.split())

        print(f"  window segment_id={sid} ({tokens_in} tokens in) ...", end=" ", flush=True)

        emit({"event": "prefill_start", "ts": ts_now(), "segment_id": sid})
        prefill_start = time.time()

        try:
            first_token_time, decode_end_time, text, tokens_out = chat_streaming(endpoint, model, system, prompt)
        except Exception as e:
            print(f"ERROR: {e}")
            continue

        if first_token_time is None:
            first_token_time = time.time()

        prefill_ms = int((first_token_time - prefill_start) * 1000)
        decode_ms  = int((decode_end_time  - first_token_time) * 1000)

        emit({"event": "first_token",  "ts": epoch_to_ts(first_token_time), "segment_id": sid})
        emit({
            "event":      "decode_end",
            "ts":         epoch_to_ts(decode_end_time),
            "segment_id": sid,
            "tokens_in":  tokens_in,
            "tokens_out": tokens_out,
        })

        tps = tokens_out / (decode_ms / 1000) if decode_ms > 0 else 0
        print(f"ttft={prefill_ms}ms decode={decode_ms}ms tps={tps:.1f} text={text[:60]!r}")

    sampler.stop()

    # Sort so rss_sample events interleave chronologically with inference events.
    events.sort(key=lambda e: e["ts"])

    peak_mb = max((e["rss_mb"] for e in events if e["event"] == "rss_sample"), default=0.0)
    print(f"Peak Ollama RSS: {peak_mb} MB")

    with open(out, "w") as f:
        for e in events:
            f.write(json.dumps(e) + "\n")

    print(f"\nWrote {len(events)} events → {out}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log",       type=Path, help="Session JSONL from a local run")
    parser.add_argument("--endpoint", default="http://localhost:11434/v1")
    parser.add_argument("--model",    default="llama3.1:8b")
    parser.add_argument("--out",     type=Path, required=True)
    args = parser.parse_args()
    replay(args.log, args.endpoint, args.model, args.out)
