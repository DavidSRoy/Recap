# Recap — Build Brief

## Mission
Ship a macOS SwiftUI app that records or replays audio through the same pipeline, streams ASR transcripts, emits live 1–3 bullets for each 60-second window, maintains a long summary capped at 500 words, and logs ML systems metrics to JSONL for a local vs vLLM baseline.

## Hard Constraints
- One LLM call per window. Output must be exactly `KEEP_LISTENING` or bullets.
- Swift owns audio, ASR, LLM, UI. C++ is limited to a lock-free ring buffer and a high-resolution timer, exposed via Objective-C++.
- JSONL logging starts on Day 1 and is never disabled.
- File playback must use the identical pipeline as live mic and preserve real-time pacing.
- Long summary hard cap is 500 words.
- Model stays loaded for the entire session to enable prefix KV reuse.

## Suggested Models
- ASR: WhisperKit tiny or small streaming. Fallback: MLX Whisper tiny.en
- LLM: MLX community 1.5B–3B instruct, 4-bit quantized. Keep context alive.

## Repo Structure
```
Recap/
  App/
    RecapApp.swift
    ContentView.swift
    Audio/
      AudioEngineManager.swift
      FilePlayer.swift
    ASR/
      ASRStreamer.swift
      Segment.swift
    Summarizer/
      WindowBuilder.swift
      SummarizerClient.swift
      PromptTemplates.swift
    State/
      SummaryStore.swift
      SessionStore.swift
      Deduplicator.swift
    Metrics/
      MetricsLogger.swift
      RSSSampler.swift
    UI/
      TranscriptView.swift
      BulletsView.swift
      SummaryView.swift
      MetricsOverlay.swift
  Engine/
    RingBuffer.hpp
    RingBuffer.cpp
    MetricsCollector.hpp
    MetricsCollector.cpp
  EngineBridge/
    EngineBridge.h
    EngineBridge.mm
  Eval/
    analyze.py
    plot.py
    vllm_client.py
    samples/
      meeting_5m.wav
      lecture_10m.wav
      discussion_5m.wav
  Runs/
  Report/
    figures/
    report.md
```

## Data Contracts

### Segment
```swift
struct Segment: Codable {
  let id: Int
  let startMs: Int
  let endMs: Int
  let text: String
  let isFinal: Bool
}
```

### JSONL Events
Write one JSON object per line. Use UTC ISO 8601 with milliseconds for `ts`.

| Event | Fields |
|-------|--------|
| `audio_start` | `ts` |
| `segment_end` | `ts`, `segment_id`, `start_ms`, `end_ms`, `text` |
| `prefill_start` | `ts`, `segment_id` |
| `first_token` | `ts`, `segment_id` |
| `decode_end` | `ts`, `segment_id`, `tokens_in`, `tokens_out` |
| `rss_sample` | `ts`, `mb` |
| `summary_update` | `ts`, `words` |

**Derived metrics for analysis:**
- `segment_end_to_token_ms = first_token.ts - segment_end.ts`
- `ttft_first_segment_ms = first_token.ts - audio_start.ts`
- `tokens_per_sec_out = tokens_out / ((decode_end.ts - first_token.ts) / 1000)`

## Frozen Interfaces

### Swift
```swift
final class ASRStreamer {
  func startMic() throws
  func startFile(url: URL, realtime: Bool) throws
  func stop()
  var onSegment: ((Segment) -> Void)?
}

final class WindowBuilder {
  func add(_ seg: Segment)
  func currentWindow(nowMs: Int) -> (text: String, tokenCount: Int)
}

final class SummarizerClient {
  func warmup() async
  func summarize(window: String, summary: String, priorBullets: [String]) async -> SummarizeResult
}
enum SummarizeResult { case keepListening; case bullets([String]) }

final class SummaryStore {
  private(set) var summary: String = ""
  func update(with bullets: [String]) async
}

final class MetricsLogger {
  init(sessionId: String)
  func log(_ event: String, _ payload: [String: Any])
}
```

### C++
```cpp
// RingBuffer.hpp
class RingBuffer {
public:
  explicit RingBuffer(size_t capacityFrames);
  size_t push(const float* data, size_t frames);
  size_t pop(float* out, size_t maxFrames);
  size_t size() const;
};

// MetricsCollector.hpp
uint64_t nowNs();
double rssMb();
```

### Objective-C++ Bridge
```objc
@interface EngineBridge : NSObject
- (instancetype)initWithCapacity:(NSUInteger)frames;
- (void)pushPCM:(const float*)data count:(NSUInteger)count;
- (NSUInteger)popPCM:(float*)out maxCount:(NSUInteger)max;
- (uint64_t)nowNs;
- (double)rssMb;
@end
```

## Frozen Prompts

**Planner + Summarizer**
```
System: You are Recap. Output either KEEP_LISTENING or 1–3 concise bullets. No preamble.
Long summary (<=500 words): {summary}
Recent 60s transcript: {window}
Prior bullets: {last_5}
Rules: Do not repeat prior bullets. If no new idea, output exactly KEEP_LISTENING.
```

**Summary Update**
```
Update the session summary to at most 500 words. Preserve decisions, action items, and open questions. Remove redundancy.
Current summary: {summary}
New bullets: {bullets}
```

## Day-by-Day Plan

> Day 0 is a bootstrap day (project setup, no audio yet). Days 1–6 are the six build days.

### Day 0: Bootstrap
**Tasks:** Create Xcode project, add MLX Swift and WhisperKit packages, add Engine static lib, implement MetricsLogger that opens `Runs/session_<ts>.jsonl`, add mic usage description.

**Acceptance:** App launches. One call to `log` creates a file with one line.

---

### Day 1: Audio → Reliable Transcript
**Tasks:** `AudioEngineManager` 16 kHz mono tap pushing to `EngineBridge`. `FilePlayer` pushes same format at real-time. `ASRStreamer` polls bridge, emits final `Segment` on 700 ms silence or 8000 ms max. Log `audio_start` and `segment_end`. Show transcript list.

**Acceptance:** 60-second mic test yields 8–15 finals in UI and JSONL. Replay `meeting_5m.wav` twice; segment count matches within 1.

---

### Day 2: Window + Bullets
**Tasks:** `WindowBuilder` evicts segments older than `now - 60000 ms`. `SummarizerClient` loads LLM once, streams tokens, logs `prefill_start`, `first_token`, `decode_end`. Implement `KEEP_LISTENING` gate. Render streamed bullets.

**Acceptance:** 3-minute file run produces ≥4 bullet batches. Each batch has matching timing events.

---

### Day 3: Summary + Dedup
**Tasks:** `SummaryStore` updates on background queue, enforces 500-word cap by truncating oldest sentences. `Deduplicator` uses Jaccard 3-gram > 0.8 against last 5 bullets. `SessionStore` writes `session.json` on stop. `RSSSampler` logs every 200 ms.

**Acceptance:** 10-minute run ends with summary 420–500 words. No duplicate bullets appear.

---

### Day 4: Systems Optimizations
**Tasks:** Ensure all audio flows through `RingBuffer`. Keep LLM context alive; split prompt into static prefix and dynamic suffix. Quantize to 4-bit. Profile with Instruments; record `prefill_ms` vs `decode_ms`.

**Acceptance:** Second-window `prefill_ms` is ≥20% lower than first. RSS is flat after minute 2.

---

### Day 5: Evaluation
**Tasks:** Run local file playback twice per sample; keep second run. Implement `vllm_client.py` to replay same windows and prompts, log identical schema. Implement `analyze.py` to compute mean and p95 latency, mean TPS, peak RSS. Implement `plot.py` for two figures.

**Acceptance:** `Report/results.csv` exists with columns `run, model, mean_latency_ms, p95_latency_ms, tps_out, peak_rss_mb`. Both PNGs render.

---

### Day 6: Demo + Report
**Tasks:** Record 90–120 second demo showing bullets streaming and summary updating. Export Markdown. Write report with sections: Abstract, Design, Implementation, Optimizations, Evaluation, Results, Hypothesis validation, Limitations. README with build steps and reproduce commands.

**Acceptance:** Clean clone builds on Apple Silicon. Demo video plays. Report references figures by filename.

---

## Build + Reproduce Commands
```bash
# Build
open Recap.xcodeproj

# Run file mode
RecapApp --mode file --input Eval/samples/meeting_5m.wav

# Analyze
python Eval/analyze.py Runs/*.jsonl --out Report/results.csv
python Eval/plot.py Report/results.csv --outdir Report/figures
```

## Cut Line (if behind)
Keep in priority order:
1. File playback ASR + bullets + summary + metrics
2. `results.csv` and plots
3. C++ RingBuffer integration
4. 4-bit quantization
5. Live mic mode
6. UI polish

## Definition of Done
- [ ] JSONL contains `audio_start`, `segment_end`, `prefill_start`, `first_token`, `decode_end`, `rss_sample`
- [ ] Summary never exceeds 500 words
- [ ] Prefix reuse shows measurable prefill reduction
- [ ] Local and vLLM `results.csv` and two plots present
- [ ] Demo video 90–120 seconds
- [ ] README reproduces numbers from clean clone
