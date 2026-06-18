import SwiftUI
import UIKit
import Charts

/// Dev-only VISUAL harness: render real summary screens to PNGs with controlled
/// data, headless, so a layout/chart bug is EYEBALLABLE (by the agent pulling
/// the PNG, and the founder) without driving the GUI or going to the gym. Same
/// env-gate pattern as ShareCardPreviewHarness.
///
/// `AARC_SUMMARY_SNAP=1` at launch → writes PNGs to <Documents>/, then the run
/// exits. Pull with `xcrun simctl get_app_container booted <bundleid> data`.
@MainActor
enum SummarySnapshotHarness {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["AARC_SUMMARY_SNAP"] == "1"
    }

    static func run() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // The exact bug shape: treadmill run, speed ~9-12 km/h, HR ~140-165 bpm.
        // 100m buckets over ~3 km.
        let n = 30
        let speed = (0..<n).map { 10.0 + 2.0 * sin(Double($0) / 4) }          // ~8-12 km/h
        let hr = (0..<n).map { 150.0 + 12.0 * sin(Double($0) / 6 + 1) }       // ~138-162 bpm

        // The FIXED component (per-series normalized).
        snap(SummaryTelemetryChart(speedSeries: speed, hrSeries: hr)
                .frame(width: 360, height: 150).padding().background(Color.black),
             to: dir.appendingPathComponent("summary-chart-fixed.png"))

        // For contrast: the OLD raw co-scaled rendering (speed crushed by HR on
        // one axis) — so the before/after is visible side by side.
        snap(RawCoScaledChart(speed: speed, hr: hr)
                .frame(width: 360, height: 150).padding().background(Color.black),
             to: dir.appendingPathComponent("summary-chart-OLD-broken.png"))

        NSLog("AARC_SUMMARY_SNAP wrote chart PNGs to \(dir.path)")
    }

    private static func snap(_ view: some View, to url: URL) {
        let r = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        r.scale = 2
        if let img = r.uiImage, let data = img.pngData() { try? data.write(to: url) }
    }
}

/// Reproduction of the PRE-FIX chart: raw speed + raw HR on one shared axis.
/// Lives only in the harness, purely to render the "before" for comparison.
private struct RawCoScaledChart: View {
    let speed: [Double]
    let hr: [Double]
    var body: some View {
        Chart {
            ForEach(Array(speed.enumerated()), id: \.offset) { i, v in
                LineMark(x: .value("i", i), y: .value("v", v), series: .value("s", "speed"))
                    .foregroundStyle(.orange)
            }
            ForEach(Array(hr.enumerated()), id: \.offset) { i, v in
                LineMark(x: .value("i", i), y: .value("v", v), series: .value("s", "hr"))
                    .foregroundStyle(.red.opacity(0.8))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks(position: .leading) }
        .frame(height: 150)
    }
}
