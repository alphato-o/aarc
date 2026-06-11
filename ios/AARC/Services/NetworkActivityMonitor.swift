import Foundation
import Observation

/// Live network inspector for the run's two external dependencies:
/// ElevenLabs (TTS synth) and the LLM proxy (script / reactive lines).
///
/// The Control Room reads this to show the full request lifecycle in real
/// time — sent → awaiting → received/failed — instead of a vague "TTS busy"
/// light. The thing the founder actually wants to watch while jogging on a
/// treadmill wondering whether the network is the reason it went quiet.
@MainActor
@Observable
final class NetworkActivityMonitor {
    static let shared = NetworkActivityMonitor()

    enum Phase: String, Sendable {
        case sending     // request being built / dispatched
        case awaiting    // request out, waiting on the response (the synth wait)
        case received    // response in
        case failed
        case cached      // served from the local cache — no network at all
    }

    struct Entry: Identifiable, Sendable {
        let id = UUID()
        /// "11Labs" or "LLM".
        let service: String
        /// Short label: spoken-line preview, or the endpoint/purpose.
        let label: String
        /// Characters in the request, when meaningful (TTS).
        let chars: Int?
        var phase: Phase
        let startedAt: Date
        var endedAt: Date?
        var bytes: Int?
        var detail: String?      // error text on failure, status on success

        /// Wall-clock ms from start to finish, or live elapsed if still open.
        func elapsedMs(now: Date) -> Int {
            Int(((endedAt ?? now).timeIntervalSince(startedAt)) * 1000)
        }
        var isOpen: Bool { endedAt == nil }
    }

    /// Newest-first ring of recent requests (live + finished).
    private(set) var entries: [Entry] = []
    /// How many requests are in flight right now, per service.
    private(set) var inFlight: [String: Int] = [:]

    private let capacity = 60

    private init() {}

    /// Open a new request. Returns its id; advance it with `awaiting`,
    /// `finish`, or `fail`.
    @discardableResult
    func begin(service: String, label: String, chars: Int? = nil) -> UUID {
        let entry = Entry(service: service, label: String(label.prefix(80)), chars: chars,
                          phase: .sending, startedAt: Date())
        entries.insert(entry, at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
        inFlight[service, default: 0] += 1
        return entry.id
    }

    /// Mark the request as dispatched and now waiting on the response.
    func awaiting(_ id: UUID) { update(id) { $0.phase = .awaiting } }

    /// Response arrived OK.
    func finish(_ id: UUID, bytes: Int? = nil, detail: String? = nil) {
        update(id) { $0.phase = .received; $0.endedAt = Date(); $0.bytes = bytes; $0.detail = detail }
        decFlight(id)
    }

    /// Served from cache — zero network.
    func cached(_ id: UUID) {
        update(id) { $0.phase = .cached; $0.endedAt = Date() }
        decFlight(id)
    }

    /// Request failed.
    func fail(_ id: UUID, _ error: String) {
        update(id) { $0.phase = .failed; $0.endedAt = Date(); $0.detail = String(error.prefix(120)) }
        decFlight(id)
    }

    func reset() { entries.removeAll(); inFlight.removeAll() }

    private func update(_ id: UUID, _ mutate: (inout Entry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        mutate(&entries[i])
    }

    private func decFlight(_ id: UUID) {
        guard let e = entries.first(where: { $0.id == id }) else { return }
        inFlight[e.service] = max(0, (inFlight[e.service] ?? 1) - 1)
    }
}
