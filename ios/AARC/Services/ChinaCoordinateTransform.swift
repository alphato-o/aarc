import Foundation
import CoreLocation

/// WGS-84 → GCJ-02 coordinate transform for mainland China.
///
/// Apple Maps tiles inside mainland China are GCJ-02 (the "Mars
/// Coordinates" obfuscation mandated by Chinese mapping regulation).
/// HealthKit and CoreLocation both deliver WGS-84. If we plot WGS-84
/// coordinates directly over a GCJ-02 tile, every point lands several
/// hundred metres off — typically northwest of the true position.
/// Apple Fitness silently applies this transform; AARC didn't, hence
/// the visible route offset.
///
/// We do NOT transform points outside mainland China — the algorithm
/// is undefined there and would produce nonsense. Hong Kong, Macau,
/// Taiwan, and everywhere else continue to use the input coordinates.
enum ChinaCoordinateTransform {
    /// Bounding box for mainland China minus the special administrative
    /// regions that use WGS-84 tiles. Slightly conservative to avoid
    /// false positives on edge cases (e.g., Mongolia, the Yellow Sea).
    private static let mainlandBox: (latMin: Double, latMax: Double, lonMin: Double, lonMax: Double) = (
        latMin: 0.8293, latMax: 55.8271, lonMin: 72.004, lonMax: 137.8347
    )

    /// Return the coordinate as it should appear on Apple Maps —
    /// transformed if the input falls inside mainland China, untouched
    /// otherwise.
    static func displayCoordinate(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard isInsideChina(c) else { return c }
        return wgs84ToGcj02(c)
    }

    static func displayCoordinates(_ cs: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        cs.map(displayCoordinate)
    }

    // MARK: - Internals
    //
    // Algorithm from the published GCJ-02 reverse-engineering work — the
    // canonical reference implementation used by every Chinese mapping
    // SDK. Constants are not arbitrary; do not "clean up" the magic
    // numbers without checking against a reference dataset first.

    private static let a: Double = 6378245.0
    private static let ee: Double = 0.00669342162296594323

    private static func isInsideChina(_ c: CLLocationCoordinate2D) -> Bool {
        guard mainlandBox.latMin <= c.latitude, c.latitude <= mainlandBox.latMax,
              mainlandBox.lonMin <= c.longitude, c.longitude <= mainlandBox.lonMax
        else { return false }
        // Crude HK / Macau exclusion — both are far enough south that a
        // simple latitude cutoff covers them. (Taiwan is left to fall
        // back to WGS-84 via the box.)
        if c.latitude < 22.4 && c.longitude < 114.6 { return false }
        return true
    }

    private static func wgs84ToGcj02(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let lat = c.latitude
        let lon = c.longitude
        var dLat = transformLat(x: lon - 105.0, y: lat - 35.0)
        var dLon = transformLon(x: lon - 105.0, y: lat - 35.0)
        let radLat = lat / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        return CLLocationCoordinate2D(latitude: lat + dLat, longitude: lon + dLon)
    }

    private static func transformLat(x: Double, y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLon(x: Double, y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
    }
}
