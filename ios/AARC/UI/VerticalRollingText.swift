import SwiftUI

/// Multi-line text that lives inside a fixed-height container.
///
/// If the text's intrinsic rendered height fits the container, it
/// renders statically. If it overflows, the text auto-rolls vertically
/// in a continuous loop: dwell-at-top → scroll-down → dwell-at-bottom
/// → scroll-up → repeat. The container's own size is *never* affected
/// by the text length — the rolling stays clipped to the allocated
/// frame.
///
/// Used for in-run coach subtitles so the music-widget-shaped slot
/// stays the same dimensions whether the coach said "Three k." or a
/// 300-character monologue about cargo shorts and Sam Altman.
struct VerticalRollingText: View {
    let text: String
    let font: Font
    let color: Color
    /// Line spacing — affects total rendered height.
    let lineSpacing: CGFloat
    /// Seconds to dwell at the top + bottom of each scroll cycle.
    let dwellSeconds: TimeInterval
    /// Points per second the text crawls during the scroll phases.
    let scrollSpeed: CGFloat

    init(
        _ text: String,
        font: Font = .system(size: 19, weight: .semibold, design: .rounded),
        color: Color = .white,
        lineSpacing: CGFloat = 3,
        dwellSeconds: TimeInterval = 1.4,
        scrollSpeed: CGFloat = 22
    ) {
        self.text = text
        self.font = font
        self.color = color
        self.lineSpacing = lineSpacing
        self.dwellSeconds = dwellSeconds
        self.scrollSpeed = scrollSpeed
    }

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let overflow = max(0, contentHeight - geo.size.height)
            let needsRoll = overflow > 1
            ZStack(alignment: .topLeading) {
                if needsRoll {
                    rolling(overflow: overflow)
                } else {
                    staticText
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
    }

    private var staticText: some View {
        textView
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func rollingOffset(overflow: CGFloat, at time: TimeInterval) -> CGFloat {
        let scrollDuration = TimeInterval(overflow / scrollSpeed)
        let cycle = max(0.001, scrollDuration * 2 + dwellSeconds * 2)
        let mod = time.truncatingRemainder(dividingBy: cycle)
        // Dwell at top so the runner has time to start reading.
        if mod < dwellSeconds { return 0 }
        // Scroll down.
        if mod < dwellSeconds + scrollDuration {
            let t = (mod - dwellSeconds) / scrollDuration
            return -CGFloat(t) * overflow
        }
        // Dwell at bottom so the runner can finish the last line.
        if mod < dwellSeconds + scrollDuration + dwellSeconds {
            return -overflow
        }
        // Scroll back up.
        let t = (mod - dwellSeconds - scrollDuration - dwellSeconds) / scrollDuration
        return -overflow + CGFloat(t) * overflow
    }

    private func rolling(overflow: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            textView
                .offset(y: rollingOffset(
                    overflow: overflow,
                    at: timeline.date.timeIntervalSinceReferenceDate
                ))
        }
    }

    /// The actual text view, with the hidden background that measures
    /// its rendered height via a PreferenceKey (doesn't pollute layout
    /// the way a sibling fixedSize Text would).
    private var textView: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineSpacing(lineSpacing)
            .multilineTextAlignment(.leading)
            // Size to the FULL content height regardless of the
            // container's proposed height. Without this the Text is
            // proposed the (short) container height, truncates to fit,
            // and the height we measure below comes back truncated — so
            // overflow reads ~0 and the text caps instead of rolling.
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { g in
                    Color.clear
                        .preference(key: ContentHeightKey.self, value: g.size.height)
                }
            )
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

#Preview("Short — static") {
    VerticalRollingText("Three kilometres. Christ, you still upright?")
        .frame(width: 280, height: 110)
        .padding()
        .background(Color.black)
        .preferredColorScheme(.dark)
}

#Preview("Long — rolls") {
    VerticalRollingText(
        "Three fucking kilometres, you marvellous wretched bastard. Genuinely well done. No, not really. You're still going though, which is more than I can say for the bloke I saw earlier in cargo shorts arguing with a pigeon about a Greggs receipt."
    )
    .frame(width: 280, height: 110)
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}
