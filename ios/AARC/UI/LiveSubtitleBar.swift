import SwiftUI

/// In-run subtitle bar that temporarily replaces the music-command
/// widget while the coach is speaking (and for a short dwell window
/// after, so the user has time to tap the heart). Layout:
///
///   ┌─────────────────────────────────────────────────────────┐
///   │  «Three kilometres in. Christ, you still upright?»  ❤️ │
///   │  ▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░                │
///   └─────────────────────────────────────────────────────────┘
///
/// The text marquees if it overflows. The thin progress bar at the
/// bottom drains over the line's total dwell window (~speaking time
/// plus 6s grace) so the runner can see how much time they have left
/// to react. Tapping the heart toggles persistence in LikedLinesStore
/// via LiveSubtitleStore.toggleLike.
struct LiveSubtitleBar: View {
    let line: LiveSubtitleStore.Line
    let onToggleHeart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                statusDot
                MarqueeText(
                    line.text,
                    font: .system(.callout, design: .rounded, weight: .semibold),
                    color: .white
                )
                .frame(maxWidth: .infinity, maxHeight: 24)

                heartButton
            }
            reactionWindowBar
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(barAccent.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: barAccent.opacity(0.30), radius: 16, y: 4)
    }

    private var statusDot: some View {
        Circle()
            .fill(line.isPlaying ? barAccent : barAccent.opacity(0.45))
            .frame(width: 8, height: 8)
            .shadow(color: barAccent.opacity(0.7), radius: 4)
            .scaleEffect(line.isPlaying ? 1.0 : 0.85)
            .animation(.easeOut(duration: 0.4), value: line.isPlaying)
    }

    private var heartButton: some View {
        Button(action: onToggleHeart) {
            Image(systemName: line.liked ? "heart.fill" : "heart")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(
                    line.liked
                    ? LinearGradient(
                        colors: [Color(red: 1, green: 0.35, blue: 0.55),
                                 Color(red: 1, green: 0.55, blue: 0.30)],
                        startPoint: .top, endPoint: .bottom
                      )
                    : LinearGradient(colors: [.white.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                )
                .frame(width: 44, height: 44)
                .background(
                    Circle().fill(line.liked ? Color.pink.opacity(0.15) : Color.white.opacity(0.08))
                )
                .symbolEffect(.bounce, value: line.liked)
                .accessibilityLabel(line.liked ? "Unlike line" : "Like line")
        }
        .buttonStyle(.plain)
    }

    /// Thin bottom progress bar that drains from full → empty over
    /// the line's full dwell window. Reads as "this is how much time
    /// you have to tap heart before the bar disappears." Refreshed
    /// every TimelineView tick so the drain is smooth.
    private var reactionWindowBar: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(line.startedAt)
            let total = line.estimatedTotalDwell
            let progress = max(0, min(1, 1 - elapsed / total))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [barAccent, barAccent.opacity(0.5)],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, geo.size.width * CGFloat(progress)))
                }
            }
            .frame(height: 3)
        }
    }

    /// Accent color for the bar — picks a tint based on the line's
    /// priority so milestone / coaching / banter are visually
    /// distinguishable at a glance.
    private var barAccent: Color {
        switch line.priority {
        case .milestone: return Color(red: 1.0, green: 0.55, blue: 0.30)   // amber
        case .coaching: return Color(red: 0.40, green: 0.85, blue: 1.0)    // cyan
        case .banter: return Color(red: 0.65, green: 0.45, blue: 1.0)      // purple
        }
    }
}

#Preview("Playing, milestone, unliked") {
    LiveSubtitleBar(
        line: LiveSubtitleStore.Line(
            id: UUID(),
            text: "Three kilometres in. Christ, you still upright?",
            source: "script:per_km",
            priority: .milestone,
            startedAt: .now,
            isPlaying: true,
            estimatedTotalDwell: 12,
            liked: false
        ),
        onToggleHeart: {}
    )
    .frame(width: 360)
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}

#Preview("Dwell, banter, liked") {
    LiveSubtitleBar(
        line: LiveSubtitleStore.Line(
            id: UUID(),
            text: "Oh, 'I'd catch a grenade for ya' — would you though? Have you actually SEEN a grenade?",
            source: "coach:music_riff",
            priority: .banter,
            startedAt: .now.addingTimeInterval(-3),
            isPlaying: false,
            estimatedTotalDwell: 12,
            liked: true
        ),
        onToggleHeart: {}
    )
    .frame(width: 360)
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}
