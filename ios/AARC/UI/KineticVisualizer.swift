import SwiftUI

/// Center-screen kinetic visualizer for the in-run UI.
/// Vertical neon bars centered around a pulsing heart icon, with bar
/// heights driven by the runner's heart rate (primary signal) and
/// modulated by the currently-playing track's BPM (secondary signal,
/// when Spotify audio-features is available). Pink → cyan vertical
/// gradient with a soft glow. Purpose: stop the runner from going
/// mad staring at a treadmill console for an hour.
///
/// Animation is driven by TimelineView (one frame per ~16ms) and a
/// pure-function phase calculation that's cheap on the GPU. No timers,
/// no @State spamming.
struct KineticVisualizer: View {
    /// Heart rate in BPM. nil → falls back to a 75 BPM idle rhythm so
    /// the visualizer is never frozen (the user is still moving, the
    /// watch just hasn't reported HR yet on this tick).
    let heartRateBPM: Double?
    /// Optional music BPM. If present, mixed into the bar phase so the
    /// animation breathes with the song. If nil, bars react to HR only.
    let musicBPM: Double?

    /// Number of bars. Odd so a central bar lines up with the heart.
    private let barCount: Int = 13
    /// Bar width to spacing ratio.
    private let barWidthFraction: CGFloat = 0.55
    /// How much the heart icon scales between its rest and peak size.
    private let heartScaleAmplitude: CGFloat = 0.18
    /// Idle pulse when no HR is available.
    private let idleHRBPM: Double = 75

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let hr = max(40, heartRateBPM ?? idleHRBPM)
            // Phase in radians: HR/60 cycles per second.
            let hrPhase = now * (hr / 60.0) * .pi * 2
            // Music phase (if any), at half the HR phase's amplitude.
            let musicPhase: Double? = musicBPM.map { bpm in
                now * (bpm / 60.0) * .pi * 2
            }

            GeometryReader { geo in
                ZStack {
                    bars(in: geo.size, hrPhase: hrPhase, musicPhase: musicPhase)
                    heart(hrPhase: hrPhase)
                }
            }
        }
    }

    // MARK: - Bars

    @ViewBuilder
    private func bars(in size: CGSize, hrPhase: Double, musicPhase: Double?) -> some View {
        let count = barCount
        let totalSpacing: CGFloat = size.width
        let slotWidth = totalSpacing / CGFloat(count)
        let barW = slotWidth * barWidthFraction
        let mid = (count - 1) / 2

        Canvas { ctx, _ in
            for i in 0..<count {
                let distFromCenter = abs(i - mid)
                // Higher bars near the middle (rough bell curve).
                let envelope = 0.55 + 0.45 * cos(Double(distFromCenter) / Double(mid + 1) * .pi / 2)
                // Each bar slightly out of phase so the wave appears to
                // travel across the row.
                let perBarPhaseShift = Double(i) * 0.32
                let hrComponent = (sin(hrPhase + perBarPhaseShift) + 1) / 2  // 0..1
                let musicComponent = musicPhase.map { (sin($0 + perBarPhaseShift * 0.7) + 1) / 2 } ?? hrComponent
                // Weighted mix: HR is 60%, music 40% — but when music
                // is absent we just use HR for both terms above.
                let mix = 0.6 * hrComponent + 0.4 * musicComponent
                let amplitude = CGFloat(mix * envelope)

                let barHeight = max(barW * 1.2, size.height * (0.2 + 0.55 * amplitude))
                let x = CGFloat(i) * slotWidth + (slotWidth - barW) / 2
                let y = (size.height - barHeight) / 2
                let rect = CGRect(x: x, y: y, width: barW, height: barHeight)
                let path = Path(roundedRect: rect, cornerRadius: barW / 2)
                let gradient = Gradient(stops: [
                    .init(color: Color(red: 1.0, green: 0.35, blue: 0.72), location: 0),
                    .init(color: Color(red: 0.45, green: 0.80, blue: 1.0), location: 0.55),
                    .init(color: Color(red: 0.30, green: 1.0, blue: 0.85), location: 1),
                ])
                let shading = GraphicsContext.Shading.linearGradient(
                    gradient,
                    startPoint: CGPoint(x: x, y: y),
                    endPoint: CGPoint(x: x, y: y + barHeight)
                )
                ctx.fill(path, with: shading)

                // Soft glow on top of the fill — blur the path itself.
                ctx.addFilter(.blur(radius: 4))
                ctx.fill(path, with: .color(Color(red: 1.0, green: 0.45, blue: 0.85, opacity: 0.45)))
            }
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - Heart

    private func heart(hrPhase: Double) -> some View {
        // Two-phase pulse per beat: a quick rise and longer relax,
        // approximated by sin^4 so the peak is sharper than a plain sin.
        let raw = sin(hrPhase) * 0.5 + 0.5
        let sharped = pow(raw, 4)
        let scale = 1.0 + heartScaleAmplitude * sharped

        return Image(systemName: "heart.fill")
            .resizable()
            .scaledToFit()
            .frame(width: 56, height: 56)
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        Color(red: 1.0, green: 0.25, blue: 0.55),
                        Color(red: 1.0, green: 0.50, blue: 0.30),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .shadow(color: Color(red: 1, green: 0.3, blue: 0.5).opacity(0.7), radius: 14)
            .scaleEffect(scale)
    }
}

#Preview {
    KineticVisualizer(heartRateBPM: 145, musicBPM: 128)
        .frame(height: 220)
        .background(Color.black)
        .preferredColorScheme(.dark)
}
