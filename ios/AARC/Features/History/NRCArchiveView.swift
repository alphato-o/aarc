import SwiftUI
import SwiftData
import AARCKit

/// Aggregated stats for a set of runs — powers the year/month summaries in the
/// NRC archive browser (founder ask: "give me highlights of that year — km,
/// races, cities, outdoor/indoor").
struct RunAggregate {
    var count = 0
    var totalMeters: Double = 0
    var races = 0            // half + full marathons only
    var outdoor = 0
    var indoor = 0
    var cities: [String] = []

    var km: Double { totalMeters / 1000 }

    init(_ runs: [RunRecord]) {
        var citySet = Set<String>()
        for r in runs {
            count += 1
            totalMeters += r.cachedDistanceMeters
            if r.runTypeRaw == "treadmill" { indoor += 1 } else { outdoor += 1 }
            if let c = r.city, !c.isEmpty { citySet.insert(c) }
            if Self.isRace(r.cachedDistanceMeters) { races += 1 }
        }
        // Order cities by frequency for a stable, meaningful display.
        let counts = Dictionary(grouping: runs.compactMap { $0.city }, by: { $0 }).mapValues(\.count)
        cities = citySet.sorted { (counts[$0] ?? 0, $1) > (counts[$1] ?? 0, $0) }
    }

    /// A race = a half (21.0975 km) or full (42.195 km) marathon, within ±10%
    /// to absorb GPS drift. Training runs (even long ones under ~19 km) don't count.
    static func isRace(_ meters: Double) -> Bool {
        let km = meters / 1000
        let half = abs(km - 21.0975) <= 21.0975 * 0.10
        let full = abs(km - 42.195) <= 42.195 * 0.10
        return half || full
    }
}

/// The NRC archive browser: an iOS-Photos-style Year → Month drill-down over
/// the imported Nike history, with aggregated highlights at each level.
struct NRCArchiveView: View {
    let runs: [RunRecord]   // already source=="nike", newest-first

    private var byYear: [(year: Int, runs: [RunRecord])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: runs) { cal.component(.year, from: $0.startedAt) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                overallHeader
                ForEach(byYear, id: \.year) { g in
                    NavigationLink {
                        NRCYearView(year: g.year, runs: g.runs)
                    } label: {
                        YearCard(year: g.year, agg: RunAggregate(g.runs))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    private var overallHeader: some View {
        let a = RunAggregate(runs)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Nike Run Club archive")
                .font(.headline)
            HStack(spacing: 14) {
                stat("\(a.count)", "runs")
                stat(String(format: "%.0f", a.km), "km")
                stat("\(a.races)", "races")
                stat("\(a.cities.count)", "cities")
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 2)
    }

    private func stat(_ v: String, _ l: String) -> some View {
        HStack(spacing: 4) {
            Text(v).font(.subheadline.bold().monospacedDigit()).foregroundStyle(.primary)
            Text(l).font(.caption)
        }
    }
}

/// A tappable year summary card (Level 1 of the browse).
struct YearCard: View {
    let year: Int
    let agg: RunAggregate

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(year)).font(.title2.bold())
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            HStack(spacing: 16) {
                metric(String(format: "%.0f", agg.km), "km", "ruler")
                metric("\(agg.count)", "runs", "figure.run")
                if agg.races > 0 { metric("\(agg.races)", agg.races == 1 ? "race" : "races", "medal") }
                metric("\(agg.outdoor)/\(agg.indoor)", "out/in", "map")
            }
            if !agg.cities.isEmpty {
                Text(agg.cities.prefix(4).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private func metric(_ v: String, _ l: String, _ icon: String) -> some View {
        VStack(spacing: 2) {
            Label(v, systemImage: icon).font(.subheadline.bold().monospacedDigit())
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Level 2: one year, runs grouped by month with a year summary header and
/// per-month mini stats.
struct NRCYearView: View {
    let year: Int
    let runs: [RunRecord]

    private var byMonth: [(month: Int, runs: [RunRecord])] {
        let cal = Calendar.current
        let g = Dictionary(grouping: runs) { cal.component(.month, from: $0.startedAt) }
        return g.keys.sorted(by: >).map { ($0, g[$0]!.sorted { $0.startedAt > $1.startedAt }) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                yearSummary
                ForEach(byMonth, id: \.month) { m in
                    Section {
                        ForEach(m.runs) { run in
                            NavigationLink { RunDetailView(run: run) } label: {
                                RunListRow(run: run)
                            }
                            .buttonStyle(.plain)
                            Divider().opacity(0.2)
                        }
                    } header: {
                        monthHeader(month: m.month, agg: RunAggregate(m.runs))
                    }
                }
            }
            .padding(.horizontal)
        }
        .navigationTitle(String(year))
        .navigationBarTitleDisplayMode(.large)
    }

    private var yearSummary: some View {
        let a = RunAggregate(runs)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                bigStat(String(format: "%.0f", a.km), "km")
                bigStat("\(a.count)", "runs")
                bigStat("\(a.races)", a.races == 1 ? "race" : "races")
                bigStat("\(a.outdoor)/\(a.indoor)", "out/in")
            }
            if !a.cities.isEmpty {
                Label(a.cities.joined(separator: " · "), systemImage: "mappin.and.ellipse")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 8)
    }

    private func monthHeader(month: Int, agg: RunAggregate) -> some View {
        HStack(spacing: 6) {
            Text(DateFormatter().monthSymbols[month - 1])
                .font(.headline)
            Spacer()
            Text("\(agg.count) · \(String(format: "%.0f", agg.km)) km")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if agg.races > 0 {
                Label("\(agg.races)", systemImage: "medal")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private func bigStat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.title3.bold().monospacedDigit())
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
