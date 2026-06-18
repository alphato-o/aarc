import Testing
import Foundation
@testable import AARC

/// Harness B — the post-run summary chart bug: speed (~10 km/h) and HR (~150
/// bpm) were co-plotted RAW on one auto-scaled Y axis, so HR set the scale and
/// the speed line rendered "almost zero." Fix: normalize each series to its own
/// 0…1 range (SeriesNormalize), matching the History chart. These lock the
/// property the fix relies on — two wildly different-magnitude series must EACH
/// keep their full dynamic range when co-plotted.
@Suite("Summary chart scaling")
struct ChartScalingHarness {

    @Test("a small-magnitude series keeps full range alongside a large one")
    func speedNotCrushedByHR() {
        // The exact shape of the bug: speed ~8-12 km/h, HR ~140-160 bpm.
        let speed = [8.0, 10.0, 12.0, 9.0, 11.0]
        let hr = [140.0, 150.0, 160.0, 155.0, 145.0]

        let ns = SeriesNormalize.normalized(speed)
        let nh = SeriesNormalize.normalized(hr)

        // Each series, on its OWN range, must span the full 0…1 band — i.e. the
        // speed curve is NOT flattened. (Raw co-scaling gave speed a span of
        // ~(12-8)/160 ≈ 0.025 — the "almost zero" bug.)
        #expect(abs((ns.max()! - ns.min()!) - 1.0) < 0.0001)
        #expect(abs((nh.max()! - nh.min()!) - 1.0) < 0.0001)
        // And both live within the shared 0…1 frame.
        #expect(ns.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(nh.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test("a flat series maps to mid-band, not NaN")
    func flatSeriesIsSafe() {
        let flat = [10.0, 10.0, 10.0]
        let n = SeriesNormalize.normalized(flat)
        #expect(n.allSatisfy { $0 == 0.5 })
    }

    @Test("empty series doesn't crash the range")
    func emptyIsSafe() {
        #expect(SeriesNormalize.normalized([]).isEmpty)
    }
}
