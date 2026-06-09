# Recap

On-device live transcription and summarisation for macOS. Speak (or play an audio file) and Recap streams a rolling transcript, condenses it into bullet points every minute, and maintains a running prose summary — all without leaving the device or installing any third-party model.

## What it does

- **Captures** 16 kHz mono PCM from the mic (or a file player) via `AVAudioEngine`.
- **Transcribes** on-device with `SFSpeechRecognizer` (`requiresOnDeviceRecognition = true`). Silence-gated chunking emits a `Segment` every 700 ms of silence or every 8 s of audio, whichever comes first.
- **Summarises** with Apple `FoundationModels`. A 60 s sliding window of transcript is sent to a `LanguageModelSession` with a `@Generable BulletOutput` schema; the model returns ≤ 3 bullets per cycle.
- **Deduplicates** bullets against the last 5 using character-3-gram Jaccard similarity (> 0.8 = drop).
- **Updates** a 500-word prose summary after each bullet batch via a second `LanguageModelSession` call.
- **Logs** everything to JSONL — segments, prefill/first-token/decode events with token counts, 200 ms RSS samples, dedup drops — and snapshots a `session_<ts>.json` on stop.

## Architecture

```
AVAudioEngine ──► EngineBridge (Obj-C++) ──► C++ RingBuffer<float> (SPSC, lock-free)
                                                  │
                                                  ▼
                                          ASRStreamer (drain → SFSpeechRecognizer)
                                                  │
                                                  ▼
                                          WindowBuilder (60 s sliding)
                                                  │
                                                  ▼
                            SummarizerClient (FoundationModels @Generable)
                                                  │
                                                  ▼
                              Deduplicator → SummaryStore → SwiftUI views
```

Swift owns audio, ASR, LLM, and UI. C++ is limited to the lock-free ring buffer and `mach_*`-based timing/RSS sampling, exposed through an Obj-C++ bridge.

**Zero SPM dependencies.** Everything is built on Apple frameworks (`AVFoundation`, `Speech`, `FoundationModels`, `SwiftUI`).

## Requirements

- macOS with Apple Intelligence enabled
- Xcode 26+ (the project uses file-system-synchronized groups and `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`)
- Microphone + Speech Recognition permissions

## Build & run

```bash
open Recap.xcodeproj   # ⌘R to run
```

Permissions you'll be asked for on first launch:

- Microphone
- Speech Recognition (on-device)
- Apple Intelligence must be enabled in System Settings → Apple Intelligence & Siri

## Where the data lives

```
~/Library/Containers/com.thrillersolutions.Recap/Data/Library/Application Support/Recap/Runs/
  session_<ts>.jsonl   # per-event metrics: segment_end, prefill_start, first_token, decode_end, rss_sample, dedup_dropped
  session_<ts>.json    # final snapshot: segments + bullets + summary
```

## Project layout

```
Recap/
  ASR/            SFSpeechRecognizer wrapper, silence-gated chunking
  Audio/          AVAudioEngine mic capture + file player
  Engine/         C++ RingBuffer + MetricsCollector (nowNs, rssMb)
  EngineBridge/   Obj-C++ EngineBridge + @unchecked Sendable conformance
  Metrics/        MetricsLogger (JSONL), RSSSampler
  State/          RecapModel, Deduplicator, SummaryStore, SessionStore
  Summarizer/     SummarizerClient, WindowBuilder, PromptTemplates
  UI/             TranscriptView, BulletsView, SummaryView, MetricsOverlay
  Recap-Bridging-Header.h
```

See [`STATUS.md`](STATUS.md) for current progress and known issues, and [`PLAN.md`](PLAN.md) for the full project plan.
