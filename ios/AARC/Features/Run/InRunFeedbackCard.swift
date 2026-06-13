import SwiftUI
import UIKit

/// In-run feedback display: a bounded, rolling karaoke subtitle (like Apple
/// Music lyrics). Shows ~3 lines at a time in a fixed-height window that
/// auto-scrolls to keep the line being spoken centred; words light up as
/// they're voiced. A big heart sits at the bottom — easy to hit mid-stride.
/// Shown in place of the chart + music control while a line plays.
struct InRunFeedbackCard: View {
    let line: LiveSubtitleStore.Line
    var onHeart: () -> Void

    @State private var tts = RemoteTTS.shared

    private var who: String { line.voice == .jessica ? "JESSICA" : "RICKY" }
    private var accent: Color { line.voice == .jessica ? .pink : .orange }
    /// Fallback estimate; only used until the real audio duration is known.
    private var estDur: Double { max(2, line.estimatedTotalDwell - 6) }

    var body: some View {
        VStack(spacing: 12) {
            // Full-width heart on top — a fat target, no aiming mid-stride.
            Button(action: onHeart) {
                HStack(spacing: 8) {
                    Image(systemName: line.liked ? "heart.fill" : "heart")
                        .font(.system(size: 22, weight: .semibold))
                    Text(line.liked ? "Loved" : "Love this line")
                        .font(.subheadline.bold())
                }
                .foregroundStyle(line.liked ? .pink : .white.opacity(0.9))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(line.liked ? Color.pink.opacity(0.18) : .white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)

            HStack {
                Text(who).font(.caption.bold()).foregroundStyle(accent)
                Spacer()
            }
            Group {
                if line.isPlaying {
                    TimelineView(.animation(minimumInterval: 0.06)) { tl in
                        // Roll against the REAL audio time so the highlight's
                        // END lands with the audio's end (char estimate ran long).
                        let dur = (tts.playbackDuration ?? estDur)
                        let start = tts.playbackStartedAt ?? line.startedAt
                        let elapsed = tl.date.timeIntervalSince(start)
                        let progress = min(elapsed / max(dur, 0.5), 0.999)
                        RollingKaraoke(text: line.text.strippingAudioTags, progress: progress)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    // Audio done → show the WHOLE line, font auto-fit to the
                    // box, static (no scroll/highlight) so it's readable while
                    // you decide on the heart — no end-of-line "dance".
                    StaticFitQuote(text: line.text.strippingAudioTags)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            .clipped()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(accent.opacity(0.3), lineWidth: 1))
    }
}

/// The whole line, centred, font shrunk to fit its box — shown once the audio
/// finishes so the runner can read it all and decide on the heart.
struct StaticFitQuote: View {
    let text: String
    var body: some View {
        GeometryReader { geo in
            // Measure and render at the SAME width so the fit is honest.
            let w = geo.size.width
            let size = ShareCardView.fittedSerifSize(
                "\u{201C}\(text)\u{201D}", boxW: w, boxH: geo.size.height, maxSize: 28)
            Text("\u{201C}\(text)\u{201D}")
                .font(.custom("Georgia-Italic", size: size))
                .foregroundStyle(Color(red: 0.957, green: 0.949, blue: 0.910))
                .multilineTextAlignment(.center)
                .frame(width: w, height: geo.size.height, alignment: .center)
        }
    }
}

/// A scrolling karaoke window: wraps the line into fixed lines, lights words
/// up by progress, and offsets so the active line stays centred in the
/// viewport. ~26pt so 2–3 lines are readable at arm's length on a treadmill.
struct RollingKaraoke: View {
    let text: String
    let progress: Double
    var fontSize: CGFloat = 21

    private let cream = Color(red: 0.957, green: 0.949, blue: 0.910)
    private var lineH: CGFloat { fontSize * 1.42 }

    var body: some View {
        GeometryReader { geo in
            let lines = Self.wrap(text, width: geo.size.width, fontSize: fontSize)
            let total = max(1, lines.reduce(0) { $0 + $1.count })
            let activeWord = min(total - 1, Int(progress * Double(total)))
            let activeLine = lineIndex(of: activeWord, in: lines)
            let viewH = geo.size.height
            let contentH = CGFloat(lines.count) * lineH
            // Keep the active line at the viewport's MIDDLE, but clamp so the
            // start stays pinned to the top and the end pinned to the bottom —
            // never scroll blank past either edge, so surrounding text is
            // always visible. If it all fits, top-align (offset 0).
            let centred = viewH / 2 - (CGFloat(activeLine) + 0.5) * lineH
            let minOffset = min(0, viewH - contentH)   // most-scrolled (end at bottom)
            let offset = contentH <= viewH ? 0 : max(minOffset, min(0, centred))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, lineWords in
                    HStack(alignment: .firstTextBaseline, spacing: fontSize * 0.26) {
                        ForEach(lineWords, id: \.idx) { w in
                            word(w.text, glow: glow(w.idx, active: activeWord))
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: lineH, alignment: .leading)   // exact line advance
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .offset(y: offset)
            .animation(.easeInOut(duration: 0.4), value: activeLine)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func glow(_ idx: Int, active: Int) -> Double {
        if progress >= 1 { return idx <= active ? -1 : 0 }
        if idx < active { return -1 }            // read → full bright
        if idx == active { return 1 }            // speaking → lit
        return 0                                  // unread → dim
    }

    @ViewBuilder private func word(_ w: String, glow g: Double) -> some View {
        let read = g < 0
        Text(w)
            .font(.custom("Georgia-Italic", size: fontSize))
            .lineLimit(1)
            .fixedSize()                       // never truncate a word to "wor…"
            .foregroundStyle(cream.opacity(read ? 1 : 0.34 + 0.66 * g))
            .padding(.horizontal, 0.08 * fontSize)
            .background(Color(red: 0.56, green: 0.72, blue: 0.60).opacity(0.22 * max(0, g)),
                        in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: Color(red: 0.81, green: 0.91, blue: 0.84).opacity(0.9 * max(0, g)),
                    radius: 12 * max(0, g))
    }

    private func lineIndex(of word: Int, in lines: [[WordTok]]) -> Int {
        for (i, l) in lines.enumerated() where l.contains(where: { $0.idx == word }) { return i }
        return max(0, lines.count - 1)
    }

    struct WordTok: Identifiable { let idx: Int; let text: String; var id: Int { idx } }

    /// Greedy word-wrap into lines, measured with the real font.
    static func wrap(_ text: String, width: CGFloat, fontSize: CGFloat) -> [[WordTok]] {
        let font = UIFont(name: "Georgia-Italic", size: fontSize) ?? .italicSystemFont(ofSize: fontSize)
        let space = fontSize * 0.26
        let words = text.split(separator: " ").map(String.init)
        var lines: [[WordTok]] = []
        var cur: [WordTok] = []
        var curW: CGFloat = 0
        for (i, w) in words.enumerated() {
            let ww = (w as NSString).size(withAttributes: [.font: font]).width + fontSize * 0.16
            if curW + ww > width, !cur.isEmpty { lines.append(cur); cur = []; curW = 0 }
            cur.append(WordTok(idx: i, text: w)); curW += ww + space
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines
    }
}
