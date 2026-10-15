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
- Camera: fresh battery, card formatted, Video mode, chest mount tight,
  Bluetooth on (Settings, Wireless connection). Pairing already done at home.
- Powerbeats charged and connected before the corral.
- In the corral: start the run, confirm "Camera recording" is heard, confirm
  the watch shows IN CORRAL.
- On the mat: tap CROSSED THE GATE.
