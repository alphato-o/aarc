# AARC

**Alcoholic Anonymous Runners Club** — a native iOS running app with a personalised AI voice companion, built for long-distance training and marathon racing.

> Apple Watch tracks the run. iPhone runs the AI brain. The companion adapts to your run, your history, your mood, and your preferred coaching style — and shuts up when it should.

Status: **Phase 0 in progress.**

---

## Why

Nike Run Club's guided runs are pre-recorded — dynamic in trigger, static in content. AARC keeps the serious-grade tracking layer of NRC and replaces the coaching layer with a generative one: a script personalised to the runner before each run, delivered via local TTS at meaningful moments, with optional async voice-note interaction during training and a fully offline mode for race day.

Long-form rationale: see [`PLAN.md`](PLAN.md). Product brief lives in the issue tracker.

---

## Repo structure

```
aarc/
├── README.md          ← you are here
├── AGENTS.md          ← briefing for AI coding agents
├── PLAN.md            ← entry point to all planning docs
├── docs/              ← architecture, data model, decisions, risks, phase plans
│   ├── architecture.md
│   ├── data-model.md
│   ├── decisions.md
│   ├── risks.md
│   └── phases/
├── ios/               ← Xcode workspace (iOS app + watchOS app + tests)
└── proxy/             ← Cloudflare Worker (LLM + TTS proxy at api.aarun.club)
```

iOS unit and UI tests live inside the Xcode project's test targets, not in a top-level `tests/` directory — that's the platform convention.

---

## Quick links

- [Master plan](PLAN.md)
- [Architecture](docs/architecture.md)
- [Data model](docs/data-model.md)
- [Decisions log](docs/decisions.md)
- [Risk register](docs/risks.md)
- [Phase 0 — Foundation](docs/phases/phase-0-foundation.md)

---

## Tech stack

| Layer | Choice |
|---|---|
| iOS app | SwiftUI, SwiftData, AVFoundation, Speech framework |
| watchOS app | SwiftUI, HealthKit (`HKWorkoutSession` + `HKLiveWorkoutBuilder`) |
| Cross-target shared | Swift Package `AARCKit` (in-repo) |
| Tracking | Apple Watch is the source of truth; phone subscribes via WatchConnectivity |
| LLM | Anthropic Claude (Sonnet 4.6 + Haiku 4.5) via the Worker proxy |
| TTS | `AVSpeechSynthesizer` (V1); ElevenLabs / Personal Voice (Phase 4) |
| Proxy | Cloudflare Worker, TypeScript, deployed at `api.aarun.club` |
| Min versions | iOS 17, watchOS 10 |

---

## Domain

`aarun.club`, on Cloudflare DNS.

| Hostname | Purpose |
|---|---|
| `api.aarun.club` | Worker proxy: `/ping`, `/generate-script`, `/chat-reply`, `/post-run-summary`, `/tts` |
| `app.aarun.club` | Universal Links / Associated Domains |
| `aarun.club` | Marketing + privacy policy |

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
npx wrangler dev             # local at http://localhost:8787
# In another shell:
curl http://localhost:8787/ping
```

To deploy to `api.aarun.club`:
```sh
npx wrangler login           # browser-based Cloudflare auth, one-time
npx wrangler deploy
```

`wrangler.toml` declares the custom domain binding; deploy will create the `api.aarun.club` route automatically as long as the `aarun.club` zone is on the same Cloudflare account.

### Pointing the iOS app at a local proxy

In Xcode, edit the `AARC` scheme → Run → Arguments → Environment Variables, add `AARC_API_BASE_URL=http://localhost:8787` for debug builds. Production builds always hit `https://api.aarun.club`.

### Quick iteration loop

```sh
git pull
cd ios && xcodegen generate
open AARC.xcodeproj
# ⌘R with AARC scheme + iPhone destination
```

After deploy: check the **build number on the watch home screen** (and iPhone Settings → About). If both match the value in `ios/project.yml`'s `CURRENT_PROJECT_VERSION`, you're on the latest build. Bumped on every code-change push by `scripts/bump-build.sh` (see AGENTS.md).

### Deploying only the watch app

When the iOS code didn't change but the watch did, skip the full iOS install:

1. Toolbar scheme dropdown → switch from **AARC** to **AARCWatch**
2. Destination dropdown → your Apple Watch by name
3. ⌘R — Xcode pushes the watch bundle through the iPhone

Switch back to the **AARC** scheme afterwards.

### When to clean or delete

You almost never need to. Day-to-day, incremental builds + reinstalls are correct. Reach for these only when something visibly broken:

- **⌘⇧K (Clean Build Folder)** — signature seal mismatches, "module not found" after a refactor, Xcode insists nothing has changed
- **Delete app from iPhone** — capabilities or entitlements changed and provisioning needs to re-bind
- **Force-quit watch app** (swipe away in recents) — when you suspect watchOS is keeping an older instance warm and you want to be sure the next launch loads the freshly-deployed bundle
- **`rm -rf ~/Library/Developer/Xcode/DerivedData/AARC-*`** — last-resort nuke when ⌘⇧K isn't enough

---

## License

[Apache License 2.0](LICENSE).
