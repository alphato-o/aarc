# AARC Architecture

This document describes the modules, frameworks, and key data/audio/AI flows.

The architectural lever: **Apple Watch is the tracker; iPhone is the brain.** All custom GPS/distance/pace/HR/auto-pause/splits code is replaced by `HKWorkoutSession` + `HKLiveWorkoutBuilder` on the watch. The phone consumes a stream of authoritative metrics over WatchConnectivity and uses them to drive the AI script engine and TTS playback.

---

## High-level layout

```
┌──────────────────────────────────┐         ┌────────────────────────────────────────┐
│      Apple Watch (watchOS 10)    │         │            iPhone (iOS 17)             │
│                                  │         │                                        │
│  WatchApp UI                     │         │  iOS UI (SwiftUI)                      │
│   ├── Start / Pause / End        │         │   ├── HomeView                         │
│   ├── Live metrics (HR, pace)    │         │   ├── ActiveRunView (live narration)   │
│   └── "Talk to coach" trigger    │         │   ├── HistoryView (Health-backed)      │
│                                  │ WC ↔︎    │   ├── RaceSetupView                    │
│  WorkoutSessionHost              │ WC ↔︎    │   ├── SettingsView                     │
│   ├── HKWorkoutSession            │         │                                        │
│   ├── HKLiveWorkoutBuilder        │         │  Phone services                        │
│   ├── HKWorkoutRouteBuilder       │         │   ├── LiveMetricsConsumer (WC)         │
│   └── publishes live metrics      │         │   ├── HealthKitReader                  │
│                                  │         │   ├── AudioPlaybackManager (ducking)   │
│                                  │         │   ├── LocalTTS (AVSpeechSynth)         │
│                                  │         │   ├── VoiceCapture (AVAudioRecorder)   │
│                                  │         │   ├── SpeechTranscriber (SFSpeechReco) │
│                                  │         │   ├── ScriptEngine (trigger eval)      │
│                                  │         │   ├── AIClient (proxy + retry queue)   │
│                                  │         │   ├── MemoryStore                      │
│                                  │         │   └── PersistenceStore (SwiftData)     │
│                                  │         │                                        │
│  Storage                         │         │  Storage                               │
│   └── HealthKit (writes workout) │         │   ├── SwiftData (companion data)       │
│                                  │         │   ├── HealthKit (read history)         │
│                                  │         │   └── files (audio recordings, TTS)    │
└──────────────────────────────────┘         └──────────┬─────────────────────────────┘
                                                        │ HTTPS
                                                        ▼
                                   ┌────────────────────────────────────────────┐
                                   │       AARC Edge Proxy (Cloudflare Worker)  │
                                   │   /generate-script  (Sonnet 4.6)           │
                                   │   /chat-reply       (Haiku 4.5)            │
                                   │   /post-run-summary (Sonnet 4.6)           │
                                   └────────────────────────────────────────────┘
```

WC = WatchConnectivity (`WCSession` real-time messages + file transfer for voice notes).

---

## What we are NOT writing

Worth being explicit, because this is where the schedule savings come from:

- ❌ CoreLocation handling. No `CLLocationManager`. No accuracy filtering, no smoothing, no auto-pause heuristics.
- ❌ Distance integration. No Haversine. No moving averages.
- ❌ Pace computation. Watch publishes current and average pace.
- ❌ Splits computation. Watch publishes split events.
- ❌ Heart rate sampling. Watch publishes HR ticks at the system's sample rate.
- ❌ Calorie estimation. Apple does it.
- ❌ Indoor vs outdoor distance estimation. `HKWorkoutSession` config picks the right algo.
- ❌ Background GPS reliability scaffolding on the phone. The phone does not need to record location.
- ❌ Pedometer fallback. Watch handles indoor running.

We *do* write: the watch app's session host, the WatchConnectivity wiring, the script engine, TTS pipeline, AI client, memory layer, and the iOS UI.

---

## Frameworks (pinned)

| Concern | Framework | Why |
|---|---|---|
| iOS UI | SwiftUI + `@Observable` | Velocity |
| watchOS UI | SwiftUI for watchOS | Same |
| Persistence | SwiftData | Adequate scale, iOS 17+ |
| Workout source-of-truth | HealthKit (`HKWorkoutSession`, `HKLiveWorkoutBuilder`, `HKWorkoutRouteBuilder`) | Apple's own running algorithms |
| Watch ↔ Phone | WatchConnectivity (`WCSession`) | Standard, low-latency for short messages |
| Audio session | `AVAudioSession` | Ducking, mixing |
| TTS | `AVSpeechSynthesizer` | Local, offline, free |
| Voice capture | `AVAudioRecorder` | Short voice notes |
| Speech-to-text | `SFSpeechRecognizer` | On-device when available |
| Networking | `URLSession` | No deps |
| LLM | Anthropic via proxy | See decisions doc |
| Charts | Swift Charts | Built-in |
| Map | MapKit (read `HKWorkoutRoute` and overlay) | Free |

No third-party deps required for MVP 1. Optional later: ElevenLabs SDK (premium voices), Sentry (telemetry).

---

## Module responsibilities

### Watch-side: `WorkoutSessionHost` (watchOS)

The only place an `HKWorkoutSession` is created. Owns the workout lifecycle.

- Starts session with `HKWorkoutConfiguration(activityType: .running, locationType: .outdoor or .indoor)`.
- Begins `HKLiveWorkoutBuilder` collection — Apple automatically populates distance, energy, HR, pace.
- For outdoor runs: also starts `HKWorkoutRouteBuilder` and feeds it locations from `CLLocationManager` (still on the watch — but Apple's running-mode location config does the smoothing).
- Polls or observes the `builder.statistics(for:)` API on a 1Hz timer to publish live metrics to the phone.
- On end: `endCollection`, `finishWorkout`, write route, hand the workout UUID to the phone.

Live metrics published over WC (1Hz):
```swift
struct LiveMetrics: Codable {
    let elapsed: TimeInterval
    let distance: Double          // meters, from HK
    let currentPaceSecPerKm: Double?
    let avgPaceSecPerKm: Double
    let currentHR: Double?         // bpm
    let energyKcal: Double
    let lastSplit: Split?         // emitted only when a new km/mile completes
    let state: WorkoutState        // .preparing | .running | .paused | .ended
}
```

### Watch-side: `WatchAppUI`

- One screen with prominent Start/Pause/End controls.
- Live metrics display (HR, pace, distance, elapsed).
- "Talk to coach" button → starts a short voice recording (Phase 2) and ships the file to the phone.
- Complication for one-tap start from the watch face.

### Phone-side: `LiveMetricsConsumer`

Subscribes to `WCSession` messages from the watch.

- Receives 1Hz `LiveMetrics`. Stores latest snapshot in an `@Observable` state object that the UI binds to.
- Forwards every snapshot to `ScriptEngine`.
- Tracks connection liveness; if no metrics for 10s while supposedly running, surfaces a "watch disconnected" indicator (does not stop the run — the watch keeps recording).

### Phone-side: `HealthKitReader`

Read-only on the phone. The watch is the writer.

- Read scope: workouts, distance, HR, energy, route.
- Used to render History (list of past `HKWorkout`s of activity `.running`).
- Used to render Trends (HKStatisticsCollectionQuery for weekly mileage, etc.).
- Resolves workout UUIDs → our local `Run` companion record (Script, voice notes, etc.).

The phone may request HealthKit *write* permissions only as a fallback to write companion-only metadata (a workout's `metadata` dictionary holds our `runId` so we can link). We do NOT write a duplicate workout from the phone.

### Phone-side: `AudioPlaybackManager`

Single source of audio output truth.

- Configures `AVAudioSession` category `.playback`, mode `.spokenAudio`, options `.mixWithOthers, .duckOthers`.
- Owns a serial audio event queue.
- Handles interruptions (phone calls): pauses queue on `.began`, resumes on `.ended` if `shouldResume`.
- "Mute companion" toggle from the active-run UI takes effect mid-utterance.

### Phone-side: `LocalTTS`

- Wraps `AVSpeechSynthesizer`.
- Picks the best installed voice for the user's language; lets the user override in Settings.
- Phase 3 adds: pre-rendered TTS for race-day scripts to local M4A, so playback never hits the synthesizer cold during a race.

### Phone-side: `VoiceCapture` + `SpeechTranscriber` (Phase 2)

- 30-second hard cap recording. Triggered from active-run UI or via WC from the watch's "Talk to coach" button.
- Saved as an M4A file in app container.
- Transcribed via `SFSpeechRecognizer`, `requiresOnDeviceRecognition = true` when available.
- If transcription fails, the audio is preserved and queued for cloud transcription (Phase 3 fallback).

### Phone-side: `ScriptEngine`

The thing that turns "runner is at 5.2km, on pace, HR 168" into "play this line now".

- Holds the active `Script` for the run (an ordered list of `ScriptMessage`s with triggers).
- On each `LiveMetrics` tick (1Hz), evaluates triggers and dispatches at most one message per ~30s window.
- Trigger types: `distance.atMeters`, `distance.everyMeters`, `time.atSeconds`, `halfway`, `near_finish`, `condition` (whitelisted expression), `fatigue_zone`.
- When async AI replies arrive (Phase 2), slots them at the next safe trigger point.

### Phone-side: `AIClient`

Single entry point for any LLM call.

- Methods: `generateScript(plan:)`, `chatReply(transcript:context:)`, `postRunSummary(run:)`.
- Caches responses; replays from cache for retried requests.
- Persistent retry queue (in SwiftData) for offline scenarios; drains on connectivity restore.
- Timeouts: 8s for chat-reply (else fall back to a stock line), 30s for script generation, 60s for post-run summary.

### Phone-side: `MemoryStore`

- Holds durable user prefs (tone, swearing, roast intensity, training goals, race goals) plus AI-inferred soft facts.
- Writes are explicit (settings UI) plus inferred (post-run summary may extract facts).
- Read by `AIClient` when assembling prompts.

### Phone-side: `PersistenceStore`

- SwiftData container, single `ModelContainer`.
- Entities defined in `docs/data-model.md`. Notably: route data is NOT stored here — it lives in HealthKit.
- Companion data only: scripts, played messages, voice notes, AI replies, user memory, race setups.

---

## Audio session strategy

1. Configure on app launch: `.playback` / `.spokenAudio` / `[.mixWithOthers, .duckOthers]`.
2. Activate only while a run is active.
3. When TTS speaks, the system ducks Apple Music / Spotify / Podcasts.
4. 200ms grace silence pre/post utterance for clean duck-in/duck-out.
5. Listen for `AVAudioSessionInterruptionNotification`; pause on `.began`, resume on `.ended` with `shouldResume`.

Tested against Apple Music, Spotify, Podcasts, Audible — all honour the audio session contract.

---

## Background execution

The phone is the audio device. Required `UIBackgroundModes` on iOS:
- `audio` — keeps TTS playable when locked.
- `fetch` — occasional script regeneration, rare.

We do NOT need `location` background mode on the phone — the watch is the location/workout host.

The watch's `HKWorkoutSession` keeps its app foregrounded for the duration of the workout. Standard.

---

## WatchConnectivity protocol

Small, hand-rolled message types. All Codable.

```swift
// Watch → Phone (1Hz during run)
case liveMetrics(LiveMetrics)
// Watch → Phone (events)
case workoutStarted(workoutId: UUID, startedAt: Date)
case workoutPaused
case workoutResumed
case workoutEnded(healthKitWorkoutUUID: UUID)
case voiceNote(payload: Data, recordedAt: Date)        // file transfer
// Phone → Watch
case startWorkout(personality: String, mode: RunMode)
case endWorkout
case hapticCue(kind: HapticKind)                         // wrist tap on milestones
case companionMessageDispatched(messageId: UUID)         // for haptic + watch UI badge
```

Reliability: WC may briefly disconnect. Live metrics are best-effort 1Hz; missed ticks are fine because the watch is independently writing to HealthKit. Workout state events use `transferUserInfo` (queued, guaranteed delivery).

---

## LLM call shapes

### `/generate-script` — Sonnet 4.6
Request: `{ goal, distanceKm, targetPaceSecPerKm?, personality, settings, userMemory, recentRunSummaries }`
Response: `{ scriptId, messages: [{ id, triggerSpec, text, branchKey?, priority? }] }`

### `/chat-reply` — Haiku 4.5
Request: `{ runContextSnapshot, voiceNoteTranscript, personality, recentMessagesPlayed }`
Response: `{ replyText, suggestedTriggerHint? }`

### `/post-run-summary` — Sonnet 4.6
Request: `{ run, scriptUsed, voiceNotes, personality, userMemory }`
Response: `{ summaryText, extractedFacts: [{ kind, value, confidence }] }`

The proxy prepends a per-personality system prompt. Prompt caching keeps costs low for the stable prefix (personality + memory + recent runs) across calls.

---

## Threading model

- UI on main actor.
- `LiveMetricsConsumer` runs on a WC delegate queue; forwards to MainActor.
- `AudioPlaybackManager`, `AIClient`, `WorkoutSessionHost` (watch) are actors.
- `ModelContainer` shared; writes on a background `ModelContext`.

One writer per concern, no shared mutable state outside actors.

---

## Telemetry (later)

Out of scope for V1. When added, MetricKit first; Sentry/PostHog only when user count > 1.
