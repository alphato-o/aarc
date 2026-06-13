import SwiftUI
import Charts

/// Data for one share card — built from a whole run or a single hearted line.
struct ShareCardModel {
    var date: String
    var kpis: [(label: String, value: String)]
    var speed: [Double]
    var hr: [Double]
    var quote: String
    var who: String        // "ricky" | "jessica" | ""
    var aspect: CGFloat    // width / height (0.8 portrait, 1 square)

    static let portrait: CGFloat = 1080.0 / 1350.0
    static let square: CGFloat = 1.0
}

/// The shareable card, a real SwiftUI view rendered at 1080-wide via
/// ImageRenderer (image) or frame-by-frame (video). Mirrors the dashboard
/// quote card: pub-green wash, goblet logo + aarun.club, run KPIs, a compact
/// pace/HR strip, and the line as the serif centrepiece with a word-by-word
/// karaoke highlight (driven by `progress` during video; 1 = static image).
struct ShareCardView: View {
    let model: ShareCardModel
    var progress: Double = 1

    private let W: CGFloat = 1080
    private var H: CGFloat { (W / model.aspect).rounded() }
    private let cream = Color(red: 0.957, green: 0.949, blue: 0.910)
    private let dim = Color(red: 0.46, green: 0.51, blue: 0.44)

    var body: some View {
        ZStack {
            Color(red: 0.043, green: 0.055, blue: 0.047)
            RadialGradient(colors: [Color(red: 0.29, green: 0.39, blue: 0.31).opacity(0.55), .clear],
                           center: .init(x: 0.16, y: -0.05), startRadius: 30, endRadius: W)
            VStack(alignment: .leading, spacing: 0) {
                header
                Rectangle().fill(cream.opacity(0.10)).frame(height: 1.5).padding(.top, 26)
                kpiRow.padding(.top, 34)
                chartStrip.padding(.top, 30)
                Spacer(minLength: 30)
                KaraokeQuote(text: "\u{201C}\(model.quote)\u{201D}", progress: progress,
                             baseSize: H > 1200 ? 72 : 58)
                Spacer(minLength: 30)
                footer
            }
            .padding(64)
        }
        .frame(width: W, height: H)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .top) {
            HStack(spacing: 18) {
                GobletLogo().frame(width: 64, height: 64)
                Text("AARC").font(.system(size: 42, weight: .heavy)).foregroundStyle(cream)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("aarun.club").font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color(red: 0.62, green: 0.72, blue: 0.65))
                if !model.date.isEmpty {
                    Text(model.date).font(.system(size: 20)).foregroundStyle(dim)
                }
            }
        }
    }

    private var kpiRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(model.kpis.enumerated()), id: \.offset) { i, kpi in
                VStack(spacing: 6) {
                    Text(kpi.value).font(.system(size: 44, weight: .heavy)).monospacedDigit()
                        .foregroundStyle(cream).minimumScaleFactor(0.5).lineLimit(1)
                    Text(kpi.label.uppercased()).font(.system(size: 17, weight: .bold))
                        .foregroundStyle(dim)
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    if i > 0 { Rectangle().fill(cream.opacity(0.08)).frame(width: 1, height: 56) }
                }
            }
        }
    }

    @ViewBuilder private var chartStrip: some View {
        let speed = model.speed.enumerated().map { ($0.offset, $0.element) }
        let hr = model.hr.enumerated().map { ($0.offset, $0.element) }
        if speed.count > 1 || hr.count > 1 {
            Chart {
                ForEach(speed, id: \.0) { i, v in
                    AreaMark(x: .value("i", i), y: .value("kmh", v))
                        .foregroundStyle(.linearGradient(
                            colors: [Color(red: 0.56, green: 0.72, blue: 0.60).opacity(0.30), .clear],
                            startPoint: .top, endPoint: .bottom))
                }
                ForEach(speed, id: \.0) { i, v in
                    LineMark(x: .value("i", i), y: .value("kmh", v), series: .value("s", "p"))
                        .foregroundStyle(Color(red: 0.66, green: 0.78, blue: 0.69))
                        .lineStyle(.init(lineWidth: 3))
                }
                ForEach(hr, id: \.0) { i, v in
                    LineMark(x: .value("i", i), y: .value("hr", v), series: .value("s", "h"))
                        .foregroundStyle(Color(red: 0.83, green: 0.46, blue: 0.42))
                        .lineStyle(.init(lineWidth: 2.5))
                }
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .frame(height: H > 1200 ? 150 : 120)
        }
    }

    private var footer: some View {
        HStack {
            Text("An AI running coach that talks back.")
                .font(.system(size: 20)).foregroundStyle(dim)
            Spacer()
            Text("aarun.club").font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color(red: 0.62, green: 0.72, blue: 0.65))
        }
    }
}

/// Serif quote whose words light up in sequence — full-bright once spoken,
/// a glowing pill while being spoken, dim before. Evenly distributed across
/// the clip; the voice is fairly constant so it tracks well.
struct KaraokeQuote: View {
    let text: String
    let progress: Double
    let baseSize: CGFloat

    private var words: [String] { text.split(separator: " ").map(String.init) }

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                wordView(w, glow: glow(i))
            }
        }
    }

    private func glow(_ i: Int) -> Double {
        if progress >= 1 { return -1 }            // static: full bright, no pill
        let pos = progress * Double(words.count) - 0.5
        let d = pos - Double(i)
        if d > 0.85 { return -1 }                 // already read → full bright
        let g = 1 - min(abs(d) / 1.3, 1)
        return max(0, g * g * (3 - 2 * g))        // smoothstep
    }

    @ViewBuilder private func wordView(_ w: String, glow g: Double) -> some View {
        let read = g < 0
        let cream = Color(red: 0.957, green: 0.949, blue: 0.910)
        Text(w)
            .font(.system(size: baseSize, design: .serif)).italic()
            .foregroundStyle(cream.opacity(read ? 1 : 0.40 + 0.60 * g))
            .padding(.horizontal, g > 0.04 ? 6 : 0)
            .background(
                g > 0.04 ? Color(red: 0.56, green: 0.72, blue: 0.60).opacity(0.18 * g) : .clear,
                in: RoundedRectangle(cornerRadius: 8))
            .shadow(color: Color(red: 0.81, green: 0.91, blue: 0.84).opacity(0.9 * max(0, g)),
                    radius: 14 * max(0, g))
    }
}

/// Minimal flow layout (word wrap) — iOS 16 Layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW, x > 0 { x = 0; y += lineH + lineSpacing; lineH = 0 }
            x += s.width + spacing; lineH = max(lineH, s.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW, x > 0 { x = 0; y += lineH + lineSpacing; lineH = 0 }
            v.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: .unspecified)
            x += s.width + spacing; lineH = max(lineH, s.height)
        }
    }
}
