import SwiftUI
import AARCKit

/// In-run cockpit — full screen, dark, glanceable. Three vertical
/// sections:
///
///   A. PERFORMANCE COCKPIT  — large mm:ss elapsed + 4-tile grid
///      (distance, pace, HR, kcal).
///   B. KINETIC VISUALIZER   — neon bars + pulsing heart, modulated by
///      heart rate (always) and music BPM (when Spotify gives it).
///   C. MEDIA COMMAND        — album art + track + progress + play /
///      pause / next / prev controls.
///
/// Idle timer is disabled while this view is on screen — the runner
/// puts the phone on the treadmill console and stares at it. Mute
/// toggle and End-run are tucked into a compact top bar.
struct ActiveRunView: View {
    @Environment(LiveMetricsConsumer.self) private var consumer
    @State private var nowPlaying = NowPlayingStore.shared
    @State private var showEndConfirm = false

    var onDismiss: () -> Void = {}

    var body: some View {
        ZStack {
            background
            content
        }
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
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
        VStack(spacing: 0) {
            statusStrip
            cockpit
            visualizer
            mediaCommand
            endLink
        }
        .padding(.horizontal, 20)
        .safeAreaPadding(.vertical)
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

    private var cockpit: some View {
        let metrics = consumer.latest
        return VStack(spacing: 16) {
            Text(formatElapsed(metrics?.elapsed ?? 0))
                .font(.system(size: 76, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .shadow(color: Color(red: 1, green: 0.3, blue: 0.7).opacity(0.55), radius: 18)
                .shadow(color: Color(red: 0.3, green: 0.6, blue: 1).opacity(0.35), radius: 30)
                .minimumScaleFactor(0.7)
                .lineLimit(1)

            HStack(spacing: 12) {
                cockpitTile(label: "DIST", value: formatDistance(metrics?.distanceMeters), accent: .pink)
                cockpitTile(label: "PACE", value: formatPace(metrics?.currentPaceSecPerKm), accent: .cyan)
                cockpitTile(label: "HR", value: formatHR(metrics?.currentHeartRate), accent: .red)
                cockpitTile(label: "KCAL", value: formatKcal(metrics?.energyKcal), accent: .orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func cockpitTile(label: String, value: String, accent: Color) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(accent.opacity(0.85))
                .tracking(1.4)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(accent.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - B. Kinetic visualizer

    private var visualizer: some View {
        KineticVisualizer(
            heartRateBPM: consumer.latest?.currentHeartRate,
            musicBPM: nowPlaying.tempoBPM
        )
        .frame(maxWidth: .infinity)
        .frame(minHeight: 140, idealHeight: 200)
        .padding(.vertical, 4)
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
            controls

            if let err = nowPlaying.lastControlError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        )
        .padding(.top, 8)
        .padding(.bottom, 6)
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
