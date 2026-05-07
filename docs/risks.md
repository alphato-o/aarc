# AARC Risks

What is most likely to go wrong, and how each phase guards against it.

Severity: **High** (could kill the product or cause data loss), **Medium** (degrades the experience), **Low** (annoying).

The watch-primary tracking model retires several phone-side risks. They are kept in the list, marked Retired, for traceability.

---

## R1 — Background GPS reliability — **Retired (was High)**

The phone is no longer the GPS host. The watch's `HKWorkoutSession` keeps the workout alive and Apple owns location reliability. Risk closed.

---

## R2 — Battery drain — **Medium (watch side)**

A 4-hour marathon on Apple Watch with continuous HR + GPS + audio cues + WC streaming is at the edge of older Apple Watches.

**Mitigation:**
- Test on an Apple Watch SE/9/10 explicitly.
- Phase 3 stress test: a 4-hour walking session in airplane mode, measure battery on watch + phone.
- Phone battery is no longer a concern for tracking; it is for audio + AI calls. Pre-generated race scripts (Phase 3) drop phone radio usage to near zero.

---

## R3 — Music ducking conflicts — **Medium**

Spotify keeps ducking forever, or music never resumes after a TTS line.

**Mitigation:**
- Use the documented `AVAudioSession` options.
- Phase 1 acceptance test against Apple Music, Spotify, Podcasts, Audible.

---

## R4 — HealthKit write failures — **Low (was High)**

Now the watch writes the workout via `HKLiveWorkoutBuilder` — Apple's most-tested HealthKit path. Failures are extremely rare.

**Mitigation:**
- The watch is the writer; the phone never duplicates a workout.
- If watch finalisation fails, the phone shows the run as "saved (companion only)" and we surface a retry. Companion data is intact regardless.

---

## R5 — TTS quality is mid — **Medium**

Default Siri voice undermines the personality.

**Mitigation:**
- Pick the highest-quality installed voice; prompt user to download Premium voice on first run.
- Phase 4: ElevenLabs cloud TTS for premium personalities (pre-rendered for race day).
- Phase 4: Personal Voice — founder records own voice.

---

## R6 — LLM cost / proxy abuse — **Medium**

Someone extracts the proxy URL and racks up Anthropic spend.

**Mitigation:**
- Phase 1: founder-only TestFlight. No real risk.
- Phase 4: App Attest enforced on proxy; per-device rate limits; daily spend cap.

---

## R7 — Race day connectivity — **High**

Marathon start area: 30,000 runners, zero signal.

**Mitigation:**
- Race mode is fully pre-generated.
- Pre-rendered TTS files for every script message.
- ScriptEngine works against local data only in race mode; the network code path is disabled.
- Phase 3 acceptance: complete a 30-minute run in airplane mode with race mode active and the script plays correctly.

---

## R8 — App Store rejection over name / AI claims — **Medium**

**Mitigation:**
- Ship as **AARC** with neutral subtitle.
- No medical claims.
- "AI generates content" disclosure in onboarding.
- A "tame" personality default for App Store review accounts.

---

## R9 — Voice note transcription accuracy — **Medium**

Wind, breathing, traffic, accent → garbage transcript → wrong AI reply.

**Mitigation:**
- Save the original audio.
- Low-confidence transcripts get a "transcript may be unreliable" hint to the LLM.
- Phase 4 polish: cloud Whisper fallback for poor on-device results.
- Always show the transcript in the post-run summary.

---

## R10 — SwiftData migration pain — **Low**

The DB now stores only companion data (no workout truth). Worst-case data loss is recoverable: workouts are in HealthKit; we can rebuild `Run` records by enumerating HK workouts and matching `aarcRunId` metadata.

**Mitigation:**
- Schema versioning from day one.
- Per-version migration logic.

---

## R11 — Pace / distance jitter at run start — **Retired (was Low)**

Apple's own algorithms handle this. Risk closed.

---

## R12 — Personality tone misfires — **Low**

Roast Coach goes too dark on a grief-day run; chat-reply says something tone-deaf.

**Mitigation:**
- Personality system prompts include safety guardrails (no slurs, no medical advice).
- "Mute companion" one tap away in ActiveRunView.
- Post-run "this line was bad" feedback action that adjusts MemoryStore.

---

## R13 — Watch ↔ Phone connectivity — **Medium**

WatchConnectivity may briefly disconnect. Live metrics stop streaming. The script engine could go silent.

**Mitigation:**
- Live metrics over WC are best-effort 1Hz; the watch independently records to HealthKit, so no data is lost.
- If no metrics for 10s while supposedly running, surface a "watch disconnected" indicator — but do not stop the run.
- Phase 1 acceptance: deliberately background the watch app for 30s; verify reconnection and ScriptEngine catch-up.
- Workout state events (started/paused/ended) use `transferUserInfo` (queued, guaranteed delivery), so even a long disconnect can't lose the start/end signal.

---

## R14 — Phone dies mid-run — **Low**

Phone battery dies. No more audio. Run continues on the watch.

**Mitigation:**
- Run survives because the watch is the workout host. HealthKit gets the workout when watch finishes.
- Phone reconciles companion data (Script played up to point of death) on next launch.

---

## R15 — Founder leaves the phone at home — **Low / by-product**

We don't support phone-less runs in V1. Watch alone has no AI brain.

**Mitigation:**
- Pre-flight check on watch: if phone is unreachable at run start, prompt "Continue without companion?" Watch still records the workout; the AI layer is just absent.
- Future feature: cache a small set of stock lines on the watch for phone-less runs. Phase 5+ if ever.
