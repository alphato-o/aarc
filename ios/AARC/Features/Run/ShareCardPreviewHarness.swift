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

    private static func baseModel(map: UIImage?) -> ShareCardModel {
        ShareCardModel(
            date: "Mon, Jun 15, 2026",
            kpis: [
                ("Distance", "2.63 km"), ("Time", "15m39s"),
                ("Pace", "5:58/km"), ("Avg HR", "150 bpm"),
            ],
            speed: (0..<40).map { 9 + 2 * sin(Double($0) / 4) },
            hr: (0..<40).map { 150 + 12 * sin(Double($0) / 6) },
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

    static func run() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let img = ShareExport.image(baseModel(map: nil)), let d = img.pngData() {
            try? d.write(to: dir.appendingPathComponent("share-preview-quote.png"))
        }
        if let img = ShareExport.image(baseModel(map: darkMap(w: 928, h: 555))), let d = img.pngData() {
            try? d.write(to: dir.appendingPathComponent("share-preview-route.png"))
        }
        NSLog("AARC_SHARE_PREVIEW wrote cards to \(dir.path)")
    }
}
