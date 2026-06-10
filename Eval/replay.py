#!/usr/bin/env python3
"""
Replay Recap session windows through any OpenAI-compatible inference backend
and write a JSONL file with the same event schema as the app.

Works with Ollama (Mac) or vLLM (cloud GPU) — only --base-url and --model change.

Usage — Mac/Ollama:
    ollama serve   # in another terminal
    python Eval/replay.py \\
        --input  Runs/session_<ts>.jsonl \\
        --output Runs/baseline_ollama.jsonl

Usage — cloud GPU/vLLM:
    python Eval/replay.py \\
        --input    Runs/session_<ts>.jsonl \\
        --output   Runs/baseline_vllm.jsonl \\
        --base-url http://<gpu-ip>:8000/v1 \\
        --api-key  EMPTY \\
        --backend  vllm \\
        --model    meta-llama/Llama-3.2-3B-Instruct
"""

import argparse
import asyncio
import json
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

try:
    import openai
except ImportError:
    sys.exit("openai package required — run: pip install -r Eval/requirements.txt")

# JSON schema matching @Generable BulletOutput in the Swift app.
BULLET_SCHEMA = {
    "type": "object",
    "properties": {
        "bullets": {
            "type": "array",
            "items": {"type": "string"},
            "maxItems": 3,
        }
    },
    "required": ["bullets"],
}


# ── Timing helpers ────────────────────────────────────────────────────────────

def now_ms() -> int:
    return int(time.time() * 1000)

def ms_to_iso(ms: int) -> str:
    dt = datetime.fromtimestamp(ms / 1000, tz=timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{ms % 1000:03d}Z"


# ── Result dataclass ──────────────────────────────────────────────────────────

@dataclass
class GenerationResult:
    bullets: list
    send_ms: int         # epoch ms — when the HTTP request was sent
    first_token_ms: int  # epoch ms — when the first non-empty chunk arrived
    decode_end_ms: int   # epoch ms — when the stream ended

    @property
    def prefill_ms(self) -> int:
        return self.first_token_ms - self.send_ms

    @property
    def decode_ms(self) -> int:
        return self.decode_end_ms - self.first_token_ms

    @property
    def tokens_in(self) -> int:
        # word-count approximation (same method used in the Swift app)
        return 0  # filled in by caller who has the prompt

    @property
    def tokens_out(self) -> int:
        return len(self.bullets)


# ── Core generation call ──────────────────────────────────────────────────────

async def generate(
    client: "openai.AsyncOpenAI",
    model: str,
    backend: str,
    system: str,
    prompt: str,
) -> tuple:  # (GenerationResult, tokens_in: int)

    tokens_in = len(prompt.split())

    # Schema-constrained generation — Ollama and vLLM use different param names.
    if backend == "ollama":
        extra = {"format": BULLET_SCHEMA}
    else:
        extra = {"guided_json": BULLET_SCHEMA}

    t0_perf = time.perf_counter()
    t0_ms   = now_ms()

    stream = await client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": system},
            {"role": "user",   "content": prompt},
        ],
        stream=True,
        temperature=0,
        extra_body=extra,
    )

    first_perf: Optional[float] = None
    full_text = ""

    async for chunk in stream:
        delta = chunk.choices[0].delta.content or ""
        if delta:
            if first_perf is None:
                first_perf = time.perf_counter()
            full_text += delta

    end_perf = time.perf_counter()

    if first_perf is None:
        first_perf = end_perf  # empty stream — shouldn't happen with guided JSON

    first_token_ms = t0_ms + int((first_perf - t0_perf) * 1000)
    decode_end_ms  = t0_ms + int((end_perf   - t0_perf) * 1000)

    try:
        bullets = json.loads(full_text).get("bullets", [])
    except Exception:
        bullets = []

    return GenerationResult(
        bullets=bullets,
        send_ms=t0_ms,
        first_token_ms=first_token_ms,
        decode_end_ms=decode_end_ms,
    ), tokens_in


# ── JSONL I/O ─────────────────────────────────────────────────────────────────

def read_prefill_events(path: Path) -> list:
    """Return all prefill_start events that carry system + prompt fields."""
    events = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
                if e.get("event") == "prefill_start" and "system" in e and "prompt" in e:
                    events.append(e)
            except json.JSONDecodeError:
                pass
    return events


def write_event(fh, event: str, payload: dict, ts_ms: int) -> None:
    record = {"ts": ms_to_iso(ts_ms), "event": event, **payload}
    fh.write(json.dumps(record) + "\n")
    fh.flush()


# ── Replay loop ───────────────────────────────────────────────────────────────

async def run(args) -> None:
    events = read_prefill_events(Path(args.input))
    if not events:
        sys.exit(
            f"No prefill_start events with system+prompt fields in {args.input}.\n"
            "These fields were added in Day 4. Re-run the app to generate a new session."
        )

    backend = args.backend
    if backend == "auto":
        backend = "ollama" if "11434" in args.base_url else "vllm"

    client = openai.AsyncOpenAI(base_url=args.base_url, api_key=args.api_key)

    print(f"Backend : {backend}  ({args.base_url})")
    print(f"Model   : {args.model}")
    print(f"Windows : {len(events)}")
    print()

    Path(args.output).parent.mkdir(parents=True, exist_ok=True)

    with open(args.output, "w") as out:
        for i, event in enumerate(events):
            seg_id = event.get("segment_id", i)

            try:
                result, tokens_in = await generate(
                    client, args.model, backend,
                    event["system"], event["prompt"],
                )

                write_event(out, "prefill_start", {"segment_id": seg_id}, result.send_ms)
                write_event(out, "first_token",   {"segment_id": seg_id}, result.first_token_ms)
                write_event(out, "decode_end", {
                    "segment_id": seg_id,
                    "tokens_in":  tokens_in,
                    "tokens_out": result.tokens_out,
                }, result.decode_end_ms)

                print(
                    f"  [{i+1:02d}/{len(events)}] seg={seg_id:3d}  "
                    f"prefill={result.prefill_ms:5d} ms  "
                    f"decode={result.decode_ms:5d} ms  "
                    f"bullets={result.tokens_out}"
                )

            except Exception as exc:
                print(f"  [{i+1:02d}/{len(events)}] seg={seg_id}  ERROR: {exc}", file=sys.stderr)

    print(f"\nOutput  : {args.output}")


# ── CLI ───────────────────────────────────────────────────────────────────────

def main():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--input",    required=True,
                   help="Recap session JSONL (must have prefill_start with system+prompt)")
    p.add_argument("--output",   required=True,
                   help="Output JSONL path")
    p.add_argument("--base-url", default="http://localhost:11434/v1",
                   help="Inference backend URL (default: Ollama)")
    p.add_argument("--api-key",  default="ollama",
                   help="API key — 'ollama' for Ollama, 'EMPTY' for local vLLM")
    p.add_argument("--model",    default="llama3.2:3b",
                   help="Model name (default: llama3.2:3b)")
    p.add_argument("--backend",  default="auto", choices=["auto", "ollama", "vllm"],
                   help="Structured-output parameter style (default: auto-detect from URL)")
    asyncio.run(run(p.parse_args()))


if __name__ == "__main__":
    main()
