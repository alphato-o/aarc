# Race day runbook: 25 October 2026

How AARC runs the marathon, what the Control Room watches, and what Alpha does
on the day. Written 16 Oct 2026 after the first Osmo link worked. Rehearse every
item on a training race before the day.

## The start: corral, then gate

Race mode has two settings. **Training race** starts the race clock with the
run, as every run does. **Actual race** starts the session in the corral and
holds the race clock until the gate.

1. In the corral, with the camera on and the Powerbeats in: open AARC, Race mode
   on, "Actual race", Start outdoor. The watch starts the workout at once
   (GPS warm, heart rate running) and shows **IN CORRAL** with a green
   **CROSSED THE GATE** button on its controls page. The phone shows
   "IN THE CORRAL" with the same button as a backup.
2. Nothing speaks on queue time. Ricky, Jessica, the script, the chart and the
   km markers all wait. The camera starts recording as soon as it is linked.
3. On the timing mat: tap **CROSSED THE GATE** on the wrist (one tap, a
   success haptic confirms). From that moment the run clock, distance, energy,
   splits and the kilometre readouts count from the gate. The phone logs
   `race.gate` and the camera director logs `camera.gate` with the second into
   the current clip where the race starts, for the video cut.
4. The watch keeps the whole session in Apple Health, queue included. The
   race is what AARC shows and what the share card uses.

A missed tap can be made later from the phone's green button. The offset is
then wherever you were, so tap on the mat.

If the watch app is relaunched mid-run the gate offset is restored from the
watch's own store; the phone re-keys itself to the run as before.

## The course: every voice knows where he is

The Tianjin Marathon route (start 友谊路 at 天津大礼堂, finish 宾水西道 at
天津奥林匹克中心) was traced with Amap through every turn, re-anchored to the
organiser's kilometre markers, and every kilometre looked up for its street,
district and landmarks. The aid-station table from the official map and
hand-written notes (the Astor Hotel at km 5, the 鄱阳路 turnaround at 12.5, the
Century Clock at 23, the Tianjin Eye on 永乐桥 at 27.5, the Drum Tower at 29,
the universities at 37, the Water Park at 39) sit on top. The data lives in
`proxy/src/data/courses/tianjin-2026.json`; `GET /course/tianjin2026` returns
it and `GET /course/tianjin2026/at?km=27` returns the prompt block for a point.

In **Actual race** mode the proxy adds a RACE COURSE block (where he is, what
is next, the next aid station, metres to the finish) to every voice: Ricky's
dynamic lines, Jessica's reactions, the music comments and the Home Base
kilometre readout. The course is the ground truth when the live GPS place
block is thin, which in the crowd it will be.

Jessica is broadcast-safe in both race modes: hints and swearing stay,
nothing explicit, no moaning or screaming. The race recording goes on
YouTube; bleeps in post are a feature.

## The story pack: every voice is a tour guide

`proxy/src/data/courses/tianjin-2026-stories.json` carries the city and 32
stories pinned to metres on the course: the Emperor's Ford, the nine
concessions, Eric Liddell's stadium at km 3.3, the last emperor's 静园 at km
4.1, the Astor at 5, the Dagu forts, the first railway at 15, the Century
Clock and the Bridge of All Nations at 23, 金汤桥 and 15 January 1949 at 25,
the Tianjin Eye at 27.5, the Mazu temple and the Drum Tower at 28 and 29,
Nankai and 北洋 at 37, Zhou Enlai at 38, the Water Drop at 41. Every fact
was checked; the jokes are the voices' own.

How it is dispensed in Actual race mode:
- The race pack script gets one Ricky line per story (38 to 48 messages),
  nudged off round kilometres so it never stacks on the kilometre call.
- Live, the course block in every voice carries STORY HERE for the current
  point; Ricky's and Jessica's prompts close with a tour-guide directive, and a
  line at a story point is never withheld by the race-mode rate limiter.
- Home Base tells the story in its own register and must change the shape of
  the readout every kilometre; stock closers are banned.
- Names: every Chinese place name spoken gets its English meaning right after
  it, first time, same breath (the recording has an English audience and the
  voices read Chinese aloud in Mandarin).

Another race: a new stories file next to the course JSON, attached in
`lib/course.ts`.

## The race pack: the first half hour has no signal

The crowd at the start kills the phone's data for about thirty minutes. The
pack is the answer: build it at home the night before, on Wi‑Fi.

1. Set the race plan first: 42.2 km, outdoor, Ricky. Then Settings,
   **Race pack (offline)**, **Build race pack**. It writes a race script with
   the course in it (the usual skeleton plus one-shot lines at real places,
   every kilometre from 1 to 8 covered one by one, placed mid-kilometre so they
   never stack on the kilometre call) and renders every line to audio: the
   script, the kilometre announcements and Home Base's own gate line. Expect a
   minute of generation and a few minutes of rendering; the section shows
   "N of M rendered". Rebuild if the plan or coach changes; the pack is used
   only for the exact plan it was built for.
2. At the start, in Actual race mode with a matching pack, the pack IS the
   script: no opener is generated at the start line and nothing swaps in
   later. The `race.pack` event on the live channel says so.
3. Online, Home Base still calls every kilometre and Jessica still reacts.
   When the readout cannot reach the proxy, Ricky's scripted kilometre line
   plays instead (`milestone.owner ricky:offline`). Nothing waits on the
   network; the local voice is the fallback for anything not yet rendered.
4. The gate press speaks a local Home Base line ("Gate. Race clock running.")
   with no proxy in the loop.

## The Control Room page: where he is, live

In **Actual race** mode the phone's live uplink is always on (no toggle) and
carries the full event data: a GPS fix every 20 m with speed and heart rate,
the metrics line, watch and phone battery every five minutes, the camera
events, the gate press and every spoken line. Batches that cannot be sent are
kept and resent in order, so the no-signal first half hour arrives in a burst
when the signal returns. The Worker stores a race run's events append-only
(`live_event`), so the whole race can be replayed; `GET /live/feed?since=`
returns them after a cursor.

`https://my.aarun.club/race` (dashboard login, or once with
`?key=<LIVE_ADMIN_TOKEN>` from the agent's own browser) draws the runner on
the course over relayed Amap tiles: a follow view at street level, an
overview of the whole course, the race clock from the gate, distance, pace,
average, heart rate, projected finish, next aid station, batteries, camera,
and a ticker of every line Ricky, Jessica and Home Base said. It polls every
8 s, retries on its own and shows LIVE / STALE / NO SIGNAL from the age of the
last event. No external dependencies.

For the race video the Control Room agent drives Phi Browser on the mini
(`phi-browser` skill, agent Space `aarc-race-control-room`) to show the page
next to its terminal; that screen is the B-roll, synced to the DJI A-roll by
the gate press, which is logged on both. Rehearse without a run with the
replay script (`scratchpad/tianjin/replay.py`, `SPEED=30`), which plays the
course through the live endpoints as a race run.

## Talk-back: he speaks, Control Room answers in his ear

Every mode, run or no run. A long press on the Powerbeats Pro is Siri (no app
can intercept the earbud button), so Siri is the trigger, but Siri does NOT
do the listening: its dictation decides on its own when he has stopped and
cut him off mid-sentence (founder, 17 Oct). Instead:

1. **"Hey Siri, tell Control Room"** (also "talk to / message Control Room",
   "Home Base listen"; `INAlternativeAppNames` in `Info.plist`) runs
   `TellControlRoomIntent`, an iOS 18 `AudioRecordingIntent` (opens the mic
   from the background) and `LiveActivityIntent` (starts the Live Activity
   from the background). The Live Activity MUST be up before the audio
   session: AppIntents traps the app otherwise (the 209 to 211 crashes). Siri says "Go."; a rising two-tone cue
   means the mic is open. A Live Activity ("Control Room, listening", timer)
   is required by iOS for the background recording and shows on the lock
   screen and Dynamic Island.
2. `ControlRoomRecorder` records 16 kHz AAC on the earbud mic with a
   non-mixable session, so the music pauses and the app owns Now Playing.
   Mic: the **Powerbeats mic** (Bluetooth HFP) by default, the only one close
   enough to his mouth in a race. HFP puts the earbuds in call mode, where
   the long-press no longer reaches Siri, so the send is spoken: **"over
   and out"** at the end of a line, caught by on-device speech recognition
   (`TalkbackCapture`, AVAudioEngine tap feeding both the m4a file and an
   `SFSpeechAudioBufferRecognitionRequest`, offline). The proxy strips the
   phrase from the transcript. Pauses are his; the backstops are Siri from
   the phone's side button (any interruption sends), 30 s of silence after
   speech, and the 5 minute cap. Each uninterrupted stretch is its own
   segment file, joined at send, so nothing is ever overwritten.
3. `ControlRoomChannel.sendRecording` uploads to `POST /agent/voice`
   (clientId, runId, km, elapsed, duration). The proxy stores the audio in R2
   under `talkback/`, transcribes with the voice-note chain (Volc, Whisper,
   Scribe, then the tidy pass) and puts the transcript on `agent_thread` as a
   voice row; idempotent on clientId. No signal: the audio stays on disk and
   resends from the in-run poll tick or at launch.
4. The agent sees it live in the Claude Code session through the ear loop
   (`private/ear-loop.sh` as a Monitor: `EAR VOICE #id ... [run xxxx at
   12.3 km] (recorded 48s): ...`) and answers with `private/reply.sh "<text>"`.
   In a run the answer comes through the run's inject poll, which now runs for
   every real run in every mode. Off-run the app keeps itself awake with the
   silent keepalive for three minutes and plays the answer when it lands.
   Both play in Kristen's voice. Spoken replies use pinyin plus English, never
   Chinese characters.

Verified on device 17 Oct (build 208, Siri dictation version): off-run spoken
reply. Pending on device (build 209): the recorder, the earbud press reaching
the app, music resuming after, and the in-run path.

## The camera: DJI Osmo Action 6 on the chest mount

Pair once at home, in Settings, "DJI Osmo camera": camera on, tap **Pair the
camera**, allow the code on the camera screen. The camera remembers AARC as a
remote from then on; a reconnect never asks again.

During any race-mode run (training or actual) the camera director:

- starts the recording with the session, switching the camera to video first
  if it is in another mode,
- restarts the recording if it stops by itself,
- reports in the Home Base voice: "Camera recording, battery 84 percent",
- watches the battery and says, at 30, 20, 10 and 5 percent, what to do,
- says "Camera offline" after ten seconds without the link, and "Camera back
  online at 97 percent, starting the recording" when it returns,
- warns when the camera is too hot to record or the card has under 15 minutes,
- stops the recording at run end and reports the clip length,
- feeds battery and recording state to every kilometre readout, so Home Base
  mentions the camera only when it needs attention.

Every camera line is on the timeline export like any other line.

### Batteries: three spares and a power bank for a five to six hour day

- One Osmo battery records roughly 90 minutes at 4K 30 fps in the cold; plan
  on 70 to 80 minutes to be safe. Four batteries cover the day with margin.
- Swap on the 20 percent call, at the next water station, not at 10. The
  camera takes about 15 seconds to boot; the link comes back by itself and the
  recording restarts without touching the camera.
- The power bank can feed the camera over USB-C while recording. Use it only
  if a swap is impractical; a dangling cable on a chest mount is a worse
  problem than a 15 second gap.
- Carry the spares warm (inner pocket). A cold lithium battery reads low and
  dies early.
- Put the camera in Video mode and the right preset at home. AARC can switch
  to Video but does not choose resolution or stabilisation.
- Format the card the night before; the card warning is a last line of
  defence, not a plan.

### What the Control Room does

The agent watches `/live/status` every minute and reads the `camera.*` events:
link state, battery every 5 points, recording changes, every spoken camera
line. A swap shows as `camera.link disconnected`, then `connected`, then
`camera.cmd start recording`. If the camera stays offline for more than a few
minutes, or a swap does not bring the recording back, the Control Room posts a
line through `/live/inject` in the Home Base voice saying exactly what to press.

## Checklist for the morning

- Watch and phone charged; AARC build is the one tested on the last training
  race; race mode set to **Actual race**; live share on.
- Race pack built the night before for the 42.2 km outdoor plan, Settings
  shows every line rendered and no "different plan" warning.
- Control Room page open in Phi on the mini and showing LIVE once the session
  starts in the corral; screen recording running on the mini.
- Camera: fresh battery, card formatted, Video mode, chest mount tight,
  Bluetooth on (Settings, Wireless connection). Pairing already done at home.
- Powerbeats charged and connected before the corral.
- In the corral: start the run, confirm "Camera recording" is heard, confirm
  the watch shows IN CORRAL.
- On the mat: tap CROSSED THE GATE.
