import SwiftUI

struct WatchChartSample: Identifiable {
    let id = UUID()
    let hr: Double?    // bpm
    let kmh: Double?   // speed
}

/// In-run "Chart" page: a compact live trend — red HR line over green speed
/// bars, with a pulsing "you are here" dot at the latest sample. Two glance
/// numbers up top (elapsed + live HR). Same view indoor and outdoor.
struct WatchChartPage: View {
    let samples: [WatchChartSample]
    let elapsed: TimeInterval
    let currentHR: Double?
    let distanceMeters: Double

    private let hrColor = Color.red
    private let speedColor = Color(red: 0.36, green: 0.85, blue: 0.50)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header: elapsed (yellow) + live HR (red)
            HStack {
                Text(formatElapsed(elapsed))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.98, green: 0.83, blue: 0.18))
                    .monospacedDigit()
                Spacer()
                if let hr = currentHR, hr > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "heart.fill").font(.system(size: 11)).foregroundStyle(hrColor)
                        Text("\(Int(hr))")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white).monospacedDigit()
                    }
                }
            }

            chart
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // x-axis: distance
            HStack {
                Text("0").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Text(formatDistance(distanceMeters))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var chart: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { tl in
            Canvas { ctx, size in
                draw(&ctx, size: size, now: tl.date)
            }
        }
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, now: Date) {
        guard samples.count > 1 else {
            let p = Text("warming up\u{2026}").font(.system(size: 12)).foregroundColor(.secondary)
            ctx.draw(p, at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let n = samples.count
        let pad: CGFloat = 2
        let w = size.width - pad * 2, h = size.height - pad * 2
        func x(_ i: Int) -> CGFloat { pad + w * CGFloat(i) / CGFloat(max(1, n - 1)) }

        // Speed bars (green), normalized to their own range.
        let speeds = samples.map { $0.kmh ?? 0 }
        let sMax = max(speeds.max() ?? 1, 0.1)
        let barW = max(1.0, w / CGFloat(n) - 1)
        for (i, sp) in speeds.enumerated() where sp > 0 {
            let bh = h * 0.92 * CGFloat(sp / sMax)
            let rect = CGRect(x: x(i) - barW / 2, y: pad + h - bh, width: barW, height: bh)
            ctx.fill(Path(roundedRect: rect, cornerRadius: barW * 0.4),
                     with: .color(speedColor.opacity(0.55)))
        }

        // HR line (red), normalized to a padded HR range.
        let hrs = samples.compactMap { $0.hr }.filter { $0 > 0 }
        if hrs.count > 1 {
            let lo = (hrs.min() ?? 60) - 6, hi = (hrs.max() ?? 180) + 6
            let span = max(1, hi - lo)
            func y(_ v: Double) -> CGFloat { pad + h - h * 0.92 * CGFloat((v - lo) / span) }
            var path = Path()
            var started = false
            var lastPoint = CGPoint.zero
            for (i, s) in samples.enumerated() {
                guard let v = s.hr, v > 0 else { continue }
                let pt = CGPoint(x: x(i), y: y(v))
                if started { path.addLine(to: pt) } else { path.move(to: pt); started = true }
                lastPoint = pt
            }
            ctx.stroke(path, with: .color(hrColor), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

            // Pulsing "you are here" dot at the latest HR sample.
            let t = now.timeIntervalSinceReferenceDate
            let pulse = 0.5 + 0.5 * sin(t * 3.2)
            let r = 3.5 + 2.5 * pulse
            ctx.fill(Path(ellipseIn: CGRect(x: lastPoint.x - r, y: lastPoint.y - r, width: r * 2, height: r * 2)),
                     with: .color(.white.opacity(0.25 + 0.4 * pulse)))
            ctx.fill(Path(ellipseIn: CGRect(x: lastPoint.x - 3, y: lastPoint.y - 3, width: 6, height: 6)),
                     with: .color(hrColor))
            ctx.stroke(Path(ellipseIn: CGRect(x: lastPoint.x - 3, y: lastPoint.y - 3, width: 6, height: 6)),
                       with: .color(.white), lineWidth: 1)
        }
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let s = Int(seconds), h = Int(seconds) / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    private func formatDistance(_ m: Double) -> String {
        m >= 1000 ? String(format: "%.2f km", m / 1000) : String(format: "%.0f m", m)
    }
}

#Preview {
    WatchChartPage(samples: WatchPreviewGallery.mockSamples,
                   elapsed: 1458, currentHR: 152, distanceMeters: 2410)
}
