import SwiftUI

/// Dual equalizer for the in-run UI: vertical bars on a horizontal
/// centerline, **top half is music**, **bottom half is body**.
///
/// IMPORTANT — what's real, what isn't:
///
/// iOS does NOT expose the system audio output buffer (e.g., the audio
/// Spotify is mixing into AirPods) to third-party apps. There's no API
/// you can build a true waveform-FFT equalizer against — it's a DRM /
/// privacy boundary Apple deliberately keeps closed. So a literally
/// audio-reactive music bar is technically impossible in this app
/// without taking over playback ourselves, which we don't want.
///
/// What we do here instead, on the music side:
///   • freeze the bars completely when Spotify reports `isPlaying=false`
///     — paused → motionless,
///   • drive the per-bar phase rate from the track's tempo (BPM via
///     Spotify /audio-features) so a 90-BPM ballad moves slower than a
///     140-BPM banger,
///   • scale the overall amplitude by the track's "energy" feature
///     (also from /audio-features) so a calm song is dim + short, a
///     loud song is tall + bright,
///   • give every bar an independent randomized phase offset and
///     frequency multiplier so it reads like an FFT bin layout rather
///     than a single sine wave.
///
/// On the body side this is genuinely data-driven:
///   • bars run at the runner's actual heart rate (sin(t * hr/60)),
///   • amplitude scales with HR magnitude (60 bpm → tiny + cool, 180
///     bpm → tall + hot, cyan → pink → red),
///   • if distance hasn't changed in the last 4 seconds (or the
///     workout is paused), the body bars freeze flat at zero — the
///     runner isn't running, the bars don't lie.
///
/// Top + bottom share the same X axis so each "EQ column" combines
/// music and body intensity — they meet (or don't) at the centerline.
struct KineticVisualizer: View {
    let heartRateBPM: Double?
    let paceSecPerKm: Double?
    let distanceMeters: Double
    let workoutState: WorkoutStateLike
    let musicBPM: Double?
    let musicEnergy: Double?
    let isMusicPlaying: Bool

    /// Erased state so the visualizer doesn't have to import AARCKit
    /// (which carries a watchOS-only ActivityKit dependency on macOS).
    enum WorkoutStateLike: Sendable {
        case running, paused, other
    }

    /// Number of equalizer "bins". Even-ish so the centerline lands
    /// between two columns rather than on top of one.
    private let barCount = 18

    /// Distance-change tracker for the "is the runner moving?" gate.
    /// Updated via .onChange; if distance hasn't ticked in stationary-
    /// Threshold seconds, the body bars are forced to zero.
    @State private var lastDistance: Double = 0
    @State private var lastMovedAt: Date = .now
    private let stationaryThreshold: TimeInterval = 4

    /// Per-bar random multipliers, generated once and reused for the
    /// life of the view. Stable random gives a distinctive EQ profile
    /// instead of "every bar looks the same".
    @State private var seeds: [BarSeed] = (0..<24).map { _ in BarSeed.random() }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let bodyActive = isBodyActive(at: timeline.date)
            let musicActive = isMusicPlaying && (musicBPM ?? 0) > 0
            content(time: now, bodyActive: bodyActive, musicActive: musicActive)
                .onChange(of: distanceMeters, initial: true) { _, newValue in
                    if abs(newValue - lastDistance) > 1 {
                        lastDistance = newValue
                        lastMovedAt = .now
                    }
                }
        }
        .overlay(alignment: .bottom) {
            statusCaption
                .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private func content(time: TimeInterval, bodyActive: Bool, musicActive: Bool) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let midY = h / 2

            let bodyTargetAmp = bodyActive ? hrAmplitude() : 0
            let musicTargetAmp = musicActive ? musicAmplitude() : 0

            Canvas { ctx, _ in
                let slotW = w / CGFloat(barCount)
                let barW = slotW * 0.45

                // Subtle baseline so the centerline reads as a line.
                let baseline = Path { p in
                    p.move(to: CGPoint(x: 0, y: midY))
                    p.addLine(to: CGPoint(x: w, y: midY))
                }
                ctx.stroke(baseline, with: .color(.white.opacity(0.10)), lineWidth: 0.75)

                for i in 0..<barCount {
                    let seed = seeds[i % seeds.count]
                    let x = CGFloat(i) * slotW + (slotW - barW) / 2

                    // ----- MUSIC half (top, growing upward) -----
                    let musicPhaseRate = (musicBPM ?? 0) / 60.0 * 2 * .pi
                    let musicWobble = (musicEnergy.map { 0.6 + 0.4 * $0 } ?? 0.85)
                    let musicSin = sin(time * musicPhaseRate * seed.musicMult + seed.musicPhase)
                    let musicMag = (musicSin * 0.5 + 0.5) * musicWobble
                    let musicH = CGFloat(musicMag) * musicTargetAmp * midY
                    if musicTargetAmp > 0.01 {
                        drawBar(
                            ctx: &ctx,
                            x: x, width: barW,
                            from: midY, to: midY - musicH,
                            colors: musicColors()
                        )
                    } else {
                        // Frozen pip so the column position is visible
                        // when paused — but not animated.
                        drawBar(
                            ctx: &ctx,
                            x: x, width: barW,
                            from: midY, to: midY - 3,
                            colors: [.white.opacity(0.10), .white.opacity(0.04)]
                        )
                    }

                    // ----- BODY half (bottom, growing downward) -----
                    let hrPhaseRate = ((heartRateBPM ?? 0) / 60.0) * 2 * .pi
                    let bodySin = sin(time * hrPhaseRate * seed.bodyMult + seed.bodyPhase)
                    let bodyMag = (bodySin * 0.5 + 0.5)
                    let bodyH = CGFloat(bodyMag) * bodyTargetAmp * midY
                    if bodyTargetAmp > 0.01 {
                        drawBar(
                            ctx: &ctx,
                            x: x, width: barW,
                            from: midY, to: midY + bodyH,
                            colors: bodyColors()
                        )
                    } else {
                        drawBar(
                            ctx: &ctx,
                            x: x, width: barW,
                            from: midY, to: midY + 3,
                            colors: [.white.opacity(0.10), .white.opacity(0.04)]
                        )
                    }
                }
            }
        }
    }

    private func drawBar(
        ctx: inout GraphicsContext,
        x: CGFloat, width: CGFloat,
        from y1: CGFloat, to y2: CGFloat,
        colors: [Color]
    ) {
        let top = min(y1, y2)
        let bot = max(y1, y2)
        let rect = CGRect(x: x, y: top, width: width, height: bot - top)
        let path = Path(roundedRect: rect, cornerRadius: width / 2)
        let gradient = Gradient(colors: colors)
        ctx.fill(
            path,
            with: .linearGradient(
                gradient,
                startPoint: CGPoint(x: x, y: top),
                endPoint: CGPoint(x: x, y: bot)
            )
        )
    }

    // MARK: - Status caption

    @ViewBuilder
    private var statusCaption: some View {
        // Two-up caption summarising which half is "live" right now.
        // Helps the runner read the visualizer the first time.
        HStack(spacing: 12) {
            captionPill(active: isMusicPlaying && (musicBPM ?? 0) > 0,
                        label: musicCaptionLabel)
            captionPill(active: isBodyActive(at: .now),
                        label: bodyCaptionLabel)
        }
        .font(.caption2.weight(.semibold))
    }

    private var musicCaptionLabel: String {
        guard isMusicPlaying else { return "Music paused" }
        if let bpm = musicBPM { return "Music · \(Int(bpm.rounded())) BPM" }
        return "Music"
    }

    private var bodyCaptionLabel: String {
        if !isBodyActive(at: .now) { return "You · still" }
        if let hr = heartRateBPM { return "You · \(Int(hr.rounded())) bpm" }
        return "You"
    }

    private func captionPill(active: Bool, label: String) -> some View {
        Text(label)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(
                Capsule().fill(active ? Color.white.opacity(0.12) : Color.white.opacity(0.05))
            )
            .foregroundStyle(active ? .white.opacity(0.85) : .white.opacity(0.35))
    }

    // MARK: - Movement / amplitude logic

    private func isBodyActive(at now: Date) -> Bool {
        if workoutState == .paused { return false }
        return now.timeIntervalSince(lastMovedAt) < stationaryThreshold
    }

    private func hrAmplitude() -> CGFloat {
        guard let hr = heartRateBPM, hr > 0 else { return 0.15 }
        let unit = max(0.10, min(1.0, (hr - 60) / 120))
        return CGFloat(0.20 + 0.78 * unit)
    }

    private func musicAmplitude() -> CGFloat {
        let energy = musicEnergy ?? 0.7
        return CGFloat(0.30 + 0.65 * energy)
    }

    // MARK: - Palettes

    private func bodyColors() -> [Color] {
        guard let hr = heartRateBPM, hr > 0 else {
            return [Color(red: 0.45, green: 0.85, blue: 1.0).opacity(0.85),
                    Color(red: 0.45, green: 0.85, blue: 1.0).opacity(0.25)]
        }
        let unit = max(0, min(1, (hr - 60) / 120))
        if unit < 0.45 {
            return [Color(red: 0.30, green: 0.85, blue: 1.0),
                    Color(red: 0.55, green: 0.65, blue: 1.0).opacity(0.40)]
        }
        if unit < 0.75 {
            return [Color(red: 1.0, green: 0.45, blue: 0.85),
                    Color(red: 1.0, green: 0.30, blue: 0.55).opacity(0.45)]
        }
        return [Color(red: 1.0, green: 0.35, blue: 0.25),
                Color(red: 1.0, green: 0.80, blue: 0.20).opacity(0.45)]
    }

    private func musicColors() -> [Color] {
        let teal = Color(red: 0.30, green: 0.90, blue: 0.80)
        let purple = Color(red: 0.65, green: 0.45, blue: 1.0)
        return [teal, purple.opacity(0.45)]
    }
}

/// Stable per-bar random parameters. Generated once when the view
/// appears so the EQ profile doesn't flicker on every frame.
private struct BarSeed {
    /// Phase offset for the music half — bar i fires at a different
    /// moment in the music cycle than bar i+1.
    let musicPhase: Double
    /// Frequency multiplier for the music half — gives each bar a
    /// slightly different "bin" so they don't all peak together.
    let musicMult: Double
    let bodyPhase: Double
    let bodyMult: Double

    static func random() -> BarSeed {
        BarSeed(
            musicPhase: Double.random(in: 0...(2 * .pi)),
            musicMult: Double.random(in: 0.70...1.45),
            bodyPhase: Double.random(in: 0...(2 * .pi)),
            bodyMult: Double.random(in: 0.85...1.30)
        )
    }
}

#Preview("Active run + music") {
    KineticVisualizer(
        heartRateBPM: 152,
        paceSecPerKm: 320,
        distanceMeters: 1500,
        workoutState: .running,
        musicBPM: 128,
        musicEnergy: 0.75,
        isMusicPlaying: true
    )
    .frame(height: 220)
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}

#Preview("Standing still, music paused") {
    KineticVisualizer(
        heartRateBPM: 95,
        paceSecPerKm: nil,
        distanceMeters: 0,
        workoutState: .running,
        musicBPM: 110,
        musicEnergy: 0.4,
        isMusicPlaying: false
    )
    .frame(height: 220)
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}
