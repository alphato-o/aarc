import Foundation
import Observation

/// Fetches the real-time ambient context (weather / AQI / sun / news) that gets
/// fed into script generation, so the Control Room can SHOW what was actually
/// fetched + put into the coach's context. Runs during a run (start + every
/// 15 min) and logs each result to the run diagnostics too.
@MainActor
@Observable
final class AmbientProbe {
    static let shared = AmbientProbe()
    private init() {}

    struct Snapshot {
        var fetchedAt: Date
        var hasLocation: Bool
        var fields: [(label: String, value: String)]
        var block: String          // the exact prompt block fed to the coaches
    }

    private(set) var latest: Snapshot?
    /// Fetch status, surfaced in the Control Room so a stale/failed fetch is
    /// visible instead of silently showing an old (or time-only) snapshot.
    private(set) var lastAttemptAt: Date?
    private(set) var lastOK = false
    private var loop: Task<Void, Never>?

    func start() {
        stop()
        loop = Task { [weak self] in
            guard let self else { return }
            // Probe FAST at first — at run start there's usually no GPS fix yet,
            // so the opening fetch is location-less (time only). Retry every 30s
            // until we land a real located fetch with weather/AQI, THEN settle
            // into the cheap 15-min cadence. (Before, a cold-start miss meant 15
            // minutes of "only the time" in the Control Room.)
            while !Task.isCancelled {
                let located = await self.probe()
                let next: Duration = located ? .seconds(900) : .seconds(30)
                try? await Task.sleep(for: next)
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }
    func clear() { latest = nil; lastAttemptAt = nil; lastOK = false }

    /// Returns true once we have a location-backed fetch with real ambient
    /// data (so the loop can stop hammering and settle into its slow cadence).
    @discardableResult
    func probe() async -> Bool {
        lastAttemptAt = Date()
        let info = PlaceContext.shared.ambientInfo
        var body: [String: Any] = [:]
        if let v = info.lat { body["lat"] = v }
        if let v = info.lon { body["lon"] = v }
        if let v = info.city { body["city"] = v }
        if let v = info.venue { body["venue"] = v }
        if let v = info.localClock { body["localClock"] = v }
        if let v = info.weekday { body["weekday"] = v }
        if let v = info.monthDay { body["monthDay"] = v }

        guard let url = URL(string: "\(Config.apiBaseURL.absoluteString)/ambient"),
              let payload = try? JSONSerialization.data(withJSONObject: body) else { return false }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = payload

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            lastOK = false
            return false
        }
        let r = j["resolved"] as? [String: Any] ?? [:]
        let block = j["block"] as? String ?? ""

        var fields: [(String, String)] = []
        func num(_ key: String) -> String? { (r[key] as? NSNumber).map { "\($0)" } }
        if let t = num("tempC") { fields.append(("Temp", "\(t)°C")) }
        if let f = num("feelsC") { fields.append(("Feels", "\(f)°")) }
        if let c = r["conditions"] as? String { fields.append(("Sky", c)) }
        if let h = num("humidity") { fields.append(("Humidity", "\(h)%")) }
        if let w = num("windKmh") { fields.append(("Wind", "\(w) km/h")) }
        if let p = num("pm25") {
            let cat = r["aqiCategory"] as? String ?? ""
            fields.append(("PM2.5", "\(p) µg/m³\(cat.isEmpty ? "" : " — \(cat)")"))
        }
        if let a = num("aqi") { fields.append(("AQI", "\(a)")) }
        if let ss = r["sunset"] as? String { fields.append(("Sunset", ss)) }
        if let world = r["worldNews"] as? [String], let first = world.first {
            fields.append(("World", first))
        }
        if let city = r["cityNews"] as? [String], let first = city.first {
            fields.append(("Local", first))
        }
        if let clock = info.localClock, let wd = info.weekday {
            fields.insert(("Time", "\(wd) \(clock)"), at: 0)
        }
        if let venue = info.venue { fields.append(("Venue", venue)) }

        let located = info.lat != nil
        latest = Snapshot(fetchedAt: Date(), hasLocation: located, fields: fields, block: block)
        lastOK = true

        // Mirror into the run diagnostics so a replay/dashboard can show it too.
        var logData: [String: String] = [:]
        for (k, v) in fields { logData[k] = v }
        RunEventLog.shared.record("ambient", info.city ?? (located ? "located" : "no-location"),
                                  data: logData)

        // "Located" only counts when we actually got weather/AQI back — a
        // located fetch that resolved nothing (offline) should keep retrying.
        return located && fields.contains { $0.0 != "Time" && $0.0 != "Venue" }
    }
}
