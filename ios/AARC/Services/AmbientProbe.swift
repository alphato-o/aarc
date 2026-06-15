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
    private var loop: Task<Void, Never>?

    func start() {
        stop()
        Task { await probe() }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(900))
                await self?.probe()
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }
    func clear() { latest = nil }

    func probe() async {
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
              let payload = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = payload

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let r = j["resolved"] as? [String: Any] ?? [:]
        let block = j["block"] as? String ?? ""

        var fields: [(String, String)] = []
        func num(_ key: String) -> String? { (r[key] as? NSNumber).map { "\($0)" } }
        if let t = num("tempC") { fields.append(("Temp", "\(t)°C")) }
        if let f = num("feelsC") { fields.append(("Feels", "\(f)°")) }
        if let c = r["conditions"] as? String { fields.append(("Sky", c)) }
        if let h = num("humidity") { fields.append(("Humidity", "\(h)%")) }
        if let w = num("windKmh") { fields.append(("Wind", "\(w) km/h")) }
        if let a = num("aqi") {
            let cat = r["aqiCategory"] as? String ?? ""
            let pol = r["pollutant"] as? String
            fields.append(("AQI", "\(a) — \(cat)\(pol.map { " (\($0))" } ?? "")"))
        }
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

        latest = Snapshot(fetchedAt: Date(), hasLocation: info.lat != nil, fields: fields, block: block)

        // Mirror into the run diagnostics so a replay/dashboard can show it too.
        var logData: [String: String] = [:]
        for (k, v) in fields { logData[k] = v }
        RunEventLog.shared.record("ambient", info.city ?? (info.lat != nil ? "located" : "no-location"),
                                  data: logData)
    }
}
