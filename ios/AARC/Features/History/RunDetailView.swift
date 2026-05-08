import SwiftUI
import SwiftData
import Charts
import MapKit
import HealthKit
import CoreLocation
import AARCKit

struct RunDetailView: View {
    let run: RunRecord

    @State private var hrSeries: [HealthKitReader.SeriesPoint] = []
    @State private var paceSeries: [HealthKitReader.SeriesPoint] = []
    @State private var routeCoords: [CLLocationCoordinate2D] = []
    @State private var isLoading = true
    @State private var loadError: String?

    @State private var showHR = true
    @State private var showPace = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                titleSection
                if run.isTestData { testBanner }
                statsGrid
                if run.runTypeRaw == "outdoor" {
                    mapSection
                }
                chartSection
                if isLoading { loadingHint }
                if let loadError {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding()
        }
        .navigationTitle("Run")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadData() }
    }

    // MARK: - Sections

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(RunTitleGenerator.title(
                forRunId: run.id,
                runType: RunType(rawValue: run.runTypeRaw) ?? .outdoor
            ))
                .font(.title3.bold())
                .lineLimit(2)
            Text(run.startedAt, format: .dateTime.weekday(.wide).month(.wide).day().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var testBanner: some View {
        Label("Test data — tagged in Apple Health for cleanup", systemImage: "flask.fill")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [.orange, .pink], startPoint: .leading, endPoint: .trailing))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statsGrid: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: 12) {
            statTile("Distance", value: formatDistance(run.cachedDistanceMeters), system: "ruler")
            statTile("Duration", value: formatDuration(run.cachedDurationSeconds), system: "stopwatch")
            statTile("Avg Pace", value: formatPace(run.cachedAvgPaceSecPerKm), system: "speedometer")
            statTile("Energy", value: "\(Int(run.cachedEnergyKcal)) kcal", system: "flame")
            statTile("Mode", value: run.runTypeRaw.capitalized, system: run.runTypeRaw == "treadmill" ? "figure.run.treadmill" : "figure.run")
            statTile("Personality", value: run.personality.replacingOccurrences(of: "_", with: " ").capitalized, system: "person.wave.2")
        }
    }

    private var mapSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Route")
                .font(.subheadline.bold())
            if routeCoords.count >= 2 {
                Map {
                    MapPolyline(coordinates: routeCoords)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if isLoading {
                placeholderBox(text: "Loading route…", height: 100)
            } else {
                placeholderBox(text: "No route data for this workout.", height: 80)
            }
        }
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Telemetry").font(.subheadline.bold())
                Spacer()
                legendChip("HR", color: .red,
                           range: hrRangeLabel,
                           isOn: $showHR, available: !hrSeries.isEmpty)
                legendChip("Pace", color: .blue,
                           range: paceRangeLabel,
                           isOn: $showPace, available: !paceSeries.isEmpty)
            }

            if hrSeries.isEmpty && paceSeries.isEmpty && !isLoading {
                placeholderBox(text: "No telemetry available for this run.", height: 80)
            } else {
                overlayChart
            }
        }
    }

    /// Single chart with both lines overlaid. Each series is normalized
    /// to [0, 1] so they share a common Y axis even though their natural
    /// units (bpm vs sec/km) are unrelated. Pace is also inverted so up =
    /// faster. The legend chips above show absolute ranges; the chart
    /// itself shows shape and timing.
    private var overlayChart: some View {
        Chart {
            if showHR {
                ForEach(hrSeries) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Normalized", normalize(point.value, range: hrRange)),
                        series: .value("Series", "HR")
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.red)
                }
            }
            if showPace {
                ForEach(paceSeries) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        // Invert: smaller pace value (faster) → higher line.
                        y: .value("Normalized", 1 - normalize(point.value, range: paceRange)),
                        series: .value("Series", "Pace")
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.blue)
                }
            }
        }
        .chartLegend(.hidden)
        .chartYAxis(.hidden)
        .chartXAxis {
            // Let Swift Charts pick a sensible stride based on the
            // actual data range — fixed strides break short test runs.
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisTick()
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        Text(date, format: .dateTime.hour().minute())
                    }
                }
            }
        }
        .chartYScale(domain: 0...1)
        .frame(height: 180)
    }

    // MARK: - Series ranges (computed for normalisation + legends)

    private var hrRange: (min: Double, max: Double) {
        let values = hrSeries.map(\.value)
        return (values.min() ?? 0, values.max() ?? 1)
    }

    private var paceRange: (min: Double, max: Double) {
        let values = paceSeries.map(\.value)
        return (values.min() ?? 0, values.max() ?? 1)
    }

    private var hrRangeLabel: String {
        guard !hrSeries.isEmpty else { return "—" }
        return "\(Int(hrRange.min))–\(Int(hrRange.max)) bpm"
    }

    private var paceRangeLabel: String {
        guard !paceSeries.isEmpty else { return "—" }
        return "\(formatPaceShort(paceRange.min))–\(formatPaceShort(paceRange.max)) /km"
    }

    private func normalize(_ value: Double, range: (min: Double, max: Double)) -> Double {
        let span = range.max - range.min
        guard span > 0.0001 else { return 0.5 }
        return (value - range.min) / span
    }

    private var loadingHint: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Loading telemetry…").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func statTile(_ label: String, value: String, system: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: system)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func legendChip(_ label: String, color: Color, range: String, isOn: Binding<Bool>, available: Bool) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(isOn.wrappedValue ? color : .gray.opacity(0.5))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text(label).font(.caption.bold())
                    Text(range).font(.caption2).foregroundStyle(.secondary)
                }
                .strikethrough(!isOn.wrappedValue, color: .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isOn.wrappedValue ? color.opacity(0.2) : .gray.opacity(0.12),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.4)
    }

    private func formatPaceShort(_ secPerKm: Double) -> String {
        guard secPerKm.isFinite, secPerKm > 0 else { return "—" }
        let m = Int(secPerKm) / 60
        let r = Int(secPerKm) % 60
        return String(format: "%d:%02d", m, r)
    }

    @ViewBuilder
    private func placeholderBox(text: String, height: CGFloat) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func formatDistance(_ meters: Double) -> String {
        meters >= 1000
            ? String(format: "%.2f km", meters / 1000)
            : String(format: "%.0f m", meters)
    }

    private func formatDuration(_ s: Double) -> String {
        let total = Int(s)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    private func formatPace(_ secPerKm: Double) -> String {
        guard secPerKm.isFinite, secPerKm > 0 else { return "—" }
        let m = Int(secPerKm) / 60
        let r = Int(secPerKm) % 60
        return String(format: "%d:%02d /km", m, r)
    }

    // MARK: - Loading

    private func loadData() async {
        guard let uuid = run.healthKitWorkoutUUID else {
            isLoading = false
            return
        }
        do {
            guard let workout = try await HealthKitReader.shared.fetchWorkout(uuid: uuid) else {
                isLoading = false
                loadError = "Workout not yet synced from watch."
                return
            }
            async let hr = HealthKitReader.shared.fetchHeartRateSeries(during: workout)
            async let pace = HealthKitReader.shared.fetchPaceSeries(during: workout)
            async let route = HealthKitReader.shared.fetchRoute(for: workout)
            let (hrPoints, pacePoints, locations) = try await (hr, pace, route)

            self.hrSeries = hrPoints
            self.paceSeries = pacePoints
            self.routeCoords = locations.map(\.coordinate)
            self.isLoading = false
        } catch {
            self.loadError = error.localizedDescription
            self.isLoading = false
        }
    }
}
