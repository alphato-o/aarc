import SwiftUI
import AARCKit

/// In-run cockpit — full screen, dark, glanceable. Three vertical
/// sections:
///
///   A. PERFORMANCE COCKPIT — TIME + DIST hero numbers, 4 minor tiles
///      below (pace, HR, kcal, cadence).
///   B. LIVE CHART          — per-100m HR + pace bars, auto-scaling
///      from 1 km up to 50 km as the run extends. Frontier dot
///      pulses at the current distance.
///   C. MEDIA COMMAND       — album art + track + progress + transport.
///
/// Idle timer is disabled while this view is on screen — the runner
/// puts the phone on the treadmill console and stares at it. End-run
/// sits as a discreet text link at the very bottom.
struct ActiveRunView: View {
    @Environment(LiveMetricsConsumer.self) private var consumer
    @State private var nowPlaying = NowPlayingStore.shared
    @State private var chartStore = LiveRunChartStore.shared
    @State private var subtitleStore = LiveSubtitleStore.shared
    @State private var showEndConfirm = false

    var onDismiss: () -> Void = {}

    var body: some View {
        ZStack {
            // Background bleeds under the status bar; content respects
            // the safe area so the TIME / DIST hero numbers don't sit
            // under the Dynamic Island or the iOS clock.
            background.ignoresSafeArea()
            content
        }
        .preferredColorScheme(.dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            nowPlaying.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            nowPlaying.stop()
        }
        .alert("End this run?", isPresented: $showEndConfirm) {
            Button("End", role: .destructive) { endRun() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Ends tracking on the phone or sends End to the watch.")
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: subtitleStore.currentLine?.id)
    }

    // MARK: - Background

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.04, green: 0.04, blue: 0.08),
                Color(red: 0.10, green: 0.04, blue: 0.16),
                Color(red: 0.02, green: 0.02, blue: 0.05),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 10) {
            statusStrip
            cockpit
            liveChart
            bottomWidget
            endLink
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)  // breathing room under the iOS clock / Dynamic Island
    }

    /// Bottom slot — normally the music command (album art + track +
    /// transport). While the coach is speaking (and for the few-second
    /// dwell window after), the slot transforms into the subtitle bar
    /// so the runner can see the line and react with the heart button.
    ///
    /// Fixed height so the chart above never reshuffles on swap. Both
    /// subviews fill the same 180pt-high frame; only the content
    /// inside the rounded card changes.
    private var bottomWidget: some View {
        ZStack {
            if let line = subtitleStore.currentLine {
                LiveSubtitleBar(line: line) {
                    subtitleStore.toggleLike()
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                    removal: .opacity
                ))
                .id(line.id)
            } else {
                mediaCommand
                    .transition(.opacity)
            }
        }
        .frame(height: 180)
    }

    /// Slim status indicator strip. No interactive controls here — they
    /// either lived in iOS chrome territory (clock / Dynamic Island) or
    /// the user didn't need them in-run. Mute now lives in Settings;
    /// End sits discreetly at the bottom of the screen.
    @ViewBuilder
    private var statusStrip: some View {
        HStack(spacing: 8) {
            if let metrics = consumer.latest, metrics.state == .paused {
                Text("PAUSED")
                    .font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.yellow.opacity(0.25), in: Capsule())
                    .foregroundStyle(.yellow)
            }
            if consumer.isWatchStale {
                Label("Watch reconnecting", systemImage: "applewatch.slash")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 8)
        .padding(.bottom, 4)
    }

    // MARK: - A. Performance cockpit
    //
    // Top: TIME and DISTANCE side by side, both heavy mono digits with
    // a soft pink+blue glow — the two numbers the runner glances at
    // most often. Bottom: a single row of 4 minor tiles (PACE, HR,
    // KCAL, CADENCE), smaller font, accent stroke per metric.

    private var cockpit: some View {
        let metrics = consumer.latest
        return VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                heroNumber(
                    label: "TIME",
                    value: formatElapsed(metrics?.elapsed ?? 0),
                    glow: Color(red: 1, green: 0.3, blue: 0.7)
                )
                heroNumber(
                    label: "DIST",
                    value: formatDistanceHero(metrics?.distanceMeters),
                    glow: Color(red: 0.3, green: 0.6, blue: 1)
                )
            }

            HStack(spacing: 10) {
                cockpitTile(label: "PACE", value: formatPace(metrics?.currentPaceSecPerKm), accent: .cyan)
                cockpitTile(label: "HR", value: formatHR(metrics?.currentHeartRate), accent: .red)
                cockpitTile(label: "KCAL", value: formatKcal(metrics?.energyKcal), accent: .orange)
                cockpitTile(label: "SPM", value: formatCadence(metrics?.cadenceStepsPerMinute), accent: .mint)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private func heroNumber(label: String, value: String, glow: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
                .tracking(1.6)
            Text(value)
                .font(.system(size: 52, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .shadow(color: glow.opacity(0.55), radius: 14)
                .minimumScaleFactor(0.55)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func cockpitTile(label: String, value: String, accent: Color) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(accent.opacity(0.85))
                .tracking(1.4)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(accent.opacity(0.25), lineWidth: 1)
        )
    }

    /// Distance text optimized for the hero slot — short ("3.42" or
    /// "850m") so it doesn't get crushed against the time number.
    private func formatDistanceHero(_ meters: Double?) -> String {
        guard let m = meters else { return "—" }
        if m >= 1000 {
            return String(format: "%.2f", m / 1000)
        }
        return String(format: "%.0fm", m)
    }

    private func formatCadence(_ spm: Double?) -> String {
        guard let s = spm, s.isFinite, s > 0 else { return "—" }
        return "\(Int(s.rounded()))"
    }

    // MARK: - B. Kinetic visualizer

    /// Live chart: HR + pace bars, one per 100m bucket, growing
    /// left-to-right as the run extends. X-axis auto-scales from
    /// 1 km up to 50 km. Y-axis is hidden — the legend chips at the
    /// top of the chart spell out current HR and pace ranges.
    private var liveChart: some View {
        LiveRunChart(
            samples: chartStore.samples,
            liveDistanceMeters: consumer.latest?.distanceMeters ?? 0,
            liveHeartRateBPM: consumer.latest?.currentHeartRate
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - C. Media command

    private var mediaCommand: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                albumThumb
                VStack(alignment: .leading, spacing: 2) {
                    Text(nowPlaying.track?.title ?? "Nothing playing")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(nowPlaying.track?.artist ?? "Open Spotify to control playback")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }

            progressBar
            Spacer(minLength: 0)
            controls

            if let err = nowPlaying.lastControlError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var albumThumb: some View {
        if let img = nowPlaying.coverArt {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(.white.opacity(0.08))
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.4))
                )
        }
    }

    private var progressBar: some View {
        let progress = trackProgress
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.10))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.35, blue: 0.72),
                                Color(red: 0.30, green: 1.0, blue: 0.85),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, geo.size.width * progress))
            }
        }
        .frame(height: 4)
    }

    private var controls: some View {
        HStack(spacing: 28) {
            Button {
                Task { await nowPlaying.previous() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 56, height: 56)
            }

            Button {
                Task { await nowPlaying.togglePlayPause() }
            } label: {
                Image(systemName: nowPlaying.track?.isPlaying == true
                      ? "pause.fill"
                      : "play.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 72, height: 72)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.55, blue: 0.85),
                                Color(red: 0.45, green: 1.0, blue: 0.85),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: Circle()
                    )
                    .shadow(color: Color(red: 1, green: 0.4, blue: 0.7).opacity(0.45), radius: 16)
            }
            .disabled(nowPlaying.track == nil)

            Button {
                Task { await nowPlaying.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 56, height: 56)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Discreet end link

    private var endLink: some View {
        Button {
            showEndConfirm = true
        } label: {
            Text("End run")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var trackProgress: Double {
        guard let t = nowPlaying.track,
              let p = t.progressMs,
              let d = t.durationMs,
              d > 0 else { return 0 }
        return min(1, Double(p) / Double(d))
    }

    // MARK: - End run

    private func endRun() {
        // Kill the entire voice pipeline IMMEDIATELY so nothing
        // queued, in-flight, or pre-fetched can start playing during
        // the few seconds between tapping End and the watch's
        // workoutEnded actually arriving.
        //
        // Order matters:
        //   1. ContextualCoach.stop() — cancels in-flight /dynamic-line
        //      and /music-comment requests (their callbacks would have
        //      injected lines into the queue otherwise).
        //   2. ScriptEngine.stop() — flips isActive=false so any race
        //      with a still-running task can't inject after the cancel.
        //      Also calls VoiceFeedbackQueue.stopAll() internally to
        //      clear the queue and stop the active backend.
        //   3. NowPlayingStore.stop() — done in onDisappear, no Spotify
        //      polling traffic after dismiss.
        ContextualCoach.shared.stop()
        ScriptEngine.shared.stop()
        VoiceFeedbackQueue.shared.stopAll()

        // Phone-only run: tell PhoneWorkoutSession to end.
        Task { @MainActor in
            await PhoneWorkoutSession.shared.end()
        }
        // Watch-driven run: send a state event so the watch can end its
        // HKWorkoutSession. (Watch is still the authority — it will
        // confirm via workoutEnded coming back.)
        PhoneSession.shared.sendStateEvent(.endWorkout)
        onDismiss()
    }

    // MARK: - Formatting

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    private func formatDistance(_ meters: Double?) -> String {
        guard let m = meters else { return "—" }
        return m >= 1000
            ? String(format: "%.2f km", m / 1000)
            : String(format: "%.0f m", m)
    }

    private func formatPace(_ secPerKm: Double?) -> String {
        guard let s = secPerKm, s.isFinite, s > 0 else { return "—" }
        let m = Int(s) / 60
        let r = Int(s) % 60
        return String(format: "%d:%02d", m, r)
    }

    private func formatHR(_ bpm: Double?) -> String {
        guard let bpm, bpm > 0 else { return "—" }
        return "\(Int(bpm))"
    }

    private func formatKcal(_ kcal: Double?) -> String {
        guard let k = kcal, k.isFinite else { return "—" }
        return "\(Int(k))"
    }
}

#Preview {
    ActiveRunView()
        .environment(LiveMetricsConsumer.shared)
}
