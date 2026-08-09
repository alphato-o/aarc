import AARCKit
import CoreLocation
import Foundation
import MapKit

/// Dev-only venue-search probe. Runs the SAME MapKit queries `VenueLocator`
/// uses, from a coordinate supplied on the command line, and prints every hit
/// with its distance — so the venue algorithm can be dry-run against a KNOWN
/// address without standing in a gym.
///
/// Built 2026-08-04 because Park Hyatt Beijing never surfaced in the in-run
/// venue card across four runs, and guessing at the cause from run logs had
/// already burned three attempted fixes. The two live hypotheses this settles:
///   H1 — DATUM: the code shifts the CL fix WGS-84 -> GCJ-02 before searching.
///        If iOS CoreLocation already hands back GCJ-02 inside China, that
///        second shift pushes the search centre ~500m off, which would explain
///        "real CBD hotels, never the right one".
///   H2 — COVERAGE: Apple's China POI data (AutoNavi) may simply not return
///        the hotel under the .hotel category, in which case no amount of
///        centring fixes it and we need a different provider.
///
/// Usage (simulator):
///   SIMCTL_CHILD_AARC_VENUE_PROBE="39.9062681,116.4535128" \
///     xcrun simctl launch booted club.aarun.AARC
/// Output goes to <Documents>/venue-probe.txt and the console.
@MainActor
enum VenueProbeHarness {
    /// Raw env value: either "lat,lon" or "here".
    private static var raw: String? {
        ProcessInfo.processInfo.environment["AARC_VENUE_PROBE"]
    }
    static var enabled: Bool { raw != nil }
    /// "here" = ask the DEVICE where it is instead of being told. Added
    /// 2026-08-09: the founder travelled to a new venue and the fastest way to
    /// prep for it is to have his own phone answer, rather than him typing
    /// coordinates or me guessing from a hotel's map pin.
    private static var useDeviceLocation: Bool { raw?.lowercased() == "here" }

    static var target: CLLocationCoordinate2D? {
        guard let raw, !useDeviceLocation else { return nil }
        let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return nil }
        return CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
    }

    /// What we're hoping to see come back, so the report can self-assess.
    private static let wanted = ["hyatt", "柏悦", "yintai", "银泰"]

    static func run() async {
        var out: [String] = []
        func log(_ s: String) { out.append(s); print("VENUE-PROBE \(s)") }

        // Where are we? Either the coordinate we were handed, or ask the phone.
        var wgs: CLLocationCoordinate2D
        if useDeviceLocation {
            log("=== ASKING THE DEVICE WHERE IT IS ===")
            guard let cap = await VenueLocator.shared.capture() else {
                log("FAILED — no location fix (permission denied, or no fix yet).")
                writeOut(out); return
            }
            wgs = cap.coord
            log("device says: \(fmt(cap.coord))")
            log("reverse-geocoded city: \(cap.city ?? "(none)")")
            log("venue candidates it would offer (\(cap.venues.count)):")
            for (i, v) in cap.venues.enumerated() { log("   \(i + 1). \(v)") }
            log("")
        } else if let t = target {
            wgs = t
        } else {
            return
        }

        let gcj = ChinaCoordinateTransform.displayCoordinate(wgs)
        let shiftM = CLLocation(latitude: wgs.latitude, longitude: wgs.longitude)
            .distance(from: CLLocation(latitude: gcj.latitude, longitude: gcj.longitude))
        log("target WGS-84 \(fmt(wgs))")
        log("target GCJ-02 \(fmt(gcj))  (shift \(Int(shiftM)) m)")
        log("inMainlandChina=\(ChinaCoordinateTransform.isMainlandChina(wgs))")
        log("")

        // Both datums x several radii: whichever centre puts the target at
        // ~0 m is the datum MapKit actually wants.
        for (label, c) in [("WGS-84 (raw CL fix)", wgs), ("GCJ-02 (current shipping code)", gcj)] {
            for radius in [500.0, 1200.0, 3000.0] {
                await probeCategory("\(label) r=\(Int(radius))", center: c, radius: radius,
                                    cats: [.hotel], log: log)
            }
            await probeCategory("\(label) r=1200 +gyms", center: c, radius: 1200,
                                cats: [.hotel, .fitnessCenter], log: log)
            for q in ["酒店 hotel", "Park Hyatt", "柏悦", "hotel"] {
                await probeKeyword("\(label) kw=\"\(q)\"", query: q, center: c, log: log)
            }
        }

        // CONCURRENCY PROBE — the device returned ZERO hotels tonight where
        // this same code returned 17 on the sim. Prime suspect: nearbyVenues
        // fires two MKLocalPointsOfInterestRequests CONCURRENTLY (async let),
        // MapKit throttles concurrent local searches, and `try?` swallows the
        // throttle error into an empty array. Run it repeatedly and see.
        log("")
        log("=== CONCURRENCY PROBE (5 rounds, hotels vs gyms) ===")
        for round in 1...5 {
            async let h = countOnly([.hotel], near: wgs)
            async let g = countOnly([.fitnessCenter], near: wgs)
            let (hn, gn) = (await h, await g)
            log("  concurrent round \(round): hotels=\(hn)  gyms=\(gn)\(hn == 0 ? "   <<< HOTELS EMPTY" : "")")
        }
        log("--- same thing SEQUENTIALLY ---")
        for round in 1...5 {
            let hn = await countOnly([.hotel], near: wgs)
            let gn = await countOnly([.fitnessCenter], near: wgs)
            log("  sequential round \(round): hotels=\(hn)  gyms=\(gn)\(hn == 0 ? "   <<< HOTELS EMPTY" : "")")
        }

        // THE ACTUAL SHIPPING PATH — everything above is hypothesis testing;
        // this is what the in-run card will really offer.
        log("")
        log("=== VenueLocator.nearbyVenues (SHIPPING) ===")
        let real = await VenueLocator.shared.nearbyVenues(
            CLLocation(latitude: wgs.latitude, longitude: wgs.longitude))
        log("returned \(real.count) candidates (cap \(VenueLocator.maxCandidates)):")
        for (i, n) in real.enumerated() {
            let star = wanted.contains(where: { n.lowercased().contains($0) }) ? "  <<< TARGET" : ""
            log("   \(i + 1). \(n)\(star)")
        }
        if let idx = real.firstIndex(where: { n in wanted.contains(where: { n.lowercased().contains($0) }) }) {
            log("VERDICT: target at position \(idx + 1) of \(real.count) — \(idx == 0 ? "PASS (first question)" : "found but not first")")
        } else {
            log("VERDICT: FAIL — target not in the candidate list at all")
        }

        writeOut(out)
        log("=== PROBE COMPLETE ===")
    }

    private static func writeOut(_ out: [String]) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? out.joined(separator: "\n").write(
            to: dir.appendingPathComponent("venue-probe.txt"), atomically: true, encoding: .utf8)
    }

    /// Count only, and report an ERROR distinctly from an empty result — the
    /// shipping code's `try?` cannot tell those apart, which is the whole bug.
    private static func countOnly(_ cats: [MKPointOfInterestCategory],
                                  near c: CLLocationCoordinate2D) async -> Int {
        let req = MKLocalPointsOfInterestRequest(center: c, radius: 3000)
        req.pointOfInterestFilter = MKPointOfInterestFilter(including: cats)
        do { return try await MKLocalSearch(request: req).start().mapItems.count }
        catch { return -1 }   // -1 = threw. NOTE: this API also throws on a
                              // genuinely empty category, so -1 is "no usable
                              // result", not necessarily an error.
    }

    private static func probeCategory(_ label: String, center: CLLocationCoordinate2D,
                                      radius: CLLocationDistance,
                                      cats: [MKPointOfInterestCategory],
                                      log: (String) -> Void) async {
        let req = MKLocalPointsOfInterestRequest(center: center, radius: radius)
        req.pointOfInterestFilter = MKPointOfInterestFilter(including: cats)
        await report(label: "CATEGORY  \(label)", center: center, req: MKLocalSearch(request: req), log: log)
    }

    private static func probeKeyword(_ label: String, query: String,
                                     center: CLLocationCoordinate2D,
                                     log: (String) -> Void) async {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        req.region = MKCoordinateRegion(center: center, latitudinalMeters: 2500, longitudinalMeters: 2500)
        await report(label: "KEYWORD   \(label)", center: center, req: MKLocalSearch(request: req), log: log)
    }

    private static func report(label: String, center: CLLocationCoordinate2D,
                               req: MKLocalSearch, log: (String) -> Void) async {
        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        do {
            let resp = try await req.start()
            let rows = resp.mapItems.compactMap { item -> (String, CLLocationDistance)? in
                guard let n = item.name, let d = item.placemark.location?.distance(from: origin) else { return nil }
                return (n, d)
            }.sorted { $0.1 < $1.1 }
            let hit = rows.first { r in wanted.contains { r.0.lowercased().contains($0) } }
            log("\(label) -> \(rows.count) results\(hit.map { "  *** TARGET FOUND: \($0.0) @ \(Int($0.1))m ***" } ?? "")")
            for (n, d) in rows.prefix(8) { log("      \(Int(d))m  \(n)") }
        } catch {
            log("\(label) -> ERROR \(error.localizedDescription)")
        }
    }

    private static func fmt(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.7f, %.7f", c.latitude, c.longitude)
    }
}
