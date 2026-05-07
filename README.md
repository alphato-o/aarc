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

The Xcode project and proxy code do not exist yet — they are created in [Phase 0](docs/phases/phase-0-foundation.md).

Once Phase 0 lands, this section will document:
- Xcode project setup
- Building & running on simulator / device
- Running the proxy locally (`wrangler dev`)
- Running tests

---

## License

[Apache License 2.0](LICENSE).
