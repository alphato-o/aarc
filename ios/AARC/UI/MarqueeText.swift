import SwiftUI

/// Single-line text that statically centers if it fits in the
/// container, or scrolls horizontally on a continuous loop if the
/// content is wider. Used for in-run subtitles so long roasts can
/// keep moving instead of truncating.
///
/// Implementation: measures content width once (per text) via a
/// hidden Text background + GeometryReader. If content > container,
/// renders two copies separated by a gap and offsets them with a
/// TimelineView at ~35 pt/sec, wrapping cleanly each cycle.
struct MarqueeText: View {
    let text: String
    let font: Font
    let textColor: Color
    /// Pixels per second the text crawls left while scrolling.
    let speed: CGFloat
    /// Empty space between repetitions when scrolling.
    let gap: CGFloat

    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    init(
        _ text: String,
        font: Font = .body,
        color: Color = .white,
        speed: CGFloat = 35,
        gap: CGFloat = 60
    ) {
        self.text = text
        self.font = font
        self.textColor = color
        self.speed = speed
        self.gap = gap
    }

    private var shouldScroll: Bool {
        contentWidth > containerWidth + 1
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if shouldScroll {
                    scrolling
                } else {
                    Text(text)
                        .font(font)
                        .foregroundStyle(textColor)
                        .lineLimit(1)
                        .frame(width: geo.size.width, alignment: .center)
                }

                // Hidden measurer — one Text fixed-sized so we can read
                // its intrinsic width. Updates on text changes.
                Text(text)
                    .font(font)
                    .fixedSize(horizontal: true, vertical: false)
                    .lineLimit(1)
                    .hidden()
                    .background(
                        GeometryReader { gp in
                            Color.clear
                                .onAppear { update(contentW: gp.size.width, containerW: geo.size.width) }
                                .onChange(of: text) { _, _ in update(contentW: gp.size.width, containerW: geo.size.width) }
                                .onChange(of: gp.size.width) { _, w in update(contentW: w, containerW: geo.size.width) }
                                .onChange(of: geo.size.width) { _, w in update(contentW: gp.size.width, containerW: w) }
                        }
                    )
            }
            .clipped()
        }
    }

    private func update(contentW: CGFloat, containerW: CGFloat) {
        if contentW > 0 { contentWidth = contentW }
        if containerW > 0 { containerWidth = containerW }
    }

    @ViewBuilder
    private var scrolling: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
            let cycle = contentWidth + gap
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let raw = CGFloat(elapsed) * speed
            // Mod by the cycle length so the offset wraps cleanly.
            let mod = raw.truncatingRemainder(dividingBy: max(cycle, 1))
            let offset = -mod
            HStack(spacing: gap) {
                Text(text).font(font).foregroundStyle(textColor).lineLimit(1).fixedSize()
                Text(text).font(font).foregroundStyle(textColor).lineLimit(1).fixedSize()
            }
            .offset(x: offset)
        }
    }
}

#Preview("Short — static") {
    MarqueeText("Short line, fits easily.", font: .title3)
        .frame(width: 320, height: 36)
        .background(Color.black)
        .preferredColorScheme(.dark)
}

#Preview("Long — scrolls") {
    MarqueeText(
        "Three fucking kilometres and you're still going, you marvellous wretched bastard — keep going.",
        font: .title3
    )
    .frame(width: 320, height: 36)
    .background(Color.black)
    .preferredColorScheme(.dark)
}
