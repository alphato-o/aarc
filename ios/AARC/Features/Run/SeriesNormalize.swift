import Foundation

/// Normalize a telemetry series to 0…1 against its OWN min/max, so two series
/// of very different magnitude (speed ~10 km/h vs HR ~150 bpm) can share one
/// chart frame without the larger one crushing the smaller into a flat line.
///
/// This was the post-run summary chart bug: speed and HR were co-plotted RAW on
/// a single auto-scaled Y axis, so HR's ~150 set the scale and the ~10 speed
/// line rendered "almost zero." The History chart already normalizes per-series
/// (0…1, hidden axis); this shares that technique so the summary matches.
enum SeriesNormalize {
    static func range(_ values: [Double]) -> (min: Double, max: Double) {
        (values.min() ?? 0, values.max() ?? 1)
    }

    /// `value` → 0…1 within `range`; 0.5 for a degenerate (flat) range.
    static func unit(_ value: Double, in range: (min: Double, max: Double)) -> Double {
        let span = range.max - range.min
        guard span > 0.0001 else { return 0.5 }
        return (value - range.min) / span
    }

    /// Whole series mapped to 0…1 against its own range.
    static func normalized(_ values: [Double]) -> [Double] {
        let r = range(values)
        return values.map { unit($0, in: r) }
    }
}
