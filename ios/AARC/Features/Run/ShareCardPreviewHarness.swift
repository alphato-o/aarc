import SwiftUI
import UIKit

/// Dev-only: render the share card to PNGs at launch so the layout can be
/// eyeballed against the web dashboard WITHOUT a real run. Gated behind the
/// `AARC_SHARE_PREVIEW=1` launch env var — never runs in production.
///
/// Writes <Documents>/share-preview-quote.png and -route.png. Pull them off
/// the simulator with `xcrun simctl get_app_container booted <bundleid> data`.
@MainActor
enum ShareCardPreviewHarness {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["AARC_SHARE_PREVIEW"] == "1"
    }

    /// The exact quote + KPIs from the web baseline (private/share image cal),
    /// so the rendered card is directly comparable to web.png.
    private static let sampleQuote =
        "Another k swallowed up, and what's it bought you? Sod all. Out here on the cold tarmac, lungs flapping like a wet carrier bag, while a man with proper money decides between two private islands and you're deciding whether your knee's about to file a complaint, you sweaty little plonker."

    /// Modelled on the founder's real 30 Jul run: 10.22 km (=> 102 buckets at
    /// 100m each, so km markers land every 10 samples) with the negative split
    /// he actually ran — 6:05/km for 5k, 5:45 to 8k, 5:28 home. Synthetic
    /// 40-sample sine data made the km spacing meaningless to review.
    private static var realSpeed: [Double] {
        (0..<102).map { i in
            let km = Double(i) / 10
            let base: Double = km < 5 ? 9.86 : (km < 8 ? 10.43 : 10.98)   // km/h
            return base + 0.42 * sin(Double(i) / 3.1) + 0.18 * sin(Double(i) / 7.7)
        }
    }
    private static var realHR: [Double] {
        (0..<102).map { i in
            let drift = 148.0 + Double(i) * 0.31          // cardiac drift over the run
            return drift + 4.5 * sin(Double(i) / 5.3) + 2.0 * sin(Double(i) / 11.0)
        }
    }

    private static func baseModel(map: UIImage?) -> ShareCardModel {
        ShareCardModel(
            date: "Mon, Jun 15, 2026",
            kpis: [
                ("Distance", "10.22 km"), ("Time", "1h00m"),
                ("Pace", "5:52/km"), ("Avg HR", "160 bpm"),
            ],
            speed: Self.realSpeed,
            hr: Self.realHR,
            distanceMeters: 10_220,
            quote: sampleQuote, who: "ricky", heardAtKm: nil,
            aspect: ShareCardModel.portrait,
            mapImage: map,
            mapPoints: map == nil ? [] : samplePoints(),
            mapColors: map == nil ? [] : samplePoints().map { _ in
                Color(red: 0.46, green: 0.886, blue: 0.635) })
    }

    // A plausible looping route in the 928×555 base-map pixel space.
    private static func samplePoints() -> [CGPoint] {
        [CGPoint(x: 120, y: 300), CGPoint(x: 120, y: 150), CGPoint(x: 700, y: 150),
         CGPoint(x: 700, y: 250), CGPoint(x: 300, y: 250), CGPoint(x: 300, y: 360)]
    }

    // A flat dark base map stand-in (the real one is CARTO dark_nolabels via
    // /staticmap; we only need it to validate the overlay/quote geometry).
    private static func darkMap(w: Int, h: Int) -> UIImage {
        let r = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        return r.image { ctx in
            UIColor(red: 0.05, green: 0.09, blue: 0.06, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    /// The founder's 9 Aug Qingdao run as HISTORY renders it: 7.16km read back
    /// from HealthKit as ~500 TIME samples, not 72 distance buckets. This is
    /// the shape that produced 48 overlapping "km" labels, so it is the shape
    /// the harness has to cover.
    private static func denseHistoryModel() -> ShareCardModel {
        var m = baseModel(map: nil)
        let n = 500
        // Split out: one expression with several Double ops per element blows
        // the type-checker's budget in this file.
        var sp: [Double] = []
        var hrv: [Double] = []
        for i in 0..<n {
            let d = Double(i)
            let wobble: Double = sin(d / 21) * 0.5
            let ripple: Double = sin(d / 7) * 0.2
            sp.append(10.3 + wobble + ripple)
            let drift: Double = d * 0.055
            let breathe: Double = sin(d / 33) * 3
            hrv.append(132.0 + drift + breathe)
        }
        m.speed = sp
        m.hr = hrv
        m.distanceMeters = 7_160
        m.kpis = [("Distance", "7.16 km"), ("Time", "41m45s"),
                  ("Pace", "5:50/km"), ("Avg HR", "155 bpm")]
        return m
    }

    static func run() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let img = ShareExport.image(denseHistoryModel()), let d = img.pngData() {
            try? d.write(to: dir.appendingPathComponent("share-preview-dense.png"))
        }
        if let img = ShareExport.image(baseModel(map: nil)), let d = img.pngData() {
            try? d.write(to: dir.appendingPathComponent("share-preview-quote.png"))
        }
        if let img = ShareExport.image(baseModel(map: darkMap(w: 928, h: 555))), let d = img.pngData() {
            try? d.write(to: dir.appendingPathComponent("share-preview-route.png"))
        }
        NSLog("AARC_SHARE_PREVIEW wrote cards to \(dir.path)")
    }
}
