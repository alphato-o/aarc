# AARC Data Model

SwiftData entities and their relationships. **HealthKit is the system of record for workout data**, including route, HR, energy, and per-sample data — written by the watch's `HKLiveWorkoutBuilder`. The local SwiftData store holds only what HealthKit can't or shouldn't: companion-side data.

---

## What lives where

| Data | Where | Why |
|---|---|---|
| Workout (running) | HealthKit | Watch writes via `HKWorkoutSession` |
| Route points | HealthKit (`HKWorkoutRoute`) | Watch writes via `HKWorkoutRouteBuilder` |
| Heart rate samples | HealthKit | Apple's sample rate, system-wide truth |
| Active energy | HealthKit | Apple computes |
| Distance, pace, splits | HealthKit (statistics + builder events) | Apple computes |
| Companion script | SwiftData | Custom data |
| AI messages played | SwiftData | Custom data |
| Voice notes (audio + transcript) | SwiftData (metadata) + filesystem (audio) | Custom data |
| AI replies | SwiftData | Custom data |
| User memory / preferences | SwiftData | Custom data |
| Race setups | SwiftData | Custom data |
| Pre-rendered race TTS | filesystem (referenced from SwiftData) | Custom data, large blobs |

The link from a HealthKit workout to our companion data is the workout's `metadata` dictionary, where we stash `aarcRunId: UUID` at workout-finish time. To find a HK workout's companion data, query SwiftData by that UUID.

---

## Entities

### `Run` (SwiftData)

The companion-side record for one workout. Workout truth (distance, duration, route, HR) is fetched from HealthKit on demand using `healthKitWorkoutUUID`.

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | PK; also written into HK workout metadata |
| `startedAt` | Date | snapshot from HK on save |
| `endedAt` | Date? | snapshot from HK on save |
| `runType` | enum (`outdoor`, `treadmill`) | Mirrors HK `locationType` |
| `mode` | enum (`free`, `training`, `race`) | Drives ScriptEngine behaviour |
| `personality` | String | e.g., `roast_coach` |
| `healthKitWorkoutUUID` | UUID? | Set after watch finishes the workout |
| `script` | `Script?` | One-to-one |
| `voiceNotes` | `[VoiceNote]` | One-to-many |
| `aiMessagesPlayed` | `[PlayedMessage]` | One-to-many |
| `userNotes` | String? | Post-run free text |
| `perceivedEffort` | Int? | 1–10 |
| `label` | String? | "Long run", "Race – Berlin" |
| `summaryText` | String? | AI-generated post-run summary |
| `cachedDistanceMeters` | Double? | Snapshot for fast list rendering, sourced from HK |
| `cachedDurationSeconds` | Double? | Same |
| `cachedAvgPaceSecPerKm` | Double? | Same |

`cached*` fields are denormalised purely so the History list doesn't have to await HealthKit on every row render. Refreshed on save and lazily on access.

### `Script`

The generated companion script for a run.

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | PK |
| `runId` | UUID | FK |
| `personality` | String | |
| `generatedAt` | Date | |
| `model` | String | `claude-sonnet-4-6` etc. |
| `inputDigest` | String | Hash of inputs; lets us skip regeneration |
| `messages` | `[ScriptMessage]` | |
| `branchPolicy` | enum (`linear`, `branched`) | Race day uses `branched` |

### `ScriptMessage`

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | PK |
| `triggerSpec` | JSON | See trigger spec below |
| `text` | String | The line |
| `branchKey` | String? | e.g., `ahead_of_pace_10k`; used by branch selector |
| `prerenderedAudioPath` | String? | Phase 3 — pre-rendered TTS file |
| `priority` | Int | Default 50; race-critical messages override |
| `playOnce` | Bool | Default true |

### `PlayedMessage`

| Field | Type | Notes |
|---|---|---|
| `messageId` | UUID | FK to ScriptMessage |
| `playedAt` | Date | |
| `runId` | UUID | FK |
| `wasInterrupted` | Bool | |

### `VoiceNote`

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | PK |
| `runId` | UUID | FK |
| `recordedAt` | Date | |
| `audioFilePath` | String | local M4A in app container |
| `transcript` | String? | |
| `transcriptionStatus` | enum (`pending`, `done`, `failed`) | |
| `aiReplyId` | UUID? | FK |

### `AiReply`

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | PK |
| `voiceNoteId` | UUID | FK |
| `replyText` | String | |
| `requestedAt` | Date | |
| `respondedAt` | Date? | nil while in queue |
| `playedAt` | Date? | |
| `model` | String | |
| `costUsd` | Double? | optional accounting |

### `UserMemory`

Flat key-value-ish store for prefs and soft facts.

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | PK |
| `kind` | enum (`preference`, `goal`, `fact`, `dislike`, `personalReference`) | |
| `key` | String | e.g., `swearing.allowed`, `goal.race.berlin_2026.target_time` |
| `value` | String (JSON) | |
| `confidence` | Double | 1.0 if user-set; <1.0 if AI-inferred and pending confirmation |
| `source` | enum (`user`, `ai_inferred`, `system_default`) | |
| `updatedAt` | Date | |

### `RaceSetup` (Phase 3)

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | PK |
| `name` | String | "Berlin Marathon 2026" |
| `distanceMeters` | Double | |
| `targetTimeSeconds` | Double | |
| `pacingStrategy` | enum (`even`, `negative`, `positive`, `custom`) | |
| `fuelingPlan` | `[FuelingCue]` | |
| `hydrationPlan` | `[HydrationCue]` | |
| `notes` | String? | course quirks |
| `scriptId` | UUID? | pre-generated race script |
| `runId` | UUID? | set after race day |

---

## Trigger spec (DSL inside `ScriptMessage.triggerSpec`)

JSON shapes the ScriptEngine evaluates. Keep small.

```json
{ "type": "distance", "atMeters": 1000 }
{ "type": "distance", "everyMeters": 1000 }
{ "type": "time", "atSeconds": 1800 }
{ "type": "halfway" }
{ "type": "near_finish", "remainingMeters": 500 }
{ "type": "condition",
  "expression": "pace_3min_ratio > 1.05 AND distance > 8000",
  "branchKey": "too_fast_late",
  "cooldownSeconds": 240 }
{ "type": "fatigue_zone",
  "expression": "hr_zone >= 4 AND distance > 25000" }
```

Whitelisted variables: `distance`, `duration`, `current_pace`, `avg_pace`, `target_pace`, `pace_3min_ratio`, `hr`, `hr_zone`, `cadence`, `time_of_day_hour`. Hand-written evaluator; the LLM is told the grammar and we validate.

The `pace_3min_ratio` and `hr_zone` derivations live in the phone's `ScriptEngine`, computed off the watch's published `LiveMetrics` snapshots.

---

## Fetching workout truth on demand

When rendering history detail, splits, route, HR chart:

```swift
func loadWorkoutTruth(for run: Run) async throws -> WorkoutTruth {
    let workout = try await healthStore.fetchWorkout(uuid: run.healthKitWorkoutUUID!)
    async let route = healthStore.fetchRoute(for: workout)
    async let hrSeries = healthStore.fetchHeartRate(during: workout)
    async let splits = healthStore.fetchSplits(for: workout)  // derived from distance statistics
    return try await WorkoutTruth(workout: workout, route: route, hrSeries: hrSeries, splits: splits)
}
```

Splits are derived from `HKStatisticsCollectionQuery` over the workout's interval. Apple does not expose them as first-class objects; integrating distance per km is straightforward and uses Apple's distance numbers, not our own.

---

## Storage volumes (back-of-envelope)

- Voice note: 30s M4A ≈ 250KB. A heavy training month ≈ 30MB.
- Pre-rendered race TTS: 200 messages × ~10s avg @ AAC 64kbps ≈ ~16MB per race.
- Companion records: kilobytes per run.

No quota strategy needed for V1.
