import SwiftUI
import Charts

/// The post-run summary's speed + HR chart, as a standalone production view so
/// it can be snapshot-rendered in isolation (the visual harness) WITHOUT
/// drift — the harness screenshots this exact component, not a copy.
///
/// Each series is normalized to its own 0…1 range (SeriesNormalize) and shown
/// on a shared, hidden 0…1 axis — so speed (~10 km/h) and HR (~150 bpm) coexist
/// without HR crushing the speed line flat. Matches the History chart.
struct SummaryTelemetryChart: View {
    let speedSeries: [Double]
    let hrSeries: [Double]

    var body: some View {
        let speedR = SeriesNormalize.range(speedSeries)
        let hrR = SeriesNormalize.range(hrSeries)
        let speed = speedSeries.enumerated().map { ($0.offset, SeriesNormalize.unit($0.element, in: speedR)) }
        let hr = hrSeries.enumerated().map { ($0.offset, SeriesNormalize.unit($0.element, in: hrR)) }
        return Chart {
            ForEach(speed, id: \.0) { i, v in
                AreaMark(x: .value("i", i), y: .value("speed", v))
                    .foregroundStyle(.linearGradient(
                        colors: [.orange.opacity(0.35), .orange.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
            }
            ForEach(speed, id: \.0) { i, v in
                LineMark(x: .value("i", i), y: .value("speed", v), series: .value("s", "speed"))
                    .foregroundStyle(.orange)
            }
            ForEach(hr, id: \.0) { i, v in
                LineMark(x: .value("i", i), y: .value("hr", v), series: .value("s", "hr"))
                    .foregroundStyle(.red.opacity(0.8))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...1)
        .frame(height: 150)
    }
}
