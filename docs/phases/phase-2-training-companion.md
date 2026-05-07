# Phase 2 — Training Companion

**Goal:** Turn Phase 1 into a real training companion: voice notes that get answered, all five personalities, a memory layer, post-run AI summaries, run history with charts and PBs, and proper treadmill polish.

**Outcome:**
> Mid-run, founder taps the watch's "Talk to coach" button, says "my legs feel cooked but I'll push to 8k". A minute later the companion replies in voice over the phone audio. After the run, a multi-paragraph AI summary appears, the History tab shows four weeks of mileage chart, and a soft fact ("user has a regular long run through 'the park'") sits awaiting confirmation.

**Estimated effort:** **2–3 days.**

**Dependencies:** Phase 1 complete.

---

## Workstreams

### 2.1 — Voice capture + transcription

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 2.1.1 | `VoiceCapture` actor on phone: `AVAudioRecorder`, M4A/AAC, mono, 22kHz, 30s cap | `VoiceCapture.swift` | Records and saves |
| 2.1.2 | Phone-side trigger: hold-to-talk button on ActiveRunView with visual + haptic feedback | UI | Hold to record, release to stop |
| 2.1.3 | Watch-side trigger: "Talk to coach" button. Records on watch, transfers M4A to phone via `WCSession.transferFile` | watch + phone | Note arrives on phone in seconds |
| 2.1.4 | `SpeechTranscriber` using `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true` when available | `SpeechTranscriber.swift` | Reasonable accuracy on a sample |
| 2.1.5 | Persist `VoiceNote` with `transcriptionStatus`, audio path | impl | Visible in run detail |
| 2.1.6 | If transcription fails or unavailable, keep the audio file and queue for cloud Whisper later (Phase 3 polish — for now status stays `pending`) | impl | Offline test: audio preserved |

### 2.2 — Async AI reply queue

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 2.2.1 | Proxy endpoint `POST /chat-reply` using Haiku 4.5 | TS | <2s p50 |
| 2.2.2 | `AIClient.chatReply(transcript:context:)` returns `AiReply` | Swift | Fast path |
| 2.2.3 | Persistent retry queue in SwiftData; drains on connectivity | `AIRequestQueue.swift` | Airplane mode mid-run + reconnect plays the reply at the next km |
| 2.2.4 | ScriptEngine integration: when a reply lands, slot it at the next safe trigger (next km, next interval break, after current utterance) | impl | Reply doesn't interrupt mid-utterance |
| 2.2.5 | Cancel/expire policy: a 90s-late reply still plays; a 90min-late reply is dropped | impl | Tested |
| 2.2.6 | Empty / moderated / malformed replies fall back to a generic acknowledgement TTS line | impl | Never silently swallow user input |

### 2.3 — Personalities

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 2.3.1 | Implement remaining personalities: `race_strategist`, `calm_coach`, `long_run_friend`, `drill_coach` | proxy prompts + manifests | Each generates distinctly-toned scripts on the same input |
| 2.3.2 | Personality settings UI: talk frequency, swearing, roast intensity, metric detail, encouragement style, "interrupts music?", "milestone-only?", "conversational replies?" | UI in Settings | Settings persist; sent with every script generation |
| 2.3.3 | Mid-run personality switch (rare): buffer until current section ends | impl | Switching mid-run doesn't break engine |

### 2.4 — Memory store

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 2.4.1 | `UserMemory` SwiftData model + `MemoryStore` API | code | CRUD works |
| 2.4.2 | Settings UI for explicit prefs: tone, swearing, roast intensity, training goal, race goal, weekly volume target | UI | Saved + read by AIClient |
| 2.4.3 | "Soft fact" extraction: post-run summary returns `extractedFacts: [{kind, value, confidence}]` | proxy + Swift | Stored with `confidence < 1.0`, `source = ai_inferred` |
| 2.4.4 | "Confirm or reject" surface: a tray on next app open lists pending facts; tap to accept/reject | UI | Confirmed facts get `confidence = 1.0` |
| 2.4.5 | Memory included in script-generation prompt; Anthropic prompt-cached as stable prefix | proxy code | Cache hit confirmed via response usage metadata |

### 2.5 — Treadmill polish

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 2.5.1 | Treadmill mode passes `locationType: .indoor` to `HKWorkoutConfiguration` | impl | Workout shows `indoor=true` in Health |
| 2.5.2 | "Correct distance" CTA on post-run summary that updates the HK workout's distance sample | impl | Apple Fitness reflects the corrected distance |
| 2.5.3 | Distinct treadmill UI: emphasises duration + cadence, no map | UI | — |

### 2.6 — Run history + trends

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 2.6.1 | History list: weekly grouping with weekly mileage header, monthly summary at month boundaries | UI | Renders for >=4 weeks |
| 2.6.2 | Trends tab: weekly mileage, average pace over time, longest run, HR avg trend (Swift Charts) | UI | Renders |
| 2.6.3 | Personal bests: 1km, 5km, 10km, half-marathon, marathon — derived per-run from HK distance statistics | `PersonalBestsService` | Updates on each new run |
| 2.6.4 | Filtering: by run type, personality, month | UI | Works |

All charts source data from HealthKit (workouts of activity `.running` + their distance/HR statistics), not from our SwiftData. SwiftData provides the personality/companion overlays.

### 2.7 — Post-run AI summary

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 2.7.1 | Proxy endpoint `POST /post-run-summary` (Sonnet) | TS | Returns `summaryText` + `extractedFacts` |
| 2.7.2 | Triggered on save when online; queued otherwise | Swift | Offline run gets summary on next launch |
| 2.7.3 | Rendered in run detail with "regenerate" affordance (capped 3/day per run) | UI | — |
| 2.7.4 | Memory ingestion of `extractedFacts` per 2.4.3/2.4.4 | impl | — |

### 2.8 — Polish

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 2.8.1 | Final app icon + launch screen + accent | assets | — |
| 2.8.2 | Empty states for each tab | UI | First-run is not jarring |
| 2.8.3 | Onboarding: 4 screens — permissions, the companion idea, the voicemail model, watch pairing reminder | UI | New user starts first run within 2 minutes |
| 2.8.4 | Settings: about, version, build, "send feedback" mailto | UI | — |

---

## Out of scope

- Race day mode.
- Premium / Personal voices.
- Real-time voice chat.
- Cloud Whisper transcription fallback (Phase 3 polish).
- Multi-runner accounts / login.

## Risks specific to this phase

- **Voice transcription quality outdoors** (R9) — wind and breathing destroy accuracy. Test in real conditions before declaring done.
- **Reply latency feel** — a reply that lands 90s after the question can feel disjointed. The next-km slot helps; tune.
- **Memory pollution** — AI-inferred facts can be wrong. The confirm-or-reject UI must be obvious; confidence thresholds conservative.
- **Cost creep** — chat-reply on every voice note adds up. Monitor proxy spend daily during this phase.

## Demo

1. Founder runs with `long_run_friend`.
2. At 3km, holds the watch's "Talk to coach", says "this hill at the park is brutal".
3. At 4km, hears: "the park hill is on every long run, and you complain every time. that's just your relationship with that hill. ease the cadence up, you're fine."
4. Run finishes.
5. Post-run summary appears: "20km easy, average pace 5:38, faded slightly after the park hill. Feel: positive. New PB at 15km."
6. Confirm extracted fact: "user has a regular long run through 'the park'." Tap accept.
7. Trends tab — weekly mileage chart for last 8 weeks.
8. Switch to treadmill mode. Run 10 min indoors. Correct distance post-run. Apple Fitness reflects.

## Definition of done

- All five personalities feel meaningfully different to the founder.
- Voice notes work outdoors in real conditions, not just simulator.
- History covers a full training week and looks like a tool, not a scaffold.
- Memory store has at least 5 founder-confirmed facts that visibly change companion lines.
- Founder reports they want their next run with AARC, not without it. (Required.)
