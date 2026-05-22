import SwiftUI

/// Center-screen kinetic visualizer for the in-run UI.
///
/// Two stacked flowing wave forms, each tied to a *real* signal — never
/// faked.
///
///   • **HR wave** (top half) — frequency tracks the runner's heart
///     rate, amplitude scales with HR magnitude (60 bpm rest → small
///     and cool, 180 bpm threshold → tall and hot), hue heat-maps
///     cyan → pink → red. When HR is nil the wave collapses to a thin
///     grey baseline + a quiet "Waiting for heart rate…" caption.
///
///   • **Music wave** (bottom half) — frequency tracks the currently-
///     playing track's tempo (via Spotify /audio-features). Color is
///     a cooler teal-purple. When tempo is nil but HR is available
///     the wave falls back to HR/60 so something still moves with the
///     runner; when both are nil the wave collapses to a flat line.
///
/// A slow time-derived phase noise stops the waves from looking
/// perfectly periodic across a long run. Implemented with Canvas +
/// TimelineView at 60fps for smoothness.
struct KineticVisualizer: View {
    let heartRateBPM: Double?
    let musicBPM: Double?

    /// Reasonable resting / max anchors so HR magnitude maps to a
    /// visible 0…1 range without manual tuning. A trained runner's
    /// LTHR is usually well under 180, so 60-180 covers the meat of
    /// the distribution and clamps at the tails.
    private let hrRestBPM: Double = 60
    private let hrMaxBPM: Double = 180

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let h = geo.size.height
                let halfH = h / 2 - 2
                ZStack {
                    // HR wave occupies the top half.
                    waveLayer(
                        time: now,
                        size: CGSize(width: geo.size.width, height: halfH),
                        signal: hrSignal
                    )
                    .frame(width: geo.size.width, height: halfH)
                    .position(x: geo.size.width / 2, y: halfH / 2)

                    // Music wave occupies the bottom half.
                    waveLayer(
                        time: now,
                        size: CGSize(width: geo.size.width, height: halfH),
                        signal: musicSignal
                    )
                    .frame(width: geo.size.width, height: halfH)
                    .position(x: geo.size.width / 2, y: halfH + 4 + halfH / 2)

                    // "Waiting for HR" caption only when the runner has
                    // no HR feed yet — keeps the visualizer honest about
                    // what's real.
                    if heartRateBPM == nil {
                        Text("Waiting for heart rate…")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.35))
                            .position(x: geo.size.width / 2, y: halfH / 2)
                    }
                }
            }
        }
    }

    // MARK: - Signals
    //
    // A Signal bundles together "what frequency, what amplitude, what
    // colors" so the wave drawer doesn't know or care which physical
    // input it's portraying.

    private struct Signal {
        let frequencyHz: Double      // 0 → flat line, no animation
        let amplitudeUnit: Double    // 0..1, scales rendered amplitude
        let colors: [Color]          // 2-3 stop gradient along the wave
        let glowColor: Color
        let lineWidth: CGFloat
    }

    private var hrSignal: Signal {
        guard let hr = heartRateBPM, hr > 0 else {
            // No real HR yet — render a near-flat dim baseline.
            return Signal(
                frequencyHz: 0,
                amplitudeUnit: 0.04,
                colors: [Color.white.opacity(0.18), Color.white.opacity(0.10)],
                glowColor: .clear,
                lineWidth: 2
            )
        }
        // Map HR magnitude to a 0..1 unit. Clamp + smooth.
        let raw = (hr - hrRestBPM) / (hrMaxBPM - hrRestBPM)
        let unit = max(0.10, min(1.0, raw))
        // Color heat map: cool when low, hot when high.
        let cool = Color(red: 0.30, green: 0.85, blue: 1.0)
        let mid = Color(red: 1.0, green: 0.45, blue: 0.85)
        let hot = Color(red: 1.0, green: 0.30, blue: 0.30)
        let palette: [Color] = {
            if unit < 0.45 { return [cool, mid] }
            if unit < 0.75 { return [mid, hot] }
            return [hot, Color(red: 1.0, green: 0.85, blue: 0.20)]
        }()
        return Signal(
            frequencyHz: hr / 60,
            amplitudeUnit: 0.18 + 0.78 * unit,
            colors: palette,
            glowColor: palette.last?.opacity(0.6) ?? .clear,
            lineWidth: 3
        )
    }

    private var musicSignal: Signal {
        let teal = Color(red: 0.20, green: 0.85, blue: 0.80)
        let purple = Color(red: 0.55, green: 0.40, blue: 0.95)
        if let bpm = musicBPM, bpm > 0 {
            // Map tempo 60-180 BPM to amplitude 0.35..0.85 so a slow
            // song breathes, a fast song surges.
            let unit = max(0.10, min(1.0, (bpm - 60) / 120))
            return Signal(
                frequencyHz: bpm / 60,
                amplitudeUnit: 0.30 + 0.55 * unit,
                colors: [teal, purple],
                glowColor: purple.opacity(0.55),
                lineWidth: 3
            )
        }
        // Music BPM unknown. If we have HR, use that frequency so the
        // wave still feels alive; otherwise flatline this layer.
        if let hr = heartRateBPM, hr > 0 {
            return Signal(
                frequencyHz: hr / 60,
                amplitudeUnit: 0.32,
                colors: [teal.opacity(0.65), purple.opacity(0.65)],
                glowColor: purple.opacity(0.30),
                lineWidth: 2.5
            )
        }
        return Signal(
            frequencyHz: 0,
            amplitudeUnit: 0.03,
            colors: [Color.white.opacity(0.12), Color.white.opacity(0.06)],
            glowColor: .clear,
            lineWidth: 2
        )
    }

    // MARK: - Wave layer

    private func waveLayer(time: TimeInterval, size: CGSize, signal: Signal) -> some View {
        Canvas { ctx, canvasSize in
            let path = wavePath(time: time, size: canvasSize, signal: signal)
            let gradient = Gradient(colors: signal.colors)
            let shading = GraphicsContext.Shading.linearGradient(
                gradient,
                startPoint: .zero,
                endPoint: CGPoint(x: canvasSize.width, y: 0)
            )
            ctx.stroke(
                path,
                with: shading,
                style: StrokeStyle(lineWidth: signal.lineWidth, lineCap: .round, lineJoin: .round)
            )
            if signal.glowColor != .clear {
                ctx.addFilter(.blur(radius: 6))
                ctx.stroke(
                    path,
                    with: .color(signal.glowColor),
                    style: StrokeStyle(lineWidth: signal.lineWidth + 4, lineCap: .round)
                )
            }
        }
    }

    /// Composite wave: a primary sine at `signal.frequencyHz`, plus a
    /// slower secondary sine to add organic distortion so the trace
    /// never looks perfectly periodic across a long session.
    private func wavePath(time: TimeInterval, size: CGSize, signal: Signal) -> Path {
        let midY = size.height / 2
        let amp = signal.amplitudeUnit * (midY - 4)
        let steps = max(40, Int(size.width / 4))
        let phaseAdvance = time * signal.frequencyHz * .pi * 2
        // Slower drift component: 1/10th of the primary's frequency,
        // so the wave's envelope subtly evolves over many beats.
        let driftPhase = time * 0.18 * .pi * 2

        var path = Path()
        for i in 0...steps {
            let x = CGFloat(i) / CGFloat(steps) * size.width
            // Two cycles fit across the visible width at frequency=1Hz;
            // higher-frequency signals produce more visible peaks.
            let spatialPhase = Double(i) / Double(steps) * .pi * 2 * 2
            let primary = sin(spatialPhase + phaseAdvance)
            let drift = 0.20 * sin(spatialPhase * 0.5 + driftPhase)
            let y = midY - CGFloat(primary + drift) * amp

            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

#Preview("Live: HR 145, music 128 BPM") {
    KineticVisualizer(heartRateBPM: 145, musicBPM: 128)
        .frame(height: 220)
        .padding()
        .background(Color.black)
        .preferredColorScheme(.dark)
}

#Preview("Waiting for HR, music 90 BPM") {
    KineticVisualizer(heartRateBPM: nil, musicBPM: 90)
        .frame(height: 220)
        .padding()
        .background(Color.black)
        .preferredColorScheme(.dark)
}

#Preview("HR 165, no music") {
    KineticVisualizer(heartRateBPM: 165, musicBPM: nil)
        .frame(height: 220)
        .padding()
        .background(Color.black)
        .preferredColorScheme(.dark)
}
