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
                startedAt: run.startedAt,
                runType: RunType(rawValue: run.runTypeRaw) ?? .outdoor
            ))
                .font(.title3.bold())
                .lineLimit(3)
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
            HStack {
                Text("Telemetry")
                    .font(.subheadline.bold())
                Spacer()
                seriesToggle("HR", color: .red, isOn: $showHR, available: !hrSeries.isEmpty)
                seriesToggle("Pace", color: .blue, isOn: $showPace, available: !paceSeries.isEmpty)
            }

            if showHR && !hrSeries.isEmpty {
                hrChart
            }

            if showPace && !paceSeries.isEmpty {
                paceChart
            }

            if hrSeries.isEmpty && paceSeries.isEmpty && !isLoading {
                placeholderBox(text: "No telemetry available for this run.", height: 80)
            }
        }
    }

    @ViewBuilder
    private var hrChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Heart rate")
                .font(.caption)
                .foregroundStyle(.secondary)
            Chart(hrSeries) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("BPM", point.value)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.red)
            }
            .chartYAxisLabel("bpm")
            .frame(height: 140)
        }
    }

    @ViewBuilder
    private var paceChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pace (sec / km)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Chart(paceSeries) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Pace", point.value)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.blue)
            }
            // Lower number = faster pace; invert axis so up = faster.
            .chartYScale(domain: .automatic(includesZero: false, reversed: true))
            .frame(height: 140)
        }
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
    private func seriesToggle(_ label: String, color: Color, isOn: Binding<Bool>, available: Bool) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label).font(.caption)
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
