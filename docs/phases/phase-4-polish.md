# Phase 4 — Polish & App Store

**Goal:** Take the working product over the line: premium voices, watch face complications and richer watch UI, App Attest on the proxy, App Store submission, founder polish pass.

The watch app already exists from Phase 0 onward; this phase makes it pretty and ships everything to the App Store.

**Outcome:**
> Roast Coach speaks in the founder's own voice (Personal Voice). Race Strategist speaks in a chosen ElevenLabs voice. The watch face has a one-tap "Start AARC" complication. The proxy refuses requests without a valid App Attest. The app is in App Store review.

**Estimated effort:** **1–2 days.**

**Dependencies:** Phase 3 complete.

---

## Workstreams

### 4.1 — Premium TTS

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 4.1.1 | ElevenLabs SDK or REST integration through proxy `/tts` (proxy holds the key) | TS + Swift | A test line plays in chosen voice |
| 4.1.2 | Phase 3 race scripts can pre-render with ElevenLabs voices instead of AVSpeechSynthesizer | impl | ~30MB → ~50MB; quality huge step up |
| 4.1.3 | Personality → voice mapping in settings; user picks a voice per personality | UI | Persists |
| 4.1.4 | Cost guard: ElevenLabs use only when user opts in (it's the eventual paid SKU) | impl | Default off |

### 4.2 — Personal Voice

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 4.2.1 | Onboarding screen explaining Personal Voice (iOS 17 feature) | UI | — |
| 4.2.2 | Detect installed Personal Voices via `AVSpeechSynthesisVoice` API | impl | Founder's recorded voice appears in voice picker |
| 4.2.3 | Surface as a top-tier option in the voice picker | UI | — |

### 4.3 — Watch UX polish

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 4.3.1 | Three watch face complications: "Start Roast Coach", "Resume race", "Last run quick stats" | impl | Visible across face families |
| 4.3.2 | Improved in-run watch UI: paged metric screens (HR / pace / split / AI message log), crown to scroll | UI | Clean, glanceable |
| 4.3.3 | Distinct haptic patterns: kmMilestone vs pacingWarning vs fuelingReminder | impl | Distinguishable in actual run |
| 4.3.4 | "Silent run" mode: haptics on, audio muted (companion still picks lines and logs them) | UI toggle | Useful in quiet environments |
| 4.3.5 | Always-on display friendly | UI | Stays usable in always-on |

### 4.4 — App Attest on the proxy

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 4.4.1 | App-side: generate App Attest assertion on each proxy call | Swift | Header set |
| 4.4.2 | Proxy-side: validate assertion against Apple's keys | TS | Invalid requests rejected with 401 |
| 4.4.3 | Per-device rate limit: 200 req/day baseline | TS / Cloudflare | Bucket enforced |
| 4.4.4 | Daily spend cap on Anthropic | proxy alarm | Trips at $5/day for now |

### 4.5 — App Store submission

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 4.5.1 | App icon, splash, screenshots (5 per device size) | assets | Approved by founder |
| 4.5.2 | Privacy nutrition labels: HealthKit (read+write), microphone, speech recognition, IP-only network | App Store Connect | Filled |
| 4.5.3 | App Privacy Policy hosted at `aarun.club/privacy` (one-page Cloudflare Pages site is fine) | URL | Linked in App Store |
| 4.5.4 | "AI generates content" disclosure in onboarding | UI | Visible |
| 4.5.5 | App name **AARC** + subtitle "AI Running Companion" | App Store | — |
| 4.5.6 | Default to Calm Coach for App Store reviewer accounts (or include a tame review build) | impl | Reviewer doesn't get yelled at |
| 4.5.7 | Submit to TestFlight external testers (small founder-curated group), then App Review | App Store Connect | — |

### 4.6 — Founder pass

| # | Task | Deliverable | Acceptance |
|---|---|---|---|
| 4.6.1 | Bug bash: every screen visited, every flow exercised, every personality run for 10 minutes outside | bug list | Triaged into fix-now / later |
| 4.6.2 | Performance pass: cold launch <1s, run-start latency <500ms after Start tap, no jank in Trends charts | manual | Measured |
| 4.6.3 | Copy pass: every UI string read aloud and rewritten if it sounds robotic | UI | — |
| 4.6.4 | Error states: every "what if it fails" flow has a real error UI, not a debug alert | UI | Spot-checked |

---

## Out of scope

- Standalone watch-only runs (phone left at home). Considered later.
- Multi-runner pacing groups.
- Strava / Garmin export.
- Subscription / paywall (premium voices stay free for the founder; SKU comes later).

## Risks specific to this phase

- **App Review unpredictability** — name, AI claims, audio that mocks the user. Mitigations in 4.5.4–4.5.6. Budget a re-submission round.
- **ElevenLabs cost** — even a few minutes of pre-rendered TTS adds up. Cap with daily spend alert; default off.
- **Personal Voice availability** — only iOS 17+ on supported devices, requires a 15-minute recording session. Document in onboarding.

## Demo

1. Founder picks "Roast Coach" with their own Personal Voice. Hears their own voice insulting them at km 1. Demo immediately wins.
2. Switches to "Race Strategist" with a chosen ElevenLabs voice — sounds like an actual coach.
3. Watch face: tap complication, run starts.
4. Open Settings → "Send proxy ping with bad attest" debug button — confirm 401 from proxy.
5. Open App Store Connect — build is in review.

## Definition of done

- Premium voices working end-to-end for at least one personality.
- Personal Voice detected and selectable.
- Watch complication and in-run UI feel polished, not scaffold-y.
- Proxy rejects unauthenticated calls.
- App is in App Store review (or live, depending on luck).
- Founder declares the product shippable to a friend without disclaimers.
