# Real-Time Transcription Planning

## The Problem

Current flow:
1. User holds key, speaks for X seconds
2. User releases key
3. Whisper transcribes (takes Y seconds)
4. **Wait time = Y seconds** ← This feels wasteful

**Critical insight:** If user speaks for 60 seconds and we don't transcribe anything during that time, we waste 60 seconds of potential transcription time. We need to **transcribe WHILE speaking**, not just after.

Goal: Overlap transcription with speaking time so wait after release is minimal or zero.

---

## Strategy 1: Chunked/Streaming Transcription

**How it works:**
- Transcribe audio in chunks (e.g., every 3-5 seconds) while recording
- Each chunk transcribed independently as it completes
- Results accumulated and displayed progressively
- Optional: final refinement pass on complete audio

**Advantages:**
- User sees text appearing while speaking
- Overlaps transcription with speaking time
- 60 seconds of speech = chunks being transcribed throughout, not all at end

**Disadvantages:**
- Chunk boundaries may split words/sentences
- Context from later speech not available for earlier chunks
- Need smart chunk boundary detection (pause-based?)

**Key insight:** If chunk transcription takes ~2s and chunks are 5s, we stay ahead of the audio.

**Complexity:** Medium-High

---

## Strategy 2: Continuous Pipeline (Overlapping Chunks)

**How it works:**
- While recording, maintain a rolling buffer
- Every N seconds, send the last M seconds to transcription (overlapping)
- Merge overlapping results intelligently
- Always be transcribing something

**Example timeline (5s chunks, 2s overlap):**
```
Speaking: [----0-5s----][----3-8s----][----6-11s----]...
Transcribing:    [chunk1]     [chunk2]      [chunk3]
```

**Advantages:**
- Maximizes parallel work
- Overlap helps with word boundaries
- By end of speech, most transcription already done

**Disadvantages:**
- Complex overlap merging
- Duplicate processing of overlapped audio
- Need to deduplicate/align text

**Complexity:** High

---

## Strategy 3: Dual Model Pipeline

**How it works:**
- Fast model (small/base) runs continuously for live preview
- Large model runs on chunks in background for accuracy
- Display: show fast preview, replace with accurate as it arrives
- OR: show fast preview during recording, accurate final after

**Advantages:**
- Immediate visual feedback
- Final accuracy preserved
- User knows transcription is happening

**Disadvantages:**
- Double compute
- Text may change (could be jarring)
- Need two model instances

**Complexity:** Medium-High

---

## Strategy 4: WhisperKit Eager Streaming Mode ⭐ RECOMMENDED

**Research findings:**

WhisperKit HAS native streaming support called "Eager Streaming Mode":

1. **TranscriptionCallback**: The `transcribe()` function accepts a callback that receives `TranscriptionProgress` with current text, tokens, and timing info

2. **LocalAgreement Policy**: WhisperKit confirms text by comparing consecutive hypothesis buffers - finds longest common prefix and considers that "confirmed"

3. **Dual Output**:
   - **Confirmed text**: Stable, verified transcription
   - **Hypothesis text**: Low-latency interim results (may change)

4. **Performance**: 0.45s mean latency for hypothesis text, 2% Word Error Rate

5. **Example App**: WhisperAX on TestFlight demonstrates this

**How it works internally:**
- Audio encoder modified to process in 15-second blocks (not just 30s)
- Text decoder streams tokens with hypothesis confirmation
- Text confirmed when same prefix appears in consecutive predictions

**Recommended settings (from WhisperKit docs):**
- Max tokens per loop < 100
- Max fallback count < 2
- Prompt and cache prefill: true

**Advantages:**
- Native solution, already optimized for Apple Silicon
- Handles the hard problems (chunking, confirmation, latency)
- 0.45s hypothesis latency is excellent
- Proven in WhisperAX app

**Disadvantages:**
- Need to integrate with our recording flow
- May require different UI to show confirmed vs hypothesis text
- "Eager mode" is still experimental

**Complexity:** Medium (use existing API)

---

## Comparison Matrix

| Strategy | Transcription During Speech | Final Wait | Accuracy | Complexity |
|----------|----------------------------|------------|----------|------------|
| Chunked | Yes (per chunk) | Minimal (last chunk only) | Good | Medium-High |
| Overlapping Pipeline | Yes (continuous) | Minimal | Good (overlap helps) | High |
| Dual Model | Yes (preview) | Final pass needed | Best | Medium-High |
| **WhisperKit Eager** | **Yes (native)** | **~0.45s** | **2% WER** | **Medium** |

---

## Recommended Strategy: WhisperKit Eager Streaming

Based on research, WhisperKit already solves this problem. We don't need to reinvent chunking.

### Architecture

```
Recording: [========continuous audio stream=========][stop]
                ↓ (callback every ~0.5s)
WhisperKit:  hypothesis → hypothesis → hypothesis → confirmed
                ↓            ↓            ↓            ↓
Display:    "Hello"    "Hello wor"  "Hello world"  "Hello world, how are you?"
                         (interim)     (interim)       (final confirmed)
```

### Implementation Plan

**Phase 1: Understand WhisperAX**
1. Download WhisperAX from TestFlight and test Eager Streaming Mode
2. Study WhisperAX source code (in WhisperKit repo under Examples/)
3. Understand how they feed audio and receive callbacks

**Phase 2: Integrate into Whisper App**
1. Modify `AudioRecorder` to provide streaming audio buffer access
2. Call `transcribe(audioArray:callback:)` with our audio buffer
3. Use `TranscriptionCallback` to receive progress updates
4. Display hypothesis text in launcher panel as it arrives

**Phase 3: UI Updates**
1. Show live text in launcher panel while recording
2. Distinguish confirmed vs hypothesis (maybe different opacity?)
3. Final text on key release

---

## Key Technical Details

### TranscriptionCallback
```swift
let callback: TranscriptionCallback = { progress in
    // progress.text contains current transcription
    // Return true to continue, false to stop
    print("Current: \(progress.text)")
    return true
}

let results = try await whisperKit.transcribe(
    audioArray: samples,
    decodeOptions: options,
    callback: callback
)
```

### Recommended DecodingOptions
```swift
var options = DecodingOptions()
options.usePrefillPrompt = true
options.usePrefillCache = true
// Max tokens and fallback count may need tuning
```

---

## Open Questions

1. Can we call `transcribe()` on a growing audio buffer while still recording?
2. Or do we need to pause recording, transcribe, then resume?
3. How does WhisperAX handle the mic → buffer → transcribe flow?

---

## Next Steps

- [ ] Download WhisperAX from TestFlight, test Eager mode
- [ ] Read WhisperAX source code in WhisperKit Examples/
- [ ] Test: call transcribe() with callback on sample audio
- [ ] Prototype: stream mic audio to transcribe() with live callback

---

## Sources

- [WhisperKit GitHub](https://github.com/argmaxinc/WhisperKit)
- [WhisperKit Configurations](https://github.com/argmaxinc/whisperkit/blob/main/Sources/WhisperKit/Core/Configurations.swift)
- [WhisperKit Paper](https://arxiv.org/html/2507.10860v1) - 0.45s latency, 2% WER
- [Eager Streaming Issue](https://github.com/argmaxinc/WhisperKit/issues/102)
