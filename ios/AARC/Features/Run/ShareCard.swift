import SwiftUI
import Charts
import UIKit

extension String {
    /// Strip ElevenLabs audio tags ([moans], [breathy], …) for DISPLAY only —
    /// the spoken text keeps them so v3 still performs the sounds.
    var strippingAudioTags: String {
        replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Data for one share card — built from a whole run or a single hearted line.
struct ShareCardModel {
    var date: String
    var kpis: [(label: String, value: String)]
    var speed: [Double]
    var hr: [Double]
    var quote: String
    var who: String        // "ricky" | "jessica" | ""
    var heardAtKm: Double?  // "HEARD AT KM x" stamp, when known
    var aspect: CGFloat    // width / height (0.8 portrait, 1 square)
    // Route layout (outdoor): a baked base-map image + colored trail segments
    // in that image's pixel space. When set, the card shows the map as the
    // hero and draws the trail up to `progress` (so the video animates it).
    var mapImage: UIImage? = nil
    var mapSegments: [ShareMap.Segment] = []
    var mapStart: CGPoint? = nil
    var mapFinish: CGPoint? = nil

    static let portrait: CGFloat = 1080.0 / 1350.0
    static let square: CGFloat = 1.0
}

/// The shareable card. A faithful port of the web dashboard's quote layout
/// (proxy/src/routes/dashboardApp.ts → drawLayoutQuoteFirst): pub-green wash,
/// goblet logo + aarun.club, the quote as the centred serif hero (shrunk to
/// fit, exactly like the web's layoutQuote loop), a "heard at km" stamp, a
/// compact pace/HR strip, KPI row, footer. `progress` drives the word-by-word
/// karaoke highlight during video; 1 = static image.
struct ShareCardView: View {
    let model: ShareCardModel
    var progress: Double = 1

    // 1080-wide logical canvas, matching the web exactly.
    private let W: CGFloat = 1080
    private var H: CGFloat { (W / model.aspect).rounded() }
    private let P: CGFloat = 76
    private let cream = Color(red: 0.957, green: 0.949, blue: 0.910)
    private let dim = Color(red: 0.46, green: 0.51, blue: 0.44)
    private let urlGreen = Color(red: 0.62, green: 0.72, blue: 0.65)

    // Web layout Y-anchors (drawLayoutQuoteFirst), reproduced 1:1.
    private var topY: CGFloat { P + 74 }
    private var kpiY: CGFloat { H - 240 }
    private var graphH: CGFloat { H > 1200 ? 110 : 92 }
    private var graphTop: CGFloat { kpiY - 56 - graphH }
    private var stampY: CGFloat { graphTop - 48 }
    private var quoteTop: CGFloat { topY + 56 }
    private var quoteBottom: CGFloat { stampY - 60 }

    var body: some View {
        if model.mapImage != nil { routeBody } else { quoteBody }
    }

    // MARK: - Route layout (outdoor): map hero + trail + compact quote

    private var routeBody: some View {
        // Compact map (rounded), quote gets the bulk, KPIs pinned above the
        // footer with a clear gap — no overlap.
        let mapTop = topY + 20
        let mapH = model.mapImage!.size.height
        let mapBot = mapTop + mapH
        let footY = H - 56
        let kpiTop = footY - 96
        let qTop = mapBot + 40
        let qBot = kpiTop - 36
        let q = "\u{201C}\(model.quote)\u{201D}"
        return ZStack(alignment: .topLeading) {
            background
            header
            ZStack(alignment: .topLeading) {
                Image(uiImage: model.mapImage!).resizable().frame(width: W - P * 2, height: mapH)
                Canvas { ctx, _ in
                    let upto = max(1, Int(Double(model.mapSegments.count) * min(progress, 1)))
                    for i in 0..<min(upto, model.mapSegments.count) {
                        let s = model.mapSegments[i]
                        var p = Path(); p.move(to: s.a); p.addLine(to: s.b)
                        ctx.stroke(p, with: .color(s.color), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    }
                    if let st = model.mapStart {
                        ctx.fill(Path(ellipseIn: CGRect(x: st.x - 8, y: st.y - 8, width: 16, height: 16)),
                                 with: .color(Color(red: 0.81, green: 0.91, blue: 0.84)))
                    }
                }
                .frame(width: W - P * 2, height: mapH)
            }
            .frame(width: W - P * 2, height: mapH)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .position(x: W / 2, y: mapTop + mapH / 2)

            // quote — fitted strictly into the gap between map and KPIs
            KaraokeQuote(text: q, progress: progress,
                         fontSize: ShareCardView.fittedSerifSize(q, boxW: (W - P * 2) * 0.86,
                                                                 boxH: qBot - qTop, maxSize: H > 1200 ? 58 : 48))
                .frame(width: W - P * 2, height: qBot - qTop)
                .position(x: W / 2, y: (qTop + qBot) / 2)

            kpiRow.frame(width: W - P * 2).position(x: W / 2, y: kpiTop + 30)
            footer
        }
        .frame(width: W, height: H)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Quote layout (default / treadmill)

    private var quoteBody: some View {
        ZStack(alignment: .topLeading) {
            background
            header
            quoteBlock
            if let km = model.heardAtKm {
                Text("\u{2014}  HEARD AT KM \(km == km.rounded() ? String(Int(km)) : String(format: "%.1f", km))  \u{2014}")
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(urlGreen)
                    .frame(width: W - P * 2)
                    .position(x: W / 2, y: stampY)
            }
            chartStrip
                .frame(width: W - P * 2, height: graphH)
                .position(x: W / 2, y: graphTop + graphH / 2)
            kpiRow
                .frame(width: W - P * 2)
                .position(x: W / 2, y: kpiY + 30)
            footer
        }
        .frame(width: W, height: H)
        .environment(\.colorScheme, .dark)
    }

    private var background: some View {
        ZStack {
            Color(red: 0.043, green: 0.055, blue: 0.047)
            RadialGradient(colors: [Color(red: 0.29, green: 0.39, blue: 0.31).opacity(0.55), .clear],
                           center: .init(x: 0.16, y: -0.05), startRadius: 30, endRadius: W)
        }
        .frame(width: W, height: H)
    }

    private var header: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 16) {
                GobletLogo().frame(width: 60, height: 60)
                Text("AARC").font(.system(size: 40, weight: .heavy)).foregroundStyle(cream)
            }
            .position(x: P + 130, y: P + 18)
            VStack(alignment: .trailing, spacing: 3) {
                Text("aarun.club").font(.system(size: 24, weight: .bold)).foregroundStyle(urlGreen)
                if !model.date.isEmpty {
                    Text(model.date).font(.system(size: 18)).foregroundStyle(dim)
                }
            }
            .position(x: W - P - 70, y: P + 22)
            Rectangle().fill(cream.opacity(0.10)).frame(width: W - P * 2, height: 1.5)
                .position(x: W / 2, y: topY)
        }
        .frame(width: W, height: H, alignment: .topLeading)
    }

    private var quoteBlock: some View {
        let boxW = W - P * 2
        let boxH = quoteBottom - quoteTop
        // Measure against a tighter width — the karaoke flow adds per-word
        // padding + inter-word spacing the plain bounding-rect doesn't model,
        // so this keeps the fitted size conservative (no vertical clipping).
        let size = Self.fittedSerifSize("\u{201C}\(model.quote)\u{201D}",
                                        boxW: boxW * 0.86, boxH: boxH,
                                        maxSize: H > 1200 ? 80 : 64)
        return KaraokeQuote(text: "\u{201C}\(model.quote)\u{201D}", progress: progress, fontSize: size)
            .frame(width: boxW, height: boxH)
            .position(x: W / 2, y: (quoteTop + quoteBottom) / 2)
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
                        .foregroundStyle(Color(red: 0.66, green: 0.78, blue: 0.69)).lineStyle(.init(lineWidth: 3))
                }
                ForEach(hr, id: \.0) { i, v in
                    LineMark(x: .value("i", i), y: .value("hr", v), series: .value("s", "h"))
                        .foregroundStyle(Color(red: 0.83, green: 0.46, blue: 0.42)).lineStyle(.init(lineWidth: 2.5))
                }
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
        }
    }

    private var kpiRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(model.kpis.enumerated()), id: \.offset) { i, kpi in
                VStack(spacing: 6) {
                    Text(kpi.value).font(.system(size: 42, weight: .heavy)).monospacedDigit()
                        .foregroundStyle(cream).minimumScaleFactor(0.5).lineLimit(1)
                    Text(kpi.label.uppercased()).font(.system(size: 16, weight: .bold)).foregroundStyle(dim)
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    if i > 0 { Rectangle().fill(cream.opacity(0.08)).frame(width: 1, height: 56) }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("An AI running coach that talks back.").font(.system(size: 20)).foregroundStyle(dim)
            Spacer()
            Text("aarun.club").font(.system(size: 20, weight: .bold)).foregroundStyle(urlGreen)
        }
        .frame(width: W - P * 2)
        .position(x: W / 2, y: H - 56)
    }

    /// Mirror of the web's layoutQuote: largest Georgia-italic size at which
    /// the wrapped quote fits the box. Measured with UIKit so it matches the
    /// rendered wrapping.
    static func fittedSerifSize(_ text: String, boxW: CGFloat, boxH: CGFloat, maxSize: CGFloat) -> CGFloat {
        var size = maxSize
        while size >= 26 {
            let font = UIFont(name: "Georgia-Italic", size: size) ?? .italicSystemFont(ofSize: size)
            let r = (text as NSString).boundingRect(
                with: CGSize(width: boxW, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font], context: nil)
            if r.height <= boxH { return size }
            size -= 2
        }
        return 26
    }
}

/// Serif quote whose words light up in sequence during video — full-bright
/// once spoken, a glowing pill while being spoken, dim before. Lines centred.
struct KaraokeQuote: View {
    let text: String
    let progress: Double
    let fontSize: CGFloat

    private var words: [String] { text.split(separator: " ").map(String.init) }

    var body: some View {
        FlowLayout(spacing: 0.28 * fontSize, lineSpacing: 0.30 * fontSize, alignment: .center) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                wordView(w, glow: glow(i))
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func glow(_ i: Int) -> Double {
        if progress >= 1 { return -1 }
        let pos = progress * Double(words.count) - 0.5
        let d = pos - Double(i)
        if d > 0.85 { return -1 }
        let g = 1 - min(abs(d) / 1.3, 1)
        return max(0, g * g * (3 - 2 * g))
    }

    @ViewBuilder private func wordView(_ w: String, glow g: Double) -> some View {
        let read = g < 0
        let lit = max(0, g)
        let cream = Color(red: 0.957, green: 0.949, blue: 0.910)
        // CONSTANT padding for every word so the highlight pill can fade in
        // without changing the word's width — otherwise the whole paragraph
        // reflows and "dances" as the highlight sweeps across. Only opacity,
        // fill and shadow animate; layout (size, weight, spacing) is fixed.
        Text(w)
            .font(.custom("Georgia-Italic", size: fontSize))
            .foregroundStyle(cream.opacity(read ? 1 : 0.40 + 0.60 * g))
            .padding(.horizontal, 0.08 * fontSize)
            .padding(.vertical, 0.02 * fontSize)
            .background(Color(red: 0.56, green: 0.72, blue: 0.60).opacity(0.20 * lit),
                        in: RoundedRectangle(cornerRadius: 8))
            .shadow(color: Color(red: 0.81, green: 0.91, blue: 0.84).opacity(0.9 * lit),
                    radius: 14 * lit)
    }
}

/// Minimal flow layout (word wrap) with optional per-line centring.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        let lines = wrap(subviews, maxW: maxW)
        let h = lines.reduce(0) { $0 + $1.height } + CGFloat(max(0, lines.count - 1)) * lineSpacing
        return CGSize(width: maxW == .infinity ? (lines.map(\.width).max() ?? 0) : maxW, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lines = wrap(subviews, maxW: bounds.width)
        var y = bounds.minY
        for line in lines {
            var x = bounds.minX + (alignment == .center ? (bounds.width - line.width) / 2 : 0)
            for item in line.items {
                let s = subviews[item].sizeThatFits(.unspecified)
                subviews[item].place(at: CGPoint(x: x, y: y + (line.height - s.height) / 2), proposal: .unspecified)
                x += s.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }
    private func wrap(_ subviews: Subviews, maxW: CGFloat) -> [Line] {
        var lines: [Line] = []; var cur = Line()
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            if cur.width + s.width > maxW, !cur.items.isEmpty {
                lines.append(cur); cur = Line()
            }
            cur.items.append(i); cur.width += s.width + spacing; cur.height = max(cur.height, s.height)
        }
        if !cur.items.isEmpty { lines.append(cur) }
        return lines
    }
}
