import SwiftUI

/// In-run feedback display — the same word-by-word karaoke highlight used in
/// the shareable video, shown large and readable in the chart's slot while a
/// line is being spoken. It evenly rolls the highlight across the line's
/// estimated speaking time, then holds. When the line clears (post-dwell),
/// ActiveRunView swaps the live chart back in.
struct InRunFeedbackCard: View {
    let line: LiveSubtitleStore.Line
    var onHeart: () -> Void

    private var who: String { line.voice == .jessica ? "JESSICA" : "RICKY" }
    private var accent: Color { line.voice == .jessica ? .pink : .orange }
    /// Speaking portion = total dwell minus the post-speech react window.
    private var speakDur: Double { max(2, line.estimatedTotalDwell - 6) }

    var body: some View {
        GeometryReader { geo in
            let size = ShareCardView.fittedSerifSize(
                "\u{201C}\(line.text)\u{201D}",
                boxW: (geo.size.width - 40) * 0.86,
                boxH: geo.size.height - 70,
                maxSize: 40)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(who).font(.caption.bold()).foregroundStyle(accent)
                    Spacer()
                    Button(action: onHeart) {
                        Image(systemName: line.liked ? "heart.fill" : "heart")
                            .foregroundStyle(line.liked ? .pink : .white.opacity(0.6))
                    }.buttonStyle(.plain)
                }
                TimelineView(.animation(minimumInterval: 0.06)) { tl in
                    let elapsed = tl.date.timeIntervalSince(line.startedAt)
                    let progress = line.isPlaying ? min(elapsed / speakDur, 0.999) : 1
                    KaraokeQuote(text: "\u{201C}\(line.text)\u{201D}", progress: progress, fontSize: size)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(accent.opacity(0.25), lineWidth: 1))
        }
    }
}
