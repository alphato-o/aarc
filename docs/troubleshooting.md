# Troubleshooting

Field notes for the founder when things break in the gym or on a run.

---

## "Watch app won't talk to phone, and the iPhone Watch app's Install button hangs"

You've gone to the gym. You deployed a fresh iPhone build from Xcode at home but **didn't redeploy AARCWatch**. The watch is running an older build. You hit Start on the phone; the watch never receives it. You try to fix it on the spot by long-pressing the watch app → ✗ → "Reinstall" in the iPhone's Watch app. It spins forever, then errors.

This is a **known dead-end** with dev builds. There is **no public iOS API** that lets you install a development-signed watch app without Xcode — Apple deliberately blocks it. The Install button in the iPhone's Watch app is the same auto-install handoff that just failed; retrying does nothing.

### What to do **at the gym**

Tap the tracking source picker to **Phone only**. As of build 53 you can start either Treadmill or Outdoor runs entirely from the phone — distance comes from `CMPedometer` on a treadmill, GPS outdoors. You'll lose HR, but you have a working run.

The home screen also surfaces a yellow "Watch app not reachable" banner when the watch isn't responding, with a one-tap shortcut to flip to Phone only.

### What to do **before the next gym session**

**Both** of these:

1. **Deploy both targets from Xcode before leaving the house.** The `AARC` scheme already builds both `AARC.app` and `AARCWatch.app`, but the watch only receives the install over Bluetooth/iCloud — which can take a few minutes after Xcode says it's done. Confirm with the build-number badge on the watch home screen matches `CURRENT_PROJECT_VERSION` in `ios/project.yml`.
2. **Open the watch app at least once after deploying.** First-launch settles the WatchConnectivity activation; without it the phone's `WCSession.isReachable` may stay false even though the install succeeded.

### The actual long-term fix: **TestFlight**

Once AARC is on TestFlight, the watch app installs via Apple's normal over-the-air auto-install path — exactly what the App Store does for the apps you already use. No Xcode, no laptop, no dev-profile drama. Even when you forget to redeploy before the gym, the latest TestFlight build is already on both devices.

#### One-time TestFlight setup

(You do this once, then every future "deploy" is `Product → Archive → Distribute → App Store Connect`.)

1. **App Store Connect — create the listing.** Sign in at appstoreconnect.apple.com → My Apps → "+" → New App. Platform: iOS. Bundle ID: `club.aarun.AARC`. SKU: anything (e.g. `aarc-app`). Primary language: English.
2. **Apple Developer Portal — distribution provisioning.** Identifiers → make sure `club.aarun.AARC`, `club.aarun.AARC.watchkitapp`, `club.aarun.AARC.LiveActivity`, and the `group.club.aarun.AARC` App Group all exist (they should by now). Xcode auto-signing will mint the distribution profile when you archive.
3. **Xcode — archive + upload.**
   - Open `AARC.xcodeproj`.
   - Scheme: `AARC`. Destination: `Any iOS Device`.
   - `Product → Archive` (takes a couple of minutes).
   - In the Organizer window that opens: `Distribute App → App Store Connect → Upload`.
   - Xcode bundles AARC.app + AARCWatch.app + AARCLiveActivity together and uploads to App Store Connect.
4. **App Store Connect — internal testing.** TestFlight → Internal Testing → add yourself (or anyone you want) as an Internal Tester. ~10 minutes of processing later, your build appears. Accept the TestFlight invite on your phone; TestFlight app installs both AARC.app and AARCWatch.app via the normal over-the-air path.

After this is set up, the workflow becomes:

```
cd ios && xcodegen generate
open AARC.xcodeproj
# Edit / code as usual
Product → Archive → Distribute → Upload
# wait ~10 min, then both devices get the build via TestFlight
```

You can still ⌘R from Xcode for rapid iteration on the iPhone — but the watch picks up new builds via TestFlight without you having to plug anything in.

---

## "I hear Apple's voice after I tap End on the watch"

Resolved in commit `0c4f503` (build 47). The cancellation race in `RemoteTTS.play` is now caught — falling back to LocalTTS is skipped when `Task.isCancelled`. If you see this again, file it.

## "Voice feedback subtitle appears before audio starts"

Resolved in commit `62cca52` (build 48). The subtitle now fires on the `onAudioStart` callback, not at enqueue time.

## "Widget shows 'No runs yet' even though History has runs"

Resolved in commit `9e36db8` (build 51) — `LastRunSnapshotStore.backfillFromHistory()` runs on app launch. If the widget still shows empty after a re-launch, check that the App Group is registered in Developer Portal:

```sh
log stream --predicate 'subsystem == "club.aarun.AARC" AND category == "WidgetSnapshot"'
```

A line saying "container URL is nil" means the entitlement hasn't been provisioned. See the previous widget commit message for the steps.
