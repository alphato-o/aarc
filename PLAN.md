# AARC — Implementation Plan

A phased, actionable plan for building **AARC (Alcoholic Anonymous Runners Club)**, a native iOS running app with an adaptive AI voice companion.

This file is the entry point. Each linked document is self-contained and intended to be read independently when executing that phase.

---

## How to read this plan

- **PLAN.md** (this file) — phasing, timeline, decisions to lock.
- **docs/architecture.md** — modules, frameworks, audio/AI flow.
- **docs/data-model.md** — entities, schema, HealthKit boundary.
- **docs/decisions.md** — open product/engineering decisions, with recommendations.
- **docs/risks.md** — what is likely to bite and how we soften the bite.
- **docs/phases/phase-0-foundation.md** — project skeleton + watch target + proxy.
- **docs/phases/phase-1-tracking-mvp.md** — MVP 1: watch tracks, phone narrates with Roast Coach.
- **docs/phases/phase-2-training-companion.md** — MVP 2: voice notes, memory, multiple personalities, history.
- **docs/phases/phase-3-race-day.md** — MVP 3: pre-generated branched race scripts, offline.
- **docs/phases/phase-4-polish.md** — MVP 4: premium voices, complications, App Store.

Each phase doc lists workstreams → tasks → deliverable → acceptance.

---

## Vision (one paragraph)

AARC is a serious-grade outdoor and treadmill run tracker that pairs an Apple Watch (which does all the actual tracking via `HKWorkoutSession` + `HKLiveWorkoutBuilder`) with an iPhone that runs the AI brain: a personalised script generated before each run, milestone TTS via the phone's speakers, async voicemail-style voice notes from the runner, and a fully offline race-day mode for when cellular dies at the start line.

---

## Guiding principles

1. **Apple owns tracking. We own the companion.** No custom GPS, distance, pace, or HR algorithms — `HKLiveWorkoutBuilder` on the watch is the source of truth. Our value is the AI layer on top.
2. **Local-first for the run.** The run must continue and be useful without network. Cloud LLMs enhance; they do not gate.
3. **The companion serves the run.** It speaks at useful moments. It shuts up otherwise. Music ducking is a first-class concern.
4. **Asynchronous voice over real-time chat.** Voicemail-style interaction avoids latency theatre and works under load.
5. **Build for one runner first** (the founder). Generalise only after that runner uses it for an actual long run cycle.
6. **HealthKit is the system of record for workouts.** Our local DB stores companion data (scripts, voice notes, AI memory). Workout truth lives in Health.

---

## Phasing

The brief defined four MVPs. Watch-primary tracking collapses what was Phase 4's "add watch" into Phase 1; the new Phase 4 becomes polish + App Store prep.

| Phase | Theme | Demo at end of phase | Effort |
|---|---|---|---|
| 0 | Foundation | iPhone + Watch app skeletons launch, request permissions, ping the proxy | 2–3 hrs |
| 1 | Tracking MVP + Roast Coach | Start run on watch, hear personalised km check-ins from phone, end on watch, see workout in Apple Fitness | 1–2 days |
| 2 | Training Companion | Voice notes + replies, memory, all 5 personalities, run history with charts, post-run AI summary | 2–3 days |
| 3 | Race Day Mode | Generate full branched marathon script, pre-render TTS, run airplane-mode race | 1–2 days |
| 4 | Polish + Store | Premium TTS, Personal Voice, complications, App Attest, App Store submission | 1–2 days |

Total: **~1–2 weeks** of agent-driven build time. Phase 1 alone is the smallest fully-validating build (it's "Nike Run Club but rude and personalised").

---

## Critical decisions (locked or default)

Full discussion in `docs/decisions.md`.

1. **Tracking model:** **Apple Watch primary, day 1.** `HKWorkoutSession` + `HKLiveWorkoutBuilder` on watch. Phone subscribes for live metrics via WatchConnectivity. No phone-only mode in V1.
2. **Domain:** **`aarun.club`** on Cloudflare. Bundle ID `club.aarun.AARC`. Proxy at `api.aarun.club`. Universal Links at `app.aarun.club`. Marketing/privacy at `aarun.club`.
3. **LLM provider:** **Anthropic Claude** (Sonnet 4.6 for generation/summary, Haiku 4.5 for chat replies) via a Cloudflare Worker proxy.
4. **Key handling:** **Server-side proxy.** Never ship API keys in the app.
5. **TTS (V1):** **AVSpeechSynthesizer** with the highest installed voice. ElevenLabs / Personal Voice in Phase 4.
6. **Storage:** **SwiftData**.
7. **Min versions:** **iOS 17, watchOS 10.**
8. **Music coexistence:** `AVAudioSession` ducking. Built into Phase 1.
9. **Distribution:** TestFlight from end of Phase 0. App Store submission in Phase 4.

---

## What we are explicitly NOT building

- Phone-only mode in V1. Pair an Apple Watch or come back later.
- Social features, friends, leaderboards, sharing. Solo product.
- Real-time bidirectional voice chat. Voicemail model only.
- Android.
- Nutrition/sleep tracking. Running only.
- Web app or dashboard. iPhone + Watch only.
- Custom map tiles. MapKit only.

---

## Definition of done for the project

The founder can:

1. Open AARC on their iPhone with their Apple Watch paired.
2. Start an outdoor run from the watch face complication, with Roast Coach selected.
3. Hear personalised milestone lines from the phone speaker (or earbuds), with music ducking properly.
4. Finish the run on the watch. See it in Apple Fitness within seconds. See the AI lines played in AARC's history.
5. Review trends — weekly mileage, long-run progression, PB tracking.
6. Send a voice note mid-run during a training day and hear a relevant reply at the next km.
7. Set up a marathon, generate the script the night before, run the marathon in airplane mode, and have it work.

That is the whole product. Everything else is a stretch goal.

---

## Index

**Phase docs**
- [Phase 0 — Foundation](docs/phases/phase-0-foundation.md)
- [Phase 1 — Tracking MVP + Scripted Companion](docs/phases/phase-1-tracking-mvp.md)
- [Phase 2 — Training Companion](docs/phases/phase-2-training-companion.md)
- [Phase 3 — Race Day Mode](docs/phases/phase-3-race-day.md)
- [Phase 4 — Polish & App Store](docs/phases/phase-4-polish.md)

**Supporting docs**
- [Architecture](docs/architecture.md)
- [Data Model](docs/data-model.md)
- [Decisions](docs/decisions.md)
- [Risks](docs/risks.md)
