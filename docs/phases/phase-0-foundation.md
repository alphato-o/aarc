# Phase 0 — Foundation

**Goal:** A buildable, signable iOS + watchOS app pair with the right capabilities, permissions, and a tiny proxy stub. No real running features yet.

**Outcome:** App launches on the founder's iPhone with a paired Apple Watch. Both apps request the right permissions. Three blank tabs on iPhone (Run, History, Settings); a one-screen "Hello" on the watch. A "Ping proxy" button returns "pong" from the Cloudflare Worker.

**Estimated effort:** **2–3 hours.**

**Dependencies:** None.

---

## Workstreams

### 0.1 — Repo & Xcode project

| # | Task | Acceptance |
|---|---|---|
| 0.1.1 | `git init` + Swift `.gitignore` at `/Users/alphatang/Dev/ccplayground/aarc` | clean status |
| 0.1.2 | Xcode project: SwiftUI App, iOS 17, organisation identifier `club.aarun` (from domain `aarun.club`), name `AARC`. Resulting bundle IDs: `club.aarun.AARC` (iOS), `club.aarun.AARC.watchkitapp` (watch) | builds for simulator + device |
| 0.1.3 | **Add watchOS app target** (paired with the iOS app, not standalone-only) | builds for watch simulator + Apple Watch |
| 0.1.4 | Add a shared Swift Package `AARCKit` (in-repo, local) for cross-target shared types | both targets depend on it |
| 0.1.5 | SwiftLint via SwiftPM, basic `.swiftlint.yml` | lint clean |
| 0.1.6 | Brief `README.md` with build instructions | founder can build |

### 0.2 — App skeletons

| # | Task | Acceptance |
|---|---|---|
| 0.2.1 | iOS: `AARCApp.swift` + `RootTabView` with three placeholder tabs | tab bar works |
| 0.2.2 | watchOS: `AARCWatchApp.swift` + a single `WatchRootView` placeholder | launches on watch |
| 0.2.3 | App icon + launch screen (placeholders) for both targets | icons appear |
| 0.2.4 | Dark mode default, accent colour set | visible |

### 0.3 — Capabilities & permissions

| # | Task | Acceptance |
|---|---|---|
| 0.3.1 | HealthKit capability on both targets | builds without entitlement errors |
| 0.3.2 | Background mode `audio` on iOS (TTS while locked) | visible in capabilities |
| 0.3.3 | Background mode `workout-processing` on watch (HKWorkoutSession needs it implicitly) | visible |
| 0.3.4 | iOS Info.plist: `NSHealthShareUsageDescription`, `NSHealthUpdateUsageDescription` (used to write `metadata` and resolve route reads), `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription` | strings render |
| 0.3.5 | Watch Info.plist: `NSHealthShareUsageDescription`, `NSHealthUpdateUsageDescription`, `NSMotionUsageDescription`, `NSLocationWhenInUseUsageDescription` (used by HK workout config) | strings render |
| 0.3.6 | iOS `PermissionsView` accessible from Settings: HealthKit, Mic, Speech statuses + request buttons | each status reflects reality after request |
| 0.3.7 | Watch onboarding screen on first launch: "Allow Health" CTA | request flow works |

### 0.4 — Cloudflare Worker proxy at `api.aarun.club`

| # | Task | Acceptance |
|---|---|---|
| 0.4.1 | Create `aarc-proxy/` folder (separate from app) with `wrangler.toml` + `src/index.ts` | `wrangler dev` runs |
| 0.4.2 | `GET /ping` → `{ ok: true, ts }` | curl works |
| 0.4.3 | Move `aarun.club` DNS to Cloudflare nameservers (zone added to the Cloudflare account) | zone is "Active" in dashboard |
| 0.4.4 | Add Worker Custom Domain `api.aarun.club` bound to the deployed Worker; cert auto-provisions | `curl https://api.aarun.club/ping` returns `{ok:true,...}` |
| 0.4.5 | Reserve `app.aarun.club` (CNAMEd to a placeholder Pages site or just a 200 OK Worker route) for future Universal Links | resolves with 200 |
| 0.4.6 | iOS bundle config (`Config.swift`) hard-codes `https://api.aarun.club` as the API base; debug builds may override via env | unit test passes |
| 0.4.7 | iOS `ProxyClient.swift`: `func ping() async throws -> PingResponse` | unit test passes |
| 0.4.8 | "Ping proxy" debug button in iOS Settings | tap → "pong" |

### 0.5 — Foundational types in `AARCKit`

| # | Task | Acceptance |
|---|---|---|
| 0.5.1 | `LiveMetrics`, `WorkoutState`, `RunMode`, `Personality` enums + structs | both targets compile |
| 0.5.2 | `WCMessage` enum covering watch↔phone protocol shapes per architecture doc | compiles |
| 0.5.3 | SwiftData stack on iOS with `Run`, `Script`, `ScriptMessage`, `VoiceNote`, `AiReply`, `UserMemory` empty models | iOS app boots |

### 0.6 — WatchConnectivity scaffold

| # | Task | Acceptance |
|---|---|---|
| 0.6.1 | iOS-side `PhoneSession` actor activating `WCSession` on launch | session active state visible in Settings debug panel |
| 0.6.2 | watchOS-side `WatchSession` actor activating `WCSession` on launch | active |
| 0.6.3 | Smoke-test: a "Send hello" debug button on iOS sends a `WCMessage.hello` to watch; watch displays it | round-trip works on real devices |

### 0.7 — TestFlight

| # | Task | Acceptance |
|---|---|---|
| 0.7.1 | App Store Connect record exists | — |
| 0.7.2 | First TestFlight build (iOS + watchOS) uploaded | founder installs both |

---

## Out of scope

- Any real workout / tracking.
- Any LLM call beyond the ping.
- Audio.
- Real run history UI.

## Risks specific to this phase

- Apple Developer signing, especially for the watch target. Buffer for "why won't this device build".
- WatchConnectivity reliability on simulator is poor. Smoke-test on real devices.

## Demo

1. Open Xcode, ⌘R for iOS, ⌘R for watch.
2. Both apps install.
3. Tap "Allow Health" on watch onboarding.
4. Open Settings on iOS, run permission check, tap each request.
5. Tap "Ping proxy" → "pong".
6. Tap "Send hello to watch" → watch shows the message.
7. TestFlight invite delivers the build to a second device.
