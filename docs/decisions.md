# AARC Decisions

Open product/engineering decisions, with a recommendation for each. Mark **Accepted** or **Override** before/during the relevant phase.

---

## D0 — Tracking model: Watch-primary from day 1 — **Accepted**

**Context:** Apple Watch with `HKWorkoutSession` + `HKLiveWorkoutBuilder` does GPS smoothing, distance integration, pace, splits, HR sampling, and auto-pause. We can either consume Apple's authoritative metrics or write all of that ourselves.

**Decision:** **Watch-primary, day 1.** No phone-only mode in V1. Phone subscribes to live metrics over WatchConnectivity and runs the AI/audio layer.

**Consequences:**
- Phone has zero CoreLocation code, zero distance/pace algorithms.
- watchOS target ships in Phase 0.
- Founder must wear the watch on every run.
- The Phase 4 "add Watch" workstream is gone; new Phase 4 is polish + App Store.

---

## D1 — LLM provider — **Anthropic (proposed)**

**Options:** Anthropic Claude / OpenAI / Apple Intelligence on-device / Hybrid.

**Recommendation:** Anthropic — Sonnet 4.6 for generation, Haiku 4.5 for chat reply. Strong personality conditioning; mature prompt caching.

**Consequence:** API key on the proxy only.

---

## D2 — API key + proxy — **Cloudflare Worker at `api.aarun.club` (proposed)**

One TypeScript file. Free tier. Edge latency. Easy to add App Attest later. DNS for `aarun.club` is on Cloudflare nameservers; the Worker is bound to the `api.aarun.club` custom domain.

**Consequence:** Second tiny repo `aarc-proxy`. Phase 0 ships hello-world at `api.aarun.club/ping`; Phase 1 wires up `/generate-script`. App config hard-codes the hostname so we never depend on a `*.workers.dev` URL.

---

## D3 — Proxy abuse prevention

**Recommendation:** No auth in Phase 1 (founder-only TestFlight). Apple App Attest before any wider distribution (Phase 4).

---

## D4 — TTS engine — **AVSpeechSynthesizer for V1 (proposed)**

Apple's installed voices (Premium/Enhanced when available). ElevenLabs and Personal Voice are Phase 4 polish.

**Consequence:** Personality tone is conveyed through wording and cadence in V1. Acceptable.

---

## D5 — Persistence — **SwiftData (proposed)**

**Note:** With watch-primary tracking, our local DB shrinks dramatically — only companion data, not workout truth. SwiftData is more than adequate.

---

## D6 — Minimum versions — **iOS 17, watchOS 10 (proposed)**

Buys SwiftData + Observation framework + WorkoutKit niceties. Founder is on a current iPhone and Apple Watch.

---

## D7 — Music coexistence — **Accepted**

`AVAudioSession` `.playback` / `.spokenAudio` / `[.mixWithOthers, .duckOthers]`. Confirmed compatible with Apple Music, Spotify, Podcasts, Audible.

---

## D8 — Map provider — **Accepted**

MapKit. Reads `HKWorkoutRoute` from HealthKit and overlays.

---

## D9 — Voice interaction model — **Accepted**

Voicemail / async, per the brief. No real-time voice chat in V1.

---

## D10 — Personality system prompts — **Server-side (proposed)**

Manifest (name, description, exposed settings) bundled in the app for offline UI. The actual system prompt lives on the proxy and can be tuned without an app update.

---

## D11 — Treadmill mode — **Use HKWorkoutSession indoor mode (proposed)**

`HKWorkoutConfiguration(activityType: .running, locationType: .indoor)`. Apple computes distance from wrist accelerometry — usually within ~3% on modern Apple Watches. Still expose a "correct distance" button on the post-run summary that updates the workout via HealthKit.

This is much simpler than the original "phone-side CMPedometer" plan.

---

## D12 — Subscription / monetisation — **Deferred**

No paywall through Phase 4. Premium voices (ElevenLabs / Personal Voice) are the obvious paid tier when it's time.

---

## D13 — Telemetry / crash reporting — **MetricKit only for V1 (proposed)**

Manual TestFlight feedback for now. Add Sentry only when we have more than one user.

---

## D14 — App Store name — **AARC + neutral subtitle (proposed)**

Ship as **AARC** with subtitle like "AI Running Companion". Keep the working expansion in marketing and personality prompts where appropriate. Avoid medical/health claims.

---

## D15 — Personal Voice — **Phase 4 polish (proposed)**

iOS 17 Personal Voice lets the founder record their own voice. Excellent demo value, zero ongoing cost. Schedule for Phase 4.

---

## D16 — Workout-to-companion linking — **Workout metadata (proposed)**

Watch stamps the finished workout with `metadata: ["aarcRunId": runId.uuidString]` before `finishWorkout`. Phone reads this to associate Health workouts with our companion records.

**Consequence:** Lossless link even if our local DB is wiped — we can reconstruct the run-companion mapping by enumerating Health workouts.

---

## D17 — Split source of truth — **Derive from HK distance statistics (proposed)**

We do not store split rows in our DB. We derive them per-render by querying `HKStatisticsCollectionQuery` over the workout's interval. Cheap, always consistent with Apple Fitness.

---

## D18 — Domain and hostnames — **Accepted**

Domain: **`aarun.club`** (registered, DNS to be moved to Cloudflare in Phase 0).

| Hostname | Purpose | Phase |
|---|---|---|
| `api.aarun.club` | Cloudflare Worker proxy: `/ping`, `/generate-script`, `/chat-reply`, `/post-run-summary`, `/tts` | 0+ |
| `app.aarun.club` | Universal Links + Associated Domains. Hosts `apple-app-site-association`. Used for deep links (`/race/:id`, share links from Phase 3) | 0 (reserve), 3+ (use) |
| `aarun.club` / `www.aarun.club` | Marketing / landing site | Post-launch (Phase 4 if time, else later) |

**Consequences:**
- App ships pointing at `https://api.aarun.club` from build 1. Never a `*.workers.dev` URL in shipped bundles.
- Universal Links need `app.aarun.club/.well-known/apple-app-site-association` published before any link-based feature ships (Phase 3 race-share, etc.).
- Privacy policy (required for App Store) lives at `aarun.club/privacy`. Stand up a one-pager before App Store submission in Phase 4.
- Bundle ID `club.aarun.AARC` is consistent with the domain.
