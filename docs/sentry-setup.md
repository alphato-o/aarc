# Sentry setup

Error reporting is wired but **inert by default** — no events leave the
device or the worker until you supply DSNs. No Sentry SDK is installed
anywhere; both sides speak the envelope protocol directly over
fetch/URLSession.

## 1. Create two Sentry projects

In the Sentry org, create:

| Project      | Platform setting | Receives                                  |
| ------------ | ---------------- | ----------------------------------------- |
| `aarc-proxy` | JavaScript       | Worker dispatch crashes, upstream 5xx     |
| `aarc-ios`   | Apple (Cocoa)    | Handled errors from the iPhone app        |

Each project gives you a DSN of the form
`https://KEY@oNNN.ingest.sentry.io/PROJECT_ID`.

## 2. Proxy DSN → Worker secret

```sh
cd proxy
wrangler secret put SENTRY_DSN
# paste the aarc-proxy DSN
```

That's the entire proxy setup. Until the secret exists,
`proxy/src/lib/sentry.ts` no-ops on every call. What gets reported once
it's set:

- **Unhandled exceptions** in route dispatch (`src/index.ts` wraps the
  router in try/catch → `captureException`, returns 500 JSON).
- **Upstream 5xx failures** from the LLM provider in
  `/generate-script`, `/dynamic-line`, `/react-line`, `/music-comment`
  (`captureMessage` with route + status + detail).

Reporting failures are swallowed and the ingest POST has a 3 s timeout,
so a Sentry outage can never affect request handling.

## 3. iOS DSN → Settings diagnostics field

The app reads the DSN from `UserDefaults` key **`aarc.sentry.dsn`**
(see `CrashReporter.dsnDefaultsKey`). Paste the `aarc-ios` DSN into the
Sentry DSN field in **Settings → Diagnostics**. Clear the field to turn
reporting back off — empty/missing means fully inert.

Events are tagged `release = CFBundleVersion` (build number via
`AppVersion.build`), `environment = dev`, `platform = cocoa`.

## 4. What this does NOT cover (yet)

`ios/AARC/Services/CrashReporter.swift` is a thin facade, **not** the
sentry-cocoa SDK. Until that dependency lands (separate decision):

- **Handled errors only.** `CrashReporter.capture(error:)` /
  `captureMessage(_:level:)` must be called at the catch site.
- **No crash handlers** — no signal/Mach exception capture, no
  unhandled-NSException reporting. A hard crash produces nothing.
- No breadcrumbs, no symbolicated stack traces, no session tracking.

Every capture also logs via os.Logger (`club.aarun.AARC` /
`CrashReporter`) and forwards into the in-app run event log when the
sink is wired, so the facade is useful even with no DSN configured.

## Verifying

- Proxy: temporarily break an upstream key (`wrangler secret put
  OPENROUTER_API_KEY` with junk), hit `/dynamic-line`, expect an event
  in `aarc-proxy` within seconds. Restore the key after.
- iOS: set the DSN in Settings, trigger any handled error path (e.g.
  airplane-mode a TTS fetch), check `aarc-ios`.
