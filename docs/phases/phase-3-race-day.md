# Phase 3 — Race Day Mode

**Goal:** A race day that survives no signal, no patience, and no second chances. The night before, generate a complete branched script with hydration and fueling cues; pre-render every line to local TTS; on race day, run entirely offline.

**Outcome:**
> Night before: founder sets up "Berlin Marathon — 3:25 target — even pacing — fueling at 8/16/24/32/38km — hydration every 5km". App generates a branched script (~150 messages including ahead/on/behind variants), pre-renders ~30MB of M4A. Race morning: airplane mode on, start the race on the watch, the phone delivers the right line at the right moment for 42.2km without ever touching the network. If founder drifts off pace, the right branch plays — "you're 25 seconds down at 21k, that's recoverable, hold 4:50 here and earn it back over the next 10k."

**Estimated effort:** **1–2 days.**

**Dependencies:** Phase 2 complete.

---

## Workstreams

### 3.1 — Race setup wizard

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 3.1.1 | `RaceSetup` SwiftData entity per data-model.md | model | CRUD works |
| 3.1.2 | Multi-step wizard: name → distance (5k/10k/HM/marathon/custom) → target time → pacing strategy (even/negative/positive/custom) → fueling plan → hydration plan → notes → personality | UI | <2 minutes to complete |
| 3.1.3 | Pacing strategy → per-km target pace curve | `PacingPlan.swift` | Even = constant; negative = 5s/km faster each 10k; positive = inverse |
| 3.1.4 | Fueling plan: list of (distanceKm, what) | UI | Saved with race |
| 3.1.5 | Hydration plan: every Nkm or fixed list | UI | Saved with race |
| 3.1.6 | Course notes (free text) feed the LLM | UI | Visible in generated script |

### 3.2 — Branched script generation

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 3.2.1 | Proxy endpoint `POST /generate-race-script` returning branched output | TS | Schema validated |
| 3.2.2 | Schema: every km milestone has three variants — `on_pace`, `ahead_of_pace`, `behind_pace`, plus pre-race, halfway, fatigue zones, near-finish, finish | TS | All variants present |
| 3.2.3 | Branch keys are deterministic; the engine selects without any LLM during run | impl | Tests cover all branch keys |
| 3.2.4 | Generation includes warm-up briefing (pre-race), start line, halfway variants, "the wall" messages from ~30k onward | impl | Manual review confirms |
| 3.2.5 | Token budget tuned (~4–6k output tokens for marathon); prompt-cached | proxy | Cache hits visible |

### 3.3 — Local TTS pre-rendering

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 3.3.1 | Pre-render every script message via `AVSpeechSynthesizer.write(_:toBufferCallback:)` to local M4A | `TTSPrerender.swift` | Marathon script (~150 messages) renders in <60s on iPhone 15 |
| 3.3.2 | Store path on `ScriptMessage.prerenderedAudioPath` | impl | Files exist |
| 3.3.3 | UI progress bar with cancellable affordance | UI | Cancellable |
| 3.3.4 | Verify total disk footprint (target <30MB) | manual | — |
| 3.3.5 | Cleanup on race deletion | impl | — |

### 3.4 — Branch selector (offline decision engine)

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 3.4.1 | `BranchSelector` consumed by ScriptEngine in race mode: picks `on/ahead/behind` from current vs target pace | `BranchSelector.swift` | Pace 5%+ above target sustained 60s → `behind` chosen at next km |
| 3.4.2 | Hysteresis: ±3% wobble does not flip branches | impl | Tested |
| 3.4.3 | Drift detection: cumulative time delta from target informs branch at halfway / 30k / finish | impl | Consistently slow runner gets the "way behind" branch at 30k, not just per-km behind |
| 3.4.4 | Critical-priority cues (fueling, hydration) bypass branch logic entirely; can interrupt mid-utterance with a 2-second grace | impl | Fuel cue plays even mid line |

### 3.5 — Race-mode runtime

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 3.5.1 | `RunMode.race` disables AIClient calls during the run entirely | impl | No requests made — verified by network logging |
| 3.5.2 | Race ActiveRunView (phone): target pace, current pace, time delta, next milestone, next fueling cue countdown | UI | Distinguishable from training |
| 3.5.3 | Pre-flight check: script generated, all TTS files present, watch paired & charged ≥80%, phone ≥50% | UI | Block start if any check fails |
| 3.5.4 | Live Activity (iOS 16+) showing time, distance, target delta on lock screen | impl | Visible on lock screen |
| 3.5.5 | Crash recovery: if app crashes mid-race, relaunch resumes from disk state and reattaches to the watch's running session | impl | Manual kill + relaunch keeps tracking + audio |

### 3.6 — Post-race

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 3.6.1 | Race summary view: actual vs target per km, fueling actually played, total time, splits — all sourced from HealthKit | UI | — |
| 3.6.2 | Once back online, generate a special post-race summary using race plan + actual run | proxy + Swift | "You hit target through 30k, faded 12s/km in the last 10k. Hydration reminder at 25k missed because you were still recovering from the 24k gel." |
| 3.6.3 | Race archive: completed races accumulate, comparable across attempts | UI | A second marathon shows side-by-side with first |

### 3.7 — Polish

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 3.7.1 | Cloud Whisper fallback for low-confidence on-device transcripts (carried over from Phase 2 backlog) | proxy + Swift | Triggers only when confidence below threshold |
| 3.7.2 | "Test race mode" button in race detail: simulates a 5-minute fast-forward run with mocked metrics so the founder can hear the script before race day | dev tool / hidden button | Useful pre-race rehearsal |

---

## Out of scope

- Live tracking / family-can-watch features.
- Music auto-play during race.
- Multi-runner pacing groups.
- Apple Watch UI changes specific to race mode beyond what the watch already shows during running (Phase 4 polish).

## Risks specific to this phase

- **R7 (race day connectivity)** — biggest risk in the project. Rehearse offline runs at least three times during this phase before declaring done.
- **Pre-render audio failure mid-flight** — any single message render failure leaves a gap. Treat as fatal pre-flight error and re-run.
- **Branch selection feels stuck** — hysteresis tuning needs real-run data; budget time for it.
- **iOS Live Activities lifetime** — confirm the activity survives a 4-hour run.

## Demo

1. Night before: open AARC, tap "New race". Enter Berlin Marathon, 3:25, even pace, fueling at 8/16/24/32/38, hydration every 5km, notes "hill at 30k".
2. Tap "Generate" — wait ~20 seconds.
3. Tap "Pre-render audio" — wait ~30 seconds, see progress.
4. Race morning: open app. See "Berlin Marathon — ready" badge with green check. Toggle airplane mode on.
5. Walk outside. Tap Start on the watch.
6. Run for 30 minutes (rehearsal). Hear opening line, km check-ins, deliberately speed up at km 3 → at km 4 hear "ahead of pace" branch. Slow down → at km 5 hear "back on pace, hold this". At km 8 (simulated fuel mark) hear "gel now".
7. End. Disable airplane mode. Post-race summary lands on next save.

## Definition of done

- A complete simulated race in airplane mode with no missed messages, no playback errors, no GPS issues, no battery panic.
- Branch selection feels right when manually flipping pace.
- Founder reports they would actually use this for their real race. (Required.)
- A real marathon run with this build successfully (calendar-bound — ship the build first).
