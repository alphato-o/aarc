# AARC

**Alcoholic Anonymous Runners Club** — a native iOS + watchOS running app with a live AI voice coach, built solo, for long-distance training and marathon racing.

> The Apple Watch tracks the run. The iPhone runs the brain. Ricky — a savage British roast-coach — reacts in real time to your pace, your heart rate, your splits and the music in your ears. Real lines, generated mid-run, spoken at the right moment — and silent when silence is better.

Status: **working product in daily training use.** Marketing site + waitlist at [aarun.club](https://aarun.club).

---

## What it does

- **Serious tracking** — `HKWorkoutSession` on the watch is the source of truth (GPS, pace, heart rate, splits); the phone mirrors it live over WatchConnectivity. Start a run on the phone and the watch app launches itself. Phone-only runs work too.
- **Live AI coaching** — a scripted backbone (per-km / halfway / finish lines personalised before each run) plus a reactive layer that fires on what's actually happening: pace surges, HR spikes, standing still, a song change. Lines are LLM-generated, spoken via ElevenLabs, with on-device TTS as fallback.
- **Music-aware** — knows what's playing and times the banter around the track instead of over it, with transient ducking while a line plays.
- **Orchestrated, not chatty** — a run **Director** owns the timeline (milestones are protected slots), a single priority queue paces every utterance, stale lines expire instead of playing late, and synthesis is coalesced so the voice never stacks up.
- **Full run replay** — every run's metrics, events and spoken audio are archived (D1 + R2) and replayable end-to-end in a web dashboard: speed/HR chart, clickable voice timeline, and a debug mode with the event log and network waterfall.
- **Share cards** — turn a run into a social image (quote-centred, four layouts: quote / km-splits / route / elevation) or a short video where the line's actual audio plays back with a karaoke-style word highlight. All rendered client-side (Canvas + MediaRecorder, MP4 on Chromium/Safari).
- **Test & recovery infrastructure** — a desk simulator (synthetic metrics, operator controls: pace, HR spikes, jumps) and a flagged "real run" test mode, neither of which writes to Apple Health; recently-deleted runs with 30-day retention, cloud-synced soft delete, and an importer that recovers orphaned watch workouts from Apple Health.

The coach's persona prompts live in an untracked private module — the repo ships the machinery, not the personality.

---

## Architecture

```
Apple Watch (AARCWatch)              iPhone (AARC)                       Cloud
┌────────────────────────┐   WC    ┌───────────────────────────┐  HTTPS ┌──────────────────────────┐
│ HKWorkoutSession       │ ──────▶ │ LiveMetricsConsumer       │ ─────▶ │ Cloudflare Worker        │
│ live pace/HR/distance  │         │ RunDirector + ScriptEngine│        │  /generate-script        │
│ workout-style UI       │         │ ContextualCoach + queue   │        │  /dynamic-line /tts …    │
└────────────────────────┘         │ Speaker → ElevenLabs/local│        │ D1 (runs) + R2 (audio)   │
                                   │ RunEventLog → ingest      │        │ dashboard + landing site │
                                   └───────────────────────────┘        └──────────────────────────┘
```

- One Worker serves three hostnames: `api.aarun.club` (app API + ingest), `my.aarun.club` (the replay dashboard, QR-approved auth), and `aarun.club` (public landing + waitlist).
- A standalone Node port of the proxy (`proxy/server/`, Docker + Caddy) runs on a VPS as a network-path fallback; the app's `EndpointManager` fails over between endpoints automatically.
- Errors on both sides report to Sentry.

## Repo structure

```
aarc/
├── README.md            ← you are here
├── AGENTS.md            ← briefing + ground rules for AI coding agents
├── PLAN.md              ← original planning entry point (historical)
├── docs/                ← architecture, data model, decisions, risks, phase plans
├── ios/
│   ├── project.yml      ← xcodegen source of truth (.xcodeproj is generated)
│   ├── AARC/            ← iPhone app (SwiftUI)
│   ├── AARCWatch/       ← watch app (SwiftUI + HealthKit)
│   └── AARCKit/         ← shared Swift package (host-testable)
├── proxy/               ← Cloudflare Worker (TypeScript): API, ingest, dashboard, landing
│   └── server/          ← Node port of the proxy for VPS deployment (Docker)
├── scripts/             ← bump-build.sh, icon generation
└── private/             ← untracked: secrets + founder/agent exchange (gitignored)
```

iOS tests live inside the Xcode test targets (platform convention — no top-level `tests/`). `AARCKit` tests run on the host with plain `swift test`.

## Tech stack

| Layer | Choice |
|---|---|
| iOS app | SwiftUI, SwiftData, AVFoundation, ActivityKit (Live Activity), Swift 6 strict concurrency |
| watchOS app | SwiftUI, HealthKit (`HKWorkoutSession` + `HKLiveWorkoutBuilder`) |
| Shared code | Swift package `AARCKit` (in-repo) |
| LLM | Claude via proxy (OpenRouter / Anthropic, switchable per-deployment) |
| TTS | ElevenLabs (primary) with `AVSpeechSynthesizer` fallback; per-voice audio cache |
| Proxy | Cloudflare Worker, TypeScript, D1 (run logs), R2 (voice archive) |
| Dashboard / landing | Self-contained vanilla JS + SVG/Canvas served by the Worker — no frontend build step |
| Monitoring | Sentry (proxy + iOS) |
| Min versions | iOS 17, watchOS 10 |

## Domains

| Hostname | Purpose |
|---|---|
| `api.aarun.club` | Worker API: script/line generation, TTS, run ingest, replay reads |
| `my.aarun.club` | Run replay dashboard (sign-in via QR approved on the phone) |
| `aarun.club` | Public landing page + waitlist |
| `gateway.aarun.club` | VPS fallback endpoint (Node proxy port) |

Bundle IDs: `club.aarun.AARC` (iOS), `club.aarun.AARC.watchkitapp` (watch).

---

## Development

### One-time setup

```sh
brew install xcodegen        # generates ios/AARC.xcodeproj from project.yml
cd proxy && npm install      # Cloudflare Worker deps
```

### iOS / watchOS

The `.xcodeproj` is generated, not committed. Source of truth: [`ios/project.yml`](ios/project.yml).

```sh
cd ios
xcodegen generate            # creates AARC.xcodeproj
open AARC.xcodeproj
# Set your Apple Developer Team in Signing & Capabilities for both
# AARC and AARCWatch targets, then Run.
```

Run AARCKit's tests on the host without Xcode:
```sh
cd ios/AARCKit && swift test
```

### Cloudflare Worker (proxy)

```sh
cd proxy
npm run dev                  # local at http://localhost:8787
npm run typecheck            # tsc --noEmit
npm run deploy               # wrangler deploy (all three hostnames)
npx wrangler d1 migrations apply aarc-runs --remote   # after adding a migration
```

Secrets (`wrangler secret put …`): provider API keys, `DEVICE_TOKEN` (ingest/dashboard auth), `SENTRY_DSN`.

> Editing `dashboardApp.ts` / `landing.ts`: the embedded JS lives inside TS template literals — backticks, `${`, and **every regex backslash** must be escaped (`\\s`, not `\s`), or they silently degrade in the served page.

### Pointing the iOS app at a local proxy

In Xcode, edit the `AARC` scheme → Run → Arguments → Environment Variables, add `AARC_API_BASE_URL=http://localhost:8787` for debug builds. Production builds use the bundled endpoint list with automatic failover.

### Quick iteration loop

```sh
git pull
cd ios && xcodegen generate
open AARC.xcodeproj
# ⌘R with AARC scheme + iPhone destination
```

After deploy: check the **build number on the watch home screen** (and iPhone Settings → About). If both match `CURRENT_PROJECT_VERSION` in `ios/project.yml`, you're on the latest build. It's bumped on every code-change push by `scripts/bump-build.sh` (see AGENTS.md).

To exercise the full voice pipeline without leaving your desk: Run screen → enable test mode → **Simulate at my desk**, then drive pace/HR/position from the Control Room. Test runs are flagged, excluded from Apple Health, and batch-deletable.

### Deploying only the watch app

When the iOS code didn't change but the watch did, skip the full iOS install:

1. Toolbar scheme dropdown → switch from **AARC** to **AARCWatch**
2. Destination dropdown → your Apple Watch by name
3. ⌘R — Xcode pushes the watch bundle through the iPhone

Switch back to the **AARC** scheme afterwards.

### When to clean or delete

You almost never need to. Day-to-day, incremental builds + reinstalls are correct. Reach for these only when something is visibly broken:

- **⌘⇧K (Clean Build Folder)** — signature seal mismatches, "module not found" after a refactor, Xcode insists nothing has changed
- **Delete app from iPhone** — capabilities or entitlements changed and provisioning needs to re-bind
- **Force-quit watch app** (swipe away in recents) — when you suspect watchOS is keeping an older instance warm
- **`rm -rf ~/Library/Developer/Xcode/DerivedData/AARC-*`** — last-resort nuke when ⌘⇧K isn't enough

More gotchas: [`docs/troubleshooting.md`](docs/troubleshooting.md).

---

## License

[Apache License 2.0](LICENSE).
