import SwiftUI
import Charts

/// Shown the moment a run ends: the whole-run verdict (one closing roast
/// from Ricky or Jessica, spoken + printed), performance, the speed/HR
/// chart, the route map + POIs passed (outdoor), and every line the runner
/// hearted — each shareable as an image or short video.
struct PostRunSummaryView: View {
    @State private var store = RunSummaryStore.shared
    @State private var share: ShareTarget?

    var body: some View {
        Group {
            if let s = store.summary {
                content(s)
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .sheet(item: $share) { target in
            RunShareComposer(target: target)
        }
    }

    @ViewBuilder
    private func content(_ s: RunSummaryStore.Summary) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                header(s)
                if s.overageMeters > 200, let g = s.planTotalMeters {
                    Text("\u{1F3C1} \(String(format: "%.1f", g/1000)) km goal smashed \u{2014} +\(String(format: "%.1f", s.overageMeters/1000)) km bonus")
                        .font(.subheadline.bold()).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(.orange.opacity(0.12), in: Capsule())
                }
                verdictCard
                statsGrid(s)
                if !s.speedSeries.isEmpty || !s.hrSeries.isEmpty { chartCard(s) }
                if s.isOutdoor, !s.trail.isEmpty || !s.plannedRoute.isEmpty { mapCard(s) }
                if !s.pois.isEmpty { poiCard(s) }
                if !s.hearted.isEmpty { heartedCard(s) }
                actionBar(s)
            }
            .padding(18)
        }
        .background(Color(red: 0.04, green: 0.05, blue: 0.05).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    // MARK: header

    private func header(_ s: RunSummaryStore.Summary) -> some View {
        HStack(spacing: 12) {
            GobletLogo().frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text("AARC").font(.headline.bold())
                Text(s.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if s.isTest {
                Text("TEST").font(.caption2.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.yellow.opacity(0.2), in: Capsule())
                    .foregroundStyle(.yellow)
            }
            Text(s.isOutdoor ? "OUTDOOR" : "TREADMILL")
                .font(.caption2.bold()).foregroundStyle(.secondary)
        }
    }

    // MARK: the closing roast

    private var verdictCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let text = store.finalRoast {
                let jess = store.finalRoastWho == "jessica"
                Text(jess ? "JESSICA" : "RICKY")
                    .font(.caption.bold())
                    .foregroundStyle(jess ? Color.pink : Color.orange)
                Text("\u{201C}\(text)\u{201D}")
                    .font(.system(.title3, design: .serif).italic())
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await Speaker.shared.playSync(
                        text: text,
                        voiceId: jess ? RemoteTTS.jessicaVoiceId : RemoteTTS.voiceId) }
                } label: {
                    Label("Play", systemImage: "play.circle.fill").font(.caption.bold())
                }.buttonStyle(.borderless).tint(jess ? .pink : .orange)
            } else if store.finalRoastFailed {
                Text("(couldn\u{2019}t reach the coach for a closing word)")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Writing the verdict\u{2026}").foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.07)))
    }

    // MARK: stats

    private func statsGrid(_ s: RunSummaryStore.Summary) -> some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible()),
                    GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: 14) {
            stat("DISTANCE", String(format: "%.2f km", s.distanceMeters / 1000))
            stat("TIME", RunSummaryStore.fmtDur(s.durationSeconds))
            stat("PACE", s.avgPaceSecPerKm > 0 ? RunSummaryStore.fmtPace(s.avgPaceSecPerKm) : "\u{2014}")
            stat("AVG HR", s.avgHR.map { "\(Int($0))" } ?? "\u{2014}")
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.title3.bold().monospacedDigit()).minimumScaleFactor(0.6).lineLimit(1)
            Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    // MARK: chart

    private func chartCard(_ s: RunSummaryStore.Summary) -> some View {
        let speed = s.speedSeries.enumerated().map { ($0.offset, $0.element) }
        let hr = s.hrSeries.enumerated().map { ($0.offset, $0.element) }
        return card("PACE & HEART RATE") {
            Chart {
                ForEach(speed, id: \.0) { i, v in
                    AreaMark(x: .value("i", i), y: .value("kmh", v))
                        .foregroundStyle(.linearGradient(
                            colors: [.orange.opacity(0.35), .orange.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom))
                }
                ForEach(speed, id: \.0) { i, v in
                    LineMark(x: .value("i", i), y: .value("kmh", v), series: .value("s", "speed"))
                        .foregroundStyle(.orange)
                }
                ForEach(hr, id: \.0) { i, v in
                    LineMark(x: .value("i", i), y: .value("hr", v), series: .value("s", "hr"))
                        .foregroundStyle(.red.opacity(0.8))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 150)
        }
    }

    // MARK: map

    private func mapCard(_ s: RunSummaryStore.Summary) -> some View {
        card("ROUTE") {
            VStack(alignment: .leading, spacing: 8) {
                RunMapView(trail: s.trail, current: s.trail.last,
                           pois: s.pois, plannedRoute: s.plannedRoute, follow: false)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                if let route = s.routeDescription {
                    Text(route).font(.caption).foregroundStyle(.teal)
                }
            }
        }
    }

    private func poiCard(_ s: RunSummaryStore.Summary) -> some View {
        card("PASSED ALONG THE WAY") {
            VStack(spacing: 7) {
                ForEach(s.pois.prefix(6)) { poi in
                    HStack(spacing: 9) {
                        Image(systemName: poi.symbol)
                            .foregroundStyle(poi.isHotel ? .pink : .teal).frame(width: 18)
                        Text(poi.name).font(.subheadline)
                        Spacer()
                        Text("\(poi.meters)m").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: hearted

    private func heartedCard(_ s: RunSummaryStore.Summary) -> some View {
        card("\u{2665} LINES YOU HEARTED") {
            VStack(spacing: 12) {
                ForEach(s.hearted) { line in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(line.who.uppercased())
                                .font(.caption2.bold())
                                .foregroundStyle(line.who == "jessica" ? .pink : .orange)
                            Text(line.text).font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button { share = .heartedLine(line) } label: {
                            Image(systemName: "square.and.arrow.up").font(.callout)
                        }.buttonStyle(.borderless).tint(.orange)
                    }
                }
            }
        }
    }

    // MARK: actions

    private func actionBar(_ s: RunSummaryStore.Summary) -> some View {
        VStack(spacing: 10) {
            Button { share = .wholeRun } label: {
                Label("Share this run", systemImage: "square.and.arrow.up")
                    .font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.orange).controlSize(.large)
            Button("Done") { store.dismiss() }
                .font(.headline).tint(.secondary)
        }
        .padding(.top, 4)
    }

    private func card(_ title: String, @ViewBuilder _ body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            body()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.07)))
    }
}

/// What the share composer is building from.
enum ShareTarget: Identifiable {
    case wholeRun
    case heartedLine(RunSummaryStore.HeartedLine)
    var id: String {
        switch self {
        case .wholeRun: return "run"
        case .heartedLine(let l): return l.id.uuidString
        }
    }
}
