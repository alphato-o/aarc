# Phase 1 — Tracking MVP + Scripted AI Companion

**Goal:** Founder starts an outdoor run from the watch, hears AI-generated milestone lines from the iPhone (via earbuds or speaker), ends on the watch, sees a clean summary and the workout in Apple Fitness.

**Outcome:**
> Pick "Roast Coach" on the iPhone. Tap "Ready" — script generates in ~5s. Walk outside. Tap Start on the watch (or via complication). Run for 30 minutes. Hear: a pre-run line, a check-in at every km, a halfway nod, a finish-line line. End on the watch. Both phone and Apple Fitness show the workout. The phone's run detail shows which AI lines played, and when.

**Estimated effort:** **1–2 days.**

**Dependencies:** Phase 0 complete.

This is the most important phase. The watch-primary architecture means the *tracking* workstream is small; the bulk of the work is the audio + script + AI pipeline.

---

## Workstreams

### 1.1 — Watch workout host

The whole tracking layer is here.

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 1.1.1 | `WorkoutSessionHost` actor on watch, owning `HKWorkoutSession` + `HKLiveWorkoutBuilder` | `WorkoutSessionHost.swift` (watch) | Starts an outdoor running workout that appears in the live Workouts app |
| 1.1.2 | Configuration: `HKWorkoutConfiguration(activityType: .running, locationType: .outdoor)` | impl | Outdoor running, route enabled |
| 1.1.3 | Attach `HKWorkoutRouteBuilder`; collection started/paused/ended in lockstep with the session | impl | Route appears in Apple Fitness post-finish |
| 1.1.4 | 1Hz publisher: read `builder.statistics(for: .distanceWalkingRunning)`, current heart rate (`activeWorkoutZone` or query latest sample), average pace (derived as elapsed/distance), current pace (delta over last 30s window from HK statistics), elapsed time | impl | A `LiveMetrics` value emitted every second |
| 1.1.5 | Detect new km splits by comparing distance to last published threshold; emit a `Split` in the snapshot when crossed | impl | Splits arrive at correct distances |
| 1.1.6 | `endCollection` + `finishWorkout`; before finishing, stamp `metadata` with `aarc.run_id`, `aarc.test_data` (per `Config.isTestDataMode`), `aarc.created_at`, `aarc.app_version`. See [D19](../decisions.md#d19--healthkit-test-data-isolation--accepted). | impl | Workout in Apple Health shows the metadata; `predicateForObjects(withMetadataKey:"aarc.test_data", ...)` returns it |
| 1.1.7 | Honour `Config.skipHealthKitWrite`: when ON, abandon the session before `finishWorkout` so nothing lands in HK; companion data still saves to local DB | impl | Toggle on → run completes, nothing in Apple Health, history still shows the run |
| 1.1.8 | Failure handling: if `finishWorkout` errors, persist a "to retry" record on the watch and retry next launch | impl | A simulated failure recovers |

### 1.2 — WatchConnectivity wiring

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 1.2.1 | Phone → Watch: `startWorkout(personality, mode, runId)` via `sendMessage` (iOS-initiated) | impl | Watch receives + starts |
| 1.2.2 | Watch → Phone: `liveMetrics` snapshots at 1Hz via `sendMessageData` (best-effort, fast) | impl | Phone updates UI in <500ms |
| 1.2.3 | Watch → Phone: state events (`workoutStarted`, `workoutPaused`, `workoutResumed`, `workoutEnded(uuid)`) via `transferUserInfo` (queued, guaranteed) | impl | Even after a 30s WC blackout, end signal arrives |
| 1.2.4 | Watch can also start a workout independently via its own UI; sends `workoutStarted` to phone, which catches up | impl | Watch-initiated start works |
| 1.2.5 | Reachability indicator on phone ActiveRunView: "Watch connected" / "Watch reconnecting…" | UI | Visible when WC drops |

### 1.3 — Phone live metrics consumer

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 1.3.1 | `LiveMetricsConsumer` (`@Observable` on phone) holding latest `LiveMetrics`, runId, state | `LiveMetricsConsumer.swift` | UI binds and updates |
| 1.3.2 | Forwards every snapshot to ScriptEngine | impl | ScriptEngine ticks |
| 1.3.3 | Connection watchdog: if no metrics 10s while state == running, set `watchStale = true` | impl | UI shows warning; run not aborted |

### 1.4 — Audio session + local TTS

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 1.4.1 | `AudioPlaybackManager` actor: `.playback / .spokenAudio / [.mixWithOthers, .duckOthers]` | `AudioPlaybackManager.swift` | Active during run |
| 1.4.2 | `LocalTTS` wrapping `AVSpeechSynthesizer`, picking best installed voice for user's locale | `LocalTTS.swift` | Speaks a test line on tap |
| 1.4.3 | Music ducking verified with Apple Music + Spotify + Podcasts + Audible | manual test | Music ducks in/out cleanly |
| 1.4.4 | Interruption handling (`AVAudioSessionInterruptionNotification`): pause queue on `.began`, resume on `.ended` with `.shouldResume` | impl | A phone call doesn't break audio |
| 1.4.5 | "Mute companion" toggle in ActiveRunView with immediate effect | UI | Mid-utterance mute stops speaking |

### 1.5 — Personality + script generation

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 1.5.1 | `roast_coach` manifest (key, name, description, exposed settings) | `Personalities/roast_coach.json` | Loaded into UI |
| 1.5.2 | Proxy endpoint `POST /generate-script` — Sonnet 4.6, server-side prompt with the trigger DSL grammar from data-model.md | TS Worker | Curl returns valid JSON |
| 1.5.3 | Strict JSON schema validation in the proxy; retry once if invalid | TS | Invalid generations rejected |
| 1.5.4 | iOS `AIClient.generateScript(plan:)` with 30s timeout | `AIClient.swift` | Returns a `Script` |
| 1.5.5 | Script generated **before** run start on the "Ready" screen; user can re-roll once if they want a different vibe | UI | Cannot start until ready, or user opts out |
| 1.5.6 | Persist Script + ScriptMessages | impl | Reload preserves them |

### 1.6 — Script Engine

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 1.6.1 | `ScriptEngine` actor consuming `LiveMetrics` snapshots, evaluating triggers, dispatching `play(messageId)` to AudioPlaybackManager | `ScriptEngine.swift` | Unit-tested with mocked metric streams |
| 1.6.2 | Trigger types implemented: `distance.atMeters`, `distance.everyMeters`, `time.atSeconds`, `halfway`, `near_finish` | impl | Tested |
| 1.6.3 | `condition` evaluator with whitelisted variables (V1 subset: `pace_3min_ratio`, `current_pace`, `distance`, `duration`) | impl | Tested |
| 1.6.4 | Cooldown: max one message per ~30s | impl | Spammy configs don't spam |
| 1.6.5 | Dedup: `playOnce: true` survives pause/resume | impl | Pause-resume doesn't repeat opener |
| 1.6.6 | Defer first message until elapsed >= 60s AND distance >= 100m | impl | Stationary noise doesn't trigger nonsense |

### 1.7 — UI: phone home + ready

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 1.7.1 | `RunHomeView`: pick mode (outdoor / treadmill — treadmill enabled but very basic), pick personality (Roast Coach only) | UI | — |
| 1.7.2 | "Ready" sheet: shows generated script preview (debug mode: full text; default: hidden so the lines surprise the runner), "Start countdown" CTA, "Re-roll script" CTA | UI | Generated lines visible in debug |
| 1.7.3 | `ActiveRunView`: large duration, distance, current pace, current HR, last split, mute toggle, "End on watch" reminder | UI | Readable while running |
| 1.7.4 | Always-on: `UIApplication.shared.isIdleTimerDisabled = true` while active | impl | Phone screen does not auto-lock |

### 1.8 — UI: watch active run

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 1.8.1 | Watch active run: prominent duration, distance, current pace, HR. Pause / Resume / End controls | UI | One tap per action |
| 1.8.2 | End requires force-touch / 2-step confirm | UI | Doesn't end on accidental touches |
| 1.8.3 | Watch face complication: "Start Roast Coach run" | impl | One-tap from any face |

### 1.9 — UI: post-run summary + history (basic)

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 1.9.1 | After watch's `workoutEnded(uuid)` arrives on phone: fetch the workout from Health, denormalise distance/duration/avgPace into `Run`, save | impl | Run row appears within a second |
| 1.9.2 | Summary view: Apple Maps with `HKWorkoutRoute` overlay, splits derived live from HK statistics, AI lines played list | UI | Map renders the route |
| 1.9.3 | Optional notes field, perceived effort 1–10 | UI | Saved |
| 1.9.4 | "Discard" deletes our companion record only; HealthKit workout is left alone (or optionally deleted with explicit confirm) | impl | — |
| 1.9.5 | History list: rows of "date · type · distance · duration · pace", newest first, sourced from companion records (`Run`s) joined to Health on demand | UI | — |
| 1.9.6 | Detail view = same as post-run summary | UI | — |

### 1.10 — Test-data safety net (D19)

The founder's iPhone hosts real training data. Before any HK write ships, the safety mechanism must be in place. Default at Phase 1 start: tag mode ON, skip mode OFF.

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 1.10.1 | `Config.isTestDataMode` (Bool, default `true`) and `Config.skipHealthKitWrite` (Bool, default `false`), persisted to `UserDefaults`, exposed as `@Observable` for UI | `Config.swift` extensions | Values persist across launches |
| 1.10.2 | Settings → "Test Data" section: two toggles, count of tagged workouts in HK, "Wipe AARC test data" button, last-wipe timestamp | `TestDataSettingsView.swift` | All controls render and persist |
| 1.10.3 | Banner on `ActiveRunView` and post-run summary while `isTestDataMode \|\| skipHealthKitWrite`: "TEST RUN — won't be permanently kept in Health" | UI | Banner visible across both screens; gone when both modes off |
| 1.10.4 | History list rows: small "TEST" badge when `RunRecord.isTestData == true` | UI | Visible on tagged rows |
| 1.10.5 | `TestDataManager.wipe()` actor: query workouts via `HKQuery.predicateForObjects(withMetadataKey: "aarc.test_data", operatorType: .equalTo, value: NSNumber(value: true))`, batch-delete via `healthStore.delete([HKObject])`, then delete matching local `RunRecord` rows | `TestDataManager.swift` | Tagged workouts and their associated samples + route disappear from Apple Health; non-tagged workouts untouched |
| 1.10.6 | `TestDataManager.testWorkoutCount()` reads the same predicate to populate the Settings count; refreshes after wipe and after each new run | impl | Count reflects reality |
| 1.10.7 | Confirmation alert before wiping (button is destructive, says "Wipe N workouts from Apple Health"); second confirm when toggling tag mode OFF ("Future runs will be permanent in Health — confirm") | UI | Cannot wipe or flip modes without explicit confirm |
| 1.10.8 | Add `isTestData: Bool` to `RunRecord` SwiftData model, set at run creation from `Config.isTestDataMode` | model migration | Old records default `isTestData = false` |
| 1.10.9 | Manual end-to-end check: do a treadmill walk + an outdoor short run with tag mode ON, confirm both appear in Apple Fitness, run `Wipe`, confirm both vanish from Apple Fitness and AARC History | manual test | Wipe demonstrably reverses both runs |

---

## Out of scope for this phase

- Voice notes / chat-reply.
- Personalities other than Roast Coach.
- Memory store beyond a stub.
- Race day mode.
- Charts / weekly mileage / PB tracking.
- Premium TTS voices.
- Sophisticated treadmill UX (it works, but `correct distance` / cadence display land in Phase 2).

## Risks specific to this phase

- **Music ducking edge cases** (R3) — verify against all four major music apps. Don't ship without this.
- **First Anthropic prompt for Roast Coach** is a tone-tuning exercise — budget time for the founder to read sample outputs aloud and iterate.
- **WatchConnectivity reliability on real devices** (R13) — test specifically: lock the watch, run for 5 min, confirm metrics catch up on wake.
- **Watch's `currentPace` derivation** — `HKLiveWorkoutBuilder` does not expose a "current pace" first-class field; we derive it from delta-distance over the last ~30s. Validate against Apple Fitness's own current pace reading.

## Demo

1. iPhone: pick Outdoor + Roast Coach. Tap "Generate" — see "ready" badge after ~5s.
2. Walk outside. Tap Start on the Apple Watch face complication.
3. Hear pre-run line within ~10s.
4. Run 30 minutes. Hear km check-ins, halfway, finish.
5. Tap End on watch.
6. iPhone post-run summary appears within a second. Map shows route. Splits look correct. AI lines list is populated.
7. Open Apple Fitness — workout is there with route + HR + splits.

## Definition of done for Phase 1

- 5 real outdoor runs by the founder using this build, no crashes, no lost runs.
- Music ducking verified across Apple Music, Spotify, Podcasts, Audible.
- A 60+ minute run with the phone locked in pocket: every expected line plays.
- Apple Fitness reflects every run.
- One AI line that made the founder laugh out loud during a run. (Subjective. Required.)
