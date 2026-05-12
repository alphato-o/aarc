# AGENTS.md

Briefing for AI coding agents (Claude Code, Codex, Cursor, etc.) working in this repo.

If you are an agent: **read this top-to-bottom before making changes.**

---

## What this project is

AARC is a native iOS + watchOS running app with an AI voice companion. The product brief, vision, and phasing live in [`PLAN.md`](PLAN.md). Architecture, data model, decisions, and risks are in [`docs/`](docs/).

Always read [`PLAN.md`](PLAN.md), [`docs/architecture.md`](docs/architecture.md), and the **active phase doc** in [`docs/phases/`](docs/phases/) before touching code.

---

## Repo layout

```
.
├── README.md
├── AGENTS.md          ← this file
├── PLAN.md            ← master plan + phase index
├── docs/              ← planning, design, decisions, risks
│   └── phases/        ← phase-by-phase implementation plans
├── ios/               ← Xcode workspace (iOS app + watchOS app + AARCKit + tests)
└── proxy/             ← Cloudflare Worker (TypeScript)
```

iOS tests live inside the Xcode project's `*Tests` and `*UITests` targets — do not create a top-level `tests/` folder.

---

## Non-negotiable architectural rules

These exist because they shed enormous risk and complexity. Follow them; if you think they should change, raise it in `docs/decisions.md` first.

1. **Apple Watch is the only tracker.** No `CLLocationManager` / GPS / distance / pace / split / auto-pause code on the phone, ever. The watch hosts `HKWorkoutSession` + `HKLiveWorkoutBuilder` and publishes a 1Hz `LiveMetrics` snapshot to the phone over WatchConnectivity. The phone consumes; it does not compute.
2. **HealthKit is the system of record for workouts.** Routes, HR samples, distance, energy — all live in HealthKit, written by the watch. Our SwiftData store holds only companion data (scripts, voice notes, AI replies, user memory, race setups). Never duplicate workout truth into our DB beyond denormalised cache fields.
3. **No API keys in the iOS app.** Anthropic / ElevenLabs / anything else lives behind the Worker at `api.aarun.club`.
4. **Local-first for the run itself.** A run must continue and be useful with the network gone. Cloud calls enhance; they do not gate. Race mode (Phase 3) is fully offline.
5. **The companion serves the run.** Audio respects music ducking via `AVAudioSession`. The companion never interrupts mid-utterance unless the cue is critical (race-day fueling/hydration). "Mute companion" must be one tap away during an active run.
6. **Voicemail-style voice interaction only.** No real-time bidirectional voice chat in V1.

---

## Conventions

### Swift / iOS

- SwiftUI + `@Observable` (Observation framework, iOS 17+) for view models. No `ObservableObject` / Combine plumbing unless strictly necessary.
- Actors for anything with mutable state crossing async boundaries (`AudioPlaybackManager`, `AIClient`, `WorkoutSessionHost`, `LiveMetricsConsumer`).
- One writer per concern. Avoid shared mutable state outside actors.
- Use `async/await`, not callbacks or Combine, for new code.
- Errors: `throws` + typed errors. No silent failures. UI surfaces failures with real messages (not debug alerts).
- File organisation: one type per file; group by feature, not by kind. (`RunSession/RunSessionEngine.swift`, not `Models/RunSession.swift`.)
- Do not write comments that restate the code. Only comment non-obvious *why*.

### TypeScript / Worker

- One file per route handler. Keep `src/index.ts` as a router.
- All env (`ANTHROPIC_API_KEY`, etc.) via `wrangler secret`. Never check secrets into the repo.
- Validate every request body with a small schema (zod or hand-rolled). Reject with 400 on bad shape.

### Commits

- **Conventional Commits** style: `feat(scope): ...`, `fix(scope): ...`, `chore(scope): ...`, `docs(scope): ...`, `refactor(scope): ...`. Scope examples: `ios`, `watch`, `aarckit`, `proxy`, `docs`.
- Subject ≤ 72 chars. Body wraps at 100. Explain *why* in the body when not obvious from the diff.
- Commit often. A single phase produces many small commits; do not batch a whole phase into one mega-commit.
- Branch naming: `phase-N/<slug>` for phase work, `fix/<slug>` for bug fixes, `chore/<slug>` for housekeeping. Trunk-based — merge to `main` frequently. Solo project, so PRs are optional unless we want a review checkpoint.

### Build number

The watch's main UI and iPhone's Settings → About display `vX.Y.Z (S.HHMMSS)`:
- **`S`** = `CURRENT_PROJECT_VERSION` in `ios/project.yml`. Source-controlled. Bumps on every push of code changes.
- **`HHMMSS`** = the local time at which **this specific Xcode build** was compiled. Stamped automatically into the built `Info.plist` by a postBuildScript on each target. Different on every ⌘R.

Together they answer two questions the founder can ask by glancing at the watch:
- "Am I running the latest pushed build?" → does `S` match `git pull && grep CURRENT_PROJECT_VERSION ios/project.yml`?
- "Did this last ⌘R actually take?" → does `HHMMSS` match the time you just hit Run?

Bump `S` on every push that touches `ios/AARC*/` or `ios/AARCKit/`. Never on docs-only or proxy-only.

```sh
scripts/bump-build.sh   # increments S by 1, prints "build: N → N+1"
```

After running, `cd ios && xcodegen generate` so `project.pbxproj` picks up the new value. Stage `ios/project.yml`.

The `HHMMSS` suffix is automatic and requires no agent action — Xcode handles it on every ⌘R via the postBuildScript defined in `project.yml`.

### Testing

- iOS: unit tests for `ScriptEngine`, `AIClient`, `MemoryStore`, `BranchSelector`, anything with branchable logic. UI tests for the start-run flow once Phase 1 lands.
- Worker: integration tests via `wrangler dev` + a small test harness. Validate response shape against the same schema the iOS client uses.
- Coverage is not a target. "Did you test the thing you actually changed" is the bar.

---

## Workflow

1. Read `PLAN.md` and the active phase doc.
2. Pick the next task off the phase's task list (table format: every doc has them).
3. Implement on a branch.
4. Commit small, push to GitHub.
5. Update the task's status in the phase doc when it lands. (Strikethrough or check-emoji prefixes are fine — keep the table readable.)
6. When a phase's "Definition of done" is satisfied, tag a release: `git tag phase-N` and push tags.

If you find a task is wrong, missing, or out of order: **edit the phase doc**. The plans are living documents, not historical record.

---

## What NOT to do

- Don't create a top-level `tests/` directory.
- Don't write phone-side GPS / distance / pace code.
- Don't ship API keys in the app.
- Don't add real-time voice chat.
- Don't add a top-level `node_modules/` — the Worker has its own `proxy/node_modules/`.
- Don't write multi-paragraph code comments. One short line explaining *why*, max.
- Don't commit `.env`, `*.pem`, `secrets.json`, or anything matching `.env.*` (other than `.env.example`).
- Don't commit Xcode `xcuserdata/` or `DerivedData/` — `.gitignore` covers this; if it slips in, remove it in the same commit.

---

## Secrets

The repo is **public**. No secrets — API keys, tokens, client secrets, JWT
signing keys — ever land in source control. Where each lives:

| Secret                       | Lives in                                  | Set by                                                  |
| ---------------------------- | ----------------------------------------- | ------------------------------------------------------- |
| `OPENROUTER_API_KEY`         | Cloudflare Worker env                     | `npx wrangler secret put OPENROUTER_API_KEY`            |
| `ANTHROPIC_API_KEY` (alt)    | Cloudflare Worker env                     | `npx wrangler secret put ANTHROPIC_API_KEY`             |
| `ELEVENLABS_API_KEY`         | Cloudflare Worker env                     | `npx wrangler secret put ELEVENLABS_API_KEY`            |
| Spotify OAuth tokens         | iOS device Keychain (`club.aarun.AARC.spotify`) | Set automatically after Settings → Connect Spotify |
| Musixmatch API key           | iOS device `UserDefaults`                 | Settings → Lyric providers → Musixmatch API key         |

Spotify Client ID (`5c05af0532894aeb90d3318a667829ab`) lives in
`ios/AARC/Services/Spotify/SpotifyConfig.swift`. **Public** per the
OAuth/PKCE spec — Spotify designs Client IDs to be embedded in client
binaries, no quota or billing attached. Committed intentionally.

Operational notes:

- `wrangler secret list` shows what's set on the Worker; values are never
  printable.
- For local proxy dev with `wrangler dev`, copy `proxy/.dev.vars.example`
  to `proxy/.dev.vars` and fill in. `.dev.vars` is gitignored.
- Never paste a key into chat, a PR, an issue, or a commit body. If you
  do by accident, rotate immediately at the provider, then re-set via
  `wrangler secret put`.
- `.gitignore` blocks `.env`, `.env.*`, `*.key`, `secrets.json`,
  `proxy/.dev.vars`. Don't add file patterns that bypass this.
- iOS UserDefaults / Keychain values are per-device and never sync to
  the repo. The user re-enters them on each install.

## Domain & deployment targets

- App: bundle IDs `club.aarun.AARC` (iOS) and `club.aarun.AARC.watchkitapp` (watch). TestFlight from end of Phase 0.
- Proxy: deployed at `https://api.aarun.club`. Cloudflare Worker. Custom domain bound from Phase 0.
- Universal Links: `app.aarun.club` (reserved Phase 0, used Phase 3+).
- Marketing / privacy policy: `aarun.club` (Phase 4 prerequisite for App Store).

---

## When in doubt

Ask the founder. Don't guess on product direction; don't invent abstractions to "future-proof". Ship the smallest thing that satisfies the current phase's Definition of Done, then move on.
