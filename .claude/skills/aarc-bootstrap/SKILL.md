---
name: aarc-bootstrap
description: Set up AARC from a fresh clone for a new runner. Checks what they need to bring (Apple devices and developer account, a Cloudflare Worker, an LLM key, ElevenLabs, Spotify, an agent for Home Base), deploys their own Worker, points the app at it, interviews them to write their own Ricky and second-voice persona files, and wires up Home Base talk-back. Use when someone new asks how to start with AARC, how to make the voices their own, or how to set up Home Base.
---

# AARC bootstrap

You are helping someone who just cloned AARC get to their first coached run,
with voices that are theirs. Work through the steps in order, one question at a
time, and do the work yourself where you can. Any coding agent can follow this
file (Claude Code loads it as a skill; others can just read it).

## 0. Say what AARC is (short)

AARC is an iOS and watchOS running app with AI voices in your ear. The Apple
Watch tracks the run (HealthKit); the iPhone decides what to say and when;
a Cloudflare Worker you deploy holds the API keys and talks to the LLM and to
ElevenLabs. There are three voices:

- **Ricky**, the lead coach: a scripted backbone for the run plus live
  reactions to pace, heart rate and the song playing.
- **The second voice** (id `jessica` in the code, any character you like):
  answers Ricky's lines, so the two play off each other.
- **Home Base**: an AI agent session (this one, or any agent that can run a
  shell) that watches the live run and answers when the runner talks back
  with Siri mid-run.

The persona prompts are not open source. The repo ships starter placeholders
(`proxy/src/lib/personalities.example.ts`, `jessicaDeck.example.ts`); step 4
replaces them with the runner's own.

## 1. Check what they have

Ask which of these they have, then say plainly what will and won't work.

| Need | Why | Without it |
|---|---|---|
| iPhone (iOS 18+) and Apple Watch (watchOS 10+) | the watch is the tracker | phone-only runs work, less accurate |
| Mac with Xcode, `brew install xcodegen` | build the apps | nothing works |
| Apple Developer Program membership | HealthKit, the watch app, Siri, Live Activity on device | free accounts can sideload for 7 days with fewer capabilities |
| Cloudflare account | the Worker, D1 (run logs), R2 (voice archive) | nothing works; the free plan is enough to start |
| Anthropic API key (or OpenRouter) | writes every line | no coaching |
| ElevenLabs API key | the real voices | Apple's built-in voice, much flatter |
| OpenAI key (Whisper) or Volcano Engine key | transcribes voice notes and Siri talk-back | talk-back by voice fails; the typed Home Base terminal still works |
| Spotify developer app | now-playing and lyrics for music jokes | music awareness is limited |
| An agent session (Claude Code, Grokbot, Muse, any agent with a shell) | Home Base | runs work fine, nobody answers talk-back |
| Optional: Sentry DSN, Amap key (places in China) | errors, China place names | skipped |

## 2. Deploy their own Worker

Never point a personal build at `api.aarun.club`: that is the maintainer's
server and bills the maintainer.

1. `cd proxy && npm install` (this also creates `src/lib/personalities.ts`
   and `jessicaDeck.ts` from the starters if they are missing).
2. `npx wrangler login`.
3. `npx wrangler d1 create aarc-runs` and put the new `database_id` in
   `wrangler.toml`; `npx wrangler r2 bucket create aarc-voices`.
4. In `wrangler.toml`, replace the three `aarun.club` routes with their own
   domain, or delete `routes` and use the `*.workers.dev` URL.
5. `npx wrangler d1 migrations apply aarc-runs --remote`.
6. Make three random tokens (`openssl rand -hex 32`, one each) and set the
   secrets with `npx wrangler secret put <NAME>`, typing values at the prompt.
   Never echo a key into the chat or a file in the repo.
   - `ANTHROPIC_API_KEY` (or `OPENROUTER_API_KEY`)
   - `ELEVENLABS_API_KEY`
   - `DEVICE_TOKEN`, `LIVE_DEVICE_TOKEN`, `LIVE_ADMIN_TOKEN` (the three tokens)
   - `OPENAI_API_KEY` or `VOLC_API_KEY` for transcription
   - optional `SENTRY_DSN`, `AMAP_KEY`
7. `npm run deploy`, then `curl <their-url>/ping`.

## 3. Point the app at it

- `ios/project.yml`: `bundleIdPrefix` and every `DEVELOPMENT_TEAM` to their own.
- `ios/AARC/Info.plist`: `AARCDeviceToken` = `DEVICE_TOKEN`,
  `AARCLiveDeviceToken` = `LIVE_DEVICE_TOKEN`. These ride in the app; if
  their fork is public, keep these tokens out of it (local change only).
- `ios/AARC/Services/EndpointManager.swift`: the `cf` endpoint URL to their
  Worker; remove the `us` gateway entry unless they run the Node port in
  `proxy/server/`.
- Spotify: create an app at developer.spotify.com, add the redirect URI the
  app uses (see `ios/AARC/Services/Spotify/`), put the Client ID in
  `SpotifyConfig.swift`, and add their Spotify account as a user (apps in
  development mode only allow listed users).
- `cd ios && xcodegen generate && open AARC.xcodeproj`, run the `AARC`
  scheme on their iPhone.

## 4. Interview them and write the voices

Ask these one at a time, in plain words. Offer an example answer each time.

**The runner** (goes into every prompt)
1. What should the voices call you?
2. How do you run: usual distances, pace, treadmill or outdoors, any race coming up?
3. Give me five things the coach can tease you about: job, habits, gear, the
   excuses you always make. These become the running jokes.
4. Anything off limits?

**Ricky** (`roast_coach`)
5. Keep Ricky, or describe your own lead coach: name, accent, attitude.
6. How rough: clean, mild swearing, or no limits?
7. A line you'd love to hear from it, and a line that would make you quit the app.

**The second voice** (`jessica`)
8. Who answers Ricky? A rival coach, a supportive friend, a sports
   commentator, a disappointed parent, anything. Name, accent, attitude.
9. How do the two get on: allies, rivals, a double act?

**Home Base**
10. How should Home Base sound when it answers: calm mission control, a mate
    on the phone, a race engineer?

**Voices**
11. Pick an ElevenLabs voice for each of the three (their own library or the
    shared one; play samples together). Set the ids:
    - Ricky: `RemoteTTS.voiceId` in `ios/AARC/Services/RemoteTTS.swift` and
      `VOICE_RICKY` in `proxy/src/routes/dashboardApp.ts`
    - second voice: `RemoteTTS.jessicaVoiceId` and `VOICE_JESSICA`
    - Home Base: `RemoteTTS.homeVoiceId`, `HOME_BASE_VOICE_ID` in
      `proxy/src/lib/homeBase.ts`, `HOME_VOICE_ID` in `proxy/src/routes/agent.ts`

Then write `proxy/src/lib/personalities.ts` and `proxy/src/lib/jessicaDeck.ts`
starting from the `.example.ts` files:

- Keep every exported name and signature, and every OUTPUT FORMAT block word
  for word. The routes parse those shapes.
- Put their answers into `RUNNER`, `RICKY`, `SECOND_VOICE`. Make the teasing
  bullets concrete and specific; generic personas sound generic.
- If they gave a real name they want kept off recordings, set `REAL_NAME_RE`
  to match it.
- Rewrite the deck cards in `jessicaDeck.ts` for the second voice's world:
  30 or more cards across the dimensions, each a concrete, playable idea.
  Rename the dimensions if that fits the character better.
- These two files are gitignored. Never commit them, never paste them into
  an issue or PR.

Check: `cd proxy && npm run typecheck && npm run deploy`, then get a line
without running: `curl -s -X POST <their-url>/dynamic-line -H
'content-type: application/json' -d '<body>'` (the body shape is
`DynamicLineRequestSchema` in `proxy/src/schemas.ts`), or use the Voice
Playground in the app's Settings. Iterate on the prompts until they laugh.

## 5. Home Base and talk-back

1. In the app, Run screen: turn on **Share live running data back home**.
2. In the agent's shell:
   ```sh
   export AARC_API=https://<their-worker>
   export AARC_ADMIN_TOKEN=<LIVE_ADMIN_TOKEN>   # from their password manager, never into chat
   ```
3. Run `scripts/home-base/watch.sh` in the background. It exits and prints
   when the runner sends a message, a live run starts, or a run ends.
   Handle it, then start it again. Keep exactly one running.
4. Answer with `scripts/home-base/reply.sh "<text>"`: during a run it is
   spoken into their ear in the Home Base voice; off a run it lands in the
   app's Home Base terminal and is spoken on the phone. `--silent` writes
   text only.
5. Mid-run, the runner says **"Hey Siri, tell Home Base"** (or "tell AARC"),
   talks as long as they like, then **"Send to Home Base"** or a press on
   the earbud. The watch also shows a Send button while it listens. During a live run,
   `GET $AARC_API/live/status` with header `x-aarc-admin` shows pace, heart
   rate and recent events; check in every few minutes with something useful.
6. If the agent is silent for 40 seconds, the Worker answers on its own so the
   runner is never left hanging.

Give the agent a short standing brief for Home Base built from answer 10, and
the rules: answer the runner first, keep spoken replies short, never claim a
line was heard until the app acknowledges it.

## 6. First run

Settings has a desk simulator (Run screen: test mode, then "Simulate at my
desk"), so they can hear the whole run before going outside. Then a real one.
