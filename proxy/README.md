# proxy/

Cloudflare Worker that fronts Anthropic (and later ElevenLabs). Deployed at `https://api.aarun.club`.

This directory is empty until [Phase 0 — Foundation](../docs/phases/phase-0-foundation.md) scaffolds the Worker (task 0.4 onwards).

Expected layout once scaffolded:

```
proxy/
├── package.json
├── tsconfig.json
├── wrangler.toml                ← bound to api.aarun.club custom domain
├── src/
│   ├── index.ts                 ← router
│   ├── routes/
│   │   ├── ping.ts
│   │   ├── generateScript.ts    ← Phase 1
│   │   ├── chatReply.ts         ← Phase 2
│   │   ├── postRunSummary.ts    ← Phase 2
│   │   └── tts.ts               ← Phase 4
│   ├── lib/
│   │   ├── anthropic.ts
│   │   ├── personalities.ts     ← server-side personality system prompts
│   │   └── appAttest.ts         ← Phase 4
│   └── schemas.ts               ← request/response shapes shared with iOS
└── test/
```

## Secrets

All secrets live in Cloudflare via `wrangler secret put <NAME>`. Never commit them.

| Name | Used by | Phase |
|---|---|---|
| `ANTHROPIC_API_KEY` | `lib/anthropic.ts` | 1 |
| `ELEVENLABS_API_KEY` | `routes/tts.ts` | 4 |
| `APPLE_TEAM_ID` | `lib/appAttest.ts` | 4 |

## Local development

```sh
cd proxy
npm install
npx wrangler dev
# → local http://localhost:8787, used by ios/ debug builds when overridden
```

Production deploys via `npx wrangler deploy`.
