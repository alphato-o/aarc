import SwiftUI

/// In-run dual equalizer with two halves around a horizontal centerline.
///
///   TOP half (music) — wants to be literally audio-reactive. Driven
///   by `MicAudioCapture.bins`, a 16-band FFT of microphone input.
///   Music playing on the room (phone speaker, BT speaker, treadmill
///   TV) → bars dance with the real waveform. Music in hermetic
///   earbuds → mic hears nothing and the bars sit quiet. There's no
///   API in iOS to tap a third-party app's audio buffer; this is the
///   closest a public-SDK app can get to a real EQ.
///
///   If mic capture is disabled or denied, this half falls back to a
///   Spotify-BPM-driven phase animation just so something moves —
///   that's the "stylized" mode the user saw before.
///
///   BOTTOM half (body) — driven by the runner's actual biomechanics.
///   Bar phase rate = cadence (steps/min) so each pulse maps to a
///   footstep — that's the most physical signal we can get. Falls
///   back to HR rate if cadence isn't reported yet. Amplitude scales
///   with HR magnitude (60 bpm rest → small + cool, 180 bpm → tall +
///   hot via a cyan→pink→red heat map). When the runner stops
///   (cadence < 30 SPM AND distance hasn't moved in 1.5s, or the
///   workout is paused), the body half lerps smoothly toward zero.
struct KineticVisualizer: View {
    // Body inputs
    let heartRateBPM: Double?
    let cadenceStepsPerMinute: Double?
    let distanceMeters: Double
    let workoutState: WorkoutStateLike

    // Music inputs
    let micBins: [Float]
    let isMicCapturing: Bool
    let musicBPM: Double?
    let isMusicPlaying: Bool

    /// Erased state so the visualizer doesn't import AARCKit (which
    /// pulls in ActivityKit, which is iOS-only and breaks Xcode
    /// previews on macOS).
    enum WorkoutStateLike: Sendable {
        case running, paused, other
    }

    /// Number of EQ columns. Matches MicAudioCapture's band count when
    /// mic-driven so each band → one bar 1:1.
    private let barCount = 16

    /// Stationary detection state. Distance changing → updates
    /// `lastMovedAt`. Body bars freeze if elapsed since last movement
    /// exceeds this threshold (and cadence is low).
    @State private var lastDistance: Double = 0
    @State private var lastMovedAt: Date = .now
    private let stationaryThreshold: TimeInterval = 1.5
    private let cadenceStillThreshold: Double = 30

    /// Smoothed body amplitude — lerps toward 0 when stationary so
    /// the bars don't snap. 1.0 = fully active, 0.0 = silent.
    @State private var bodyEnvelope: Double = 0
    /// Smoothed BPM-fallback music amplitude. Same lerp story.
    @State private var musicEnvelope: Double = 0
    /// Per-bar stable phase offsets — generated once. Adds visual
    /// variation in the BPM-fallback path without making it look random.
    @State private var seeds: [BarSeed] = (0..<32).map { _ in BarSeed.random() }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            content(now: now, nowDate: timeline.date)
                .onChange(of: distanceMeters, initial: true) { _, newValue in
                    if abs(newValue - lastDistance) > 1 {
                        lastDistance = newValue
                        lastMovedAt = .now
                    }
                }
                .onChange(of: timeline.date) { _, t in
                    lerpEnvelopes(at: t)
                }
        }
        .overlay(alignment: .bottom) { statusCaption }
    }

    // MARK: - Envelope lerps (independent of the 60fps draw loop)

    private func lerpEnvelopes(at now: Date) {
        // 60fps; lerp ~0.06 per frame toward target → ~250ms time
        // constant. Smoother than a hard freeze.
        let alpha = 0.06
        let bodyTarget = bodyActive(now: now) ? bodyAmplitudeTarget() : 0
        bodyEnvelope += (bodyTarget - bodyEnvelope) * alpha
        let musicTarget = (isMusicPlaying && (musicBPM ?? 0) > 0) ? bpmAmplitudeTarget() : 0
        musicEnvelope += (musicTarget - musicEnvelope) * alpha
    }

    private func bodyAmplitudeTarget() -> Double {
        guard let hr = heartRateBPM, hr > 0 else { return 0.35 }
        let unit = max(0.10, min(1.0, (hr - 60) / 120))
        return 0.20 + 0.78 * unit
    }

    private func bpmAmplitudeTarget() -> Double {
        guard let bpm = musicBPM, bpm > 0 else { return 0 }
        let unit = max(0.10, min(1.0, (bpm - 60) / 120))
        return 0.30 + 0.55 * unit
    }

    private func bodyActive(now: Date) -> Bool {
        if workoutState == .paused { return false }
        let cadenceMoving = (cadenceStepsPerMinute ?? 0) >= cadenceStillThreshold
        let recentlyMoved = now.timeIntervalSince(lastMovedAt) < stationaryThreshold
        return cadenceMoving || recentlyMoved
    }

    // MARK: - Drawing

    @ViewBuilder
    private func content(now: TimeInterval, nowDate: Date) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let midY = h / 2

            Canvas { ctx, _ in
                let slotW = w / CGFloat(barCount)
                let barW = slotW * 0.50

                // Subtle baseline so the centerline reads as a line.
                let baseline = Path { p in
                    p.move(to: CGPoint(x: 0, y: midY))
                    p.addLine(to: CGPoint(x: w, y: midY))
                }
                ctx.stroke(baseline, with: .color(.white.opacity(0.10)), lineWidth: 0.75)

                for i in 0..<barCount {
                    let x = CGFloat(i) * slotW + (slotW - barW) / 2

                    // ----- MUSIC half (top, grows upward from midY) -----
                    let musicMag = musicMagnitude(at: i, now: now)
                    let musicH = CGFloat(musicMag) * midY
                    if musicH > 1 {
                        drawBar(ctx: &ctx,
                                x: x, width: barW,
                                from: midY, to: midY - musicH,
                                colors: musicColors())
                    } else {
                        // Faint resting pip so the column locations
                        // are visible even when silent.
                        drawBar(ctx: &ctx,
                                x: x, width: barW,
                                from: midY, to: midY - 2.5,
                                colors: [Color.white.opacity(0.10), Color.white.opacity(0.04)])
                    }

                    // ----- BODY half (bottom, grows downward) -----
                    let bodyMag = bodyMagnitude(at: i, now: now)
                    let bodyH = CGFloat(bodyMag) * midY
                    if bodyH > 1 {
                        drawBar(ctx: &ctx,
                                x: x, width: barW,
                                from: midY, to: midY + bodyH,
                                colors: bodyColors())
                    } else {
                        drawBar(ctx: &ctx,
                                x: x, width: barW,
                                from: midY, to: midY + 2.5,
                                colors: [Color.white.opacity(0.10), Color.white.opacity(0.04)])
                    }
                }
            }
        }
    }

    /// Music magnitude per bar in [0, 1]. Prefers real mic FFT bins;
    /// falls back to BPM-driven sine when mic is off / quiet / denied.
    private func musicMagnitude(at i: Int, now: TimeInterval) -> Double {
        if isMicCapturing, micBins.count == barCount {
            // Real FFT magnitude. Already smoothed inside MicAudioCapture.
            return Double(micBins[i])
        }
        // Fallback: BPM-driven sine. Frozen if music isn't playing.
        guard musicEnvelope > 0.01 else { return 0 }
        let seed = seeds[i % seeds.count]
        let rate = (musicBPM ?? 0) / 60.0 * 2 * .pi
        let s = sin(now * rate * seed.musicMult + seed.musicPhase)
        return ((s * 0.5) + 0.5) * musicEnvelope
    }

    /// Body magnitude per bar in [0, 1]. Phase rate is cadence/60
    /// (each pulse = footstep) when cadence is known; otherwise HR/60.
    /// Amplitude tracks `bodyEnvelope`, which lerps toward 0 when the
    /// runner stops.
    private func bodyMagnitude(at i: Int, now: TimeInterval) -> Double {
        guard bodyEnvelope > 0.01 else { return 0 }
        let seed = seeds[i % seeds.count]
        let rateHz: Double = {
            if let cad = cadenceStepsPerMinute, cad >= cadenceStillThreshold {
                return cad / 60.0
            }
            if let hr = heartRateBPM, hr > 0 {
                return hr / 60.0
            }
            return 1.5  // shouldn't happen — bodyEnvelope is ~0 in this case
        }()
        let rate = rateHz * 2 * .pi
        let s = sin(now * rate * seed.bodyMult + seed.bodyPhase)
        // Per-bar amplitude variation is small (±25%) so the bars look
        // coherent rather than random.
        let perBarScale = 0.85 + 0.30 * seed.bodyAmp
        return ((s * 0.5) + 0.5) * bodyEnvelope * perBarScale
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

    private var statusCaption: some View {
        HStack(spacing: 12) {
            captionPill(active: musicActiveForCaption,
                        dim: !musicActiveForCaption,
                        label: musicCaptionLabel)
            captionPill(active: bodyActive(now: .now),
                        dim: !bodyActive(now: .now),
                        label: bodyCaptionLabel)
        }
        .font(.caption2.weight(.semibold))
        .padding(.bottom, 4)
    }

    private var musicActiveForCaption: Bool {
        isMicCapturing || (isMusicPlaying && (musicBPM ?? 0) > 0)
    }

    private var musicCaptionLabel: String {
        if isMicCapturing { return "Music · mic EQ live" }
        if !isMusicPlaying { return "Music paused" }
        if let bpm = musicBPM { return "Music · \(Int(bpm.rounded())) BPM" }
        return "Music · stylized"
    }

    private var bodyCaptionLabel: String {
        if !bodyActive(now: .now) { return "You · still" }
        if let cad = cadenceStepsPerMinute, cad >= cadenceStillThreshold {
            return "You · \(Int(cad.rounded())) SPM"
        }
        if let hr = heartRateBPM { return "You · \(Int(hr.rounded())) bpm" }
        return "You · moving"
    }

    private func captionPill(active: Bool, dim: Bool, label: String) -> some View {
        Text(label)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(
                Capsule().fill(dim ? Color.white.opacity(0.05) : Color.white.opacity(0.12))
            )
            .foregroundStyle(dim ? .white.opacity(0.35) : .white.opacity(0.85))
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

private struct BarSeed {
    let musicPhase: Double
    let musicMult: Double
    let bodyPhase: Double
    let bodyMult: Double
    let bodyAmp: Double

    static func random() -> BarSeed {
        BarSeed(
            musicPhase: Double.random(in: 0...(2 * .pi)),
            musicMult: Double.random(in: 0.75...1.30),
            bodyPhase: Double.random(in: 0...(2 * .pi)),
            bodyMult: Double.random(in: 0.92...1.12),
            bodyAmp: Double.random(in: 0...1)
        )
    }
}

#Preview("Active run + music") {
    KineticVisualizer(
        heartRateBPM: 152,
        cadenceStepsPerMinute: 168,
        distanceMeters: 1500,
        workoutState: .running,
        micBins: (0..<16).map { _ in Float.random(in: 0...0.7) },
        isMicCapturing: true,
        musicBPM: 128,
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
        cadenceStepsPerMinute: 0,
        distanceMeters: 0,
        workoutState: .running,
        micBins: Array(repeating: 0, count: 16),
        isMicCapturing: false,
        musicBPM: 110,
        isMusicPlaying: false
    )
    .frame(height: 220)
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}
