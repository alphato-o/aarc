import Foundation
import Observation
import AARCKit

/// The in-run roast library (founder idea, 2026-07-10): batched LLM calls
/// write short stand-alone roasts, de-duplicated against each other. Since
/// 18 Oct it is also Ricky's offline voice: kept on disk across launches,
/// audio rendered ahead, topped up whenever the network allows (home, run
/// start, the network coming back), and drawn by every trigger while dark.
@MainActor
@Observable
final class RoastPool {
    static let shared = RoastPool()

    private struct Entry: Codable { let key: String; let text: String; let at: Date }

    private var entries: [Entry] = []
    private var warmed: Set<String> = []
    private(set) var drawn = 0
    private var fetchTask: Task<Void, Never>?
    private var runKey: String?
    private var runType: RunType = .outdoor

    /// Enough for ~30 dark minutes at one line every 90 s, with spares.
    private static let target = 32
    private static let maxAge: TimeInterval = 72 * 3600
    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("roast-pool.json")
    }

    var remaining: Int { entries.filter { $0.key == (runKey ?? currentKey(runType)) }.count }

    init() {
        if let d = try? Data(contentsOf: Self.fileURL), let e = try? JSONDecoder().decode([Entry].self, from: d) {
            entries = e.filter { Date().timeIntervalSince($0.at) < Self.maxAge }
        }
        EndpointManager.shared.whenOnline { RoastPool.shared.topUp(runType: RoastPool.shared.runType) }
    }

    private func currentKey(_ runType: RunType) -> String {
        let p = ScriptPreviewStore.shared.currentPlan
        return "\(p.kind.rawValue)|\(p.distanceKm ?? 0)|\(p.timeMinutes ?? 0)|\(runType.rawValue)"
    }

    /// Run start: pin the pool to this run's plan and fill it if short.
    func fetchIfNeeded(runType: RunType, personalityId: String = "roast_coach") {
        self.runType = runType
        runKey = currentKey(runType)
        topUp(runType: runType, personalityId: personalityId)
    }

    /// Fill to `target` for this plan, one batch at a time, and render each
    /// line's audio. Quiet no-op while dark or already fetching.
    func topUp(runType: RunType, personalityId: String = "roast_coach") {
        guard !AppEnv.uiTest, fetchTask == nil, !EndpointManager.shared.isDark else { return }
        let key = currentKey(runType)
        let plan = ScriptPreviewStore.shared.currentPlan
        fetchTask = Task { @MainActor [weak self] in
            defer { self?.fetchTask = nil }
            guard let self else { return }
            var batches = 0
            while self.entries.filter({ $0.key == key }).count < Self.target, batches < 3, !EndpointManager.shared.isDark {
                batches += 1
                do {
                    // No ambient: these lines may be spoken days later, under other weather.
                    let fetched = try await AIClient.shared.generateRoastPool(
                        personalityId: personalityId,
                        planKind: plan.kind.rawValue,
                        planDistanceKm: plan.distanceKm,
                        planTimeMinutes: plan.timeMinutes,
                        runType: runType.rawValue,
                        ambient: nil,
                        personalNotes: PersonalContextStore.shared.bullets,
                        likedLineExamples: LikedLinesStore.shared.vibeExemplars(personalityId: personalityId)
                    )
                    let known = Set(self.entries.map(\.text))
                    let fresh = fetched.filter { !known.contains($0) }.shuffled()
                    guard !fresh.isEmpty else { break }
                    self.entries += fresh.map { Entry(key: key, text: $0, at: .now) }
                    self.save()
                    RunEventLog.shared.record("pool.ready", "\(fresh.count) roasts added, \(self.entries.filter { $0.key == key }.count) on hand")
                } catch {
                    RunEventLog.shared.record("pool.failed", String(describing: error).prefix(120).description)
                    break
                }
            }
            await self.warmAudio()
        }
    }

    /// Render audio for every line not yet known to be cached.
    private func warmAudio() async {
        for e in entries where !warmed.contains(e.text) {
            if EndpointManager.shared.isDark { return }
            if await RemoteTTS.shared.prefetch(e.text, within: 60) {
                warmed.insert(e.text)
                await AudioCache.shared.pin(key: AudioCache.key(voiceId: RemoteTTS.voiceId, text: e.text))
            }
        }
    }

    /// Next line for this run's plan, audio-ready lines first. Each line is
    /// spoken once, ever. nil when empty (the caller goes live or stays quiet).
    func draw() -> String? {
        let key = runKey ?? currentKey(runType)
        let mine = entries.indices.filter { entries[$0].key == key }
        guard let i = mine.first(where: { warmed.contains(entries[$0].text) }) ?? mine.first else { return nil }
        let text = entries.remove(at: i).text
        warmed.remove(text)
        // Spoken once ever; free the pinned copy after it has had time to play.
        Task { try? await Task.sleep(for: .seconds(600)); await AudioCache.shared.unpin(key: AudioCache.key(voiceId: RemoteTTS.voiceId, text: text)) }
        drawn += 1
        save()
        if remaining < 8 { topUp(runType: runType) }
        return text
    }

    /// Run end: the shelf stays for the next run.
    func reset() {
        fetchTask?.cancel()
        fetchTask = nil
        runKey = nil
        drawn = 0
    }

    private func save() {
        if let d = try? JSONEncoder().encode(entries) { try? d.write(to: Self.fileURL, options: .atomic) }
    }
}
