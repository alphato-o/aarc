import Foundation
import AARCKit
import os

/// The pre-baked race script and the voice lines it needs, built at home the
/// night before so the first half hour of the marathon, where the crowd has
/// no signal, still has a coach. Keyed to the plan it was built for; a
/// different plan or persona at the start line means it is not used.
struct RacePack: Codable, Sendable {
    let planKey: String
    let runType: String
    let personalityId: String
    let courseId: String
    let builtAt: Date
    let script: GeneratedScript
    /// Every line that was rendered to audio when the pack was built.
    var warmedLines: Int
    var totalLines: Int
    /// Jessica's and Home Base's offline lines, one kilometre each. Optional
    /// so a pack built before they existed still loads.
    var jessicaLines: [AIClient.PackVoiceLine]?
    var homeLines: [AIClient.PackVoiceLine]?

    var lineCount: Int { script.messages.reduce(0) { $0 + $1.rotationPool.count } }

    static func key(plan: RunPlan, personalityId: String) -> String {
        "\(plan.kind.rawValue)|\(plan.distanceKm ?? 0)|\(plan.timeMinutes ?? 0)|\(personalityId)"
    }
}

/// Home Base's own offline lines: spoken from the phone with no proxy in the
/// loop, so they are rendered to audio with the pack and cached.
enum RacePackLocalLines {
    static let gateCrossed = "Gate. Race clock running. Home Base has you from here."
    static let corralReady = "Session is live. You are in the corral. Press the gate button when you cross the mat."
    static var all: [String] { [gateCrossed, corralReady] }
}

@MainActor
@Observable
final class RacePackStore {
    static let shared = RacePackStore()
    static let courseId = "tianjin2026"
    private let log = Logger(subsystem: "club.aarun.AARC", category: "RacePack")

    enum Phase: Equatable {
        case idle
        case generating
        case rendering(done: Int, total: Int)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Why the last build has no Jessica / Home Base lines, for the screen.
    private(set) var voicesError: String?
    private(set) var pack: RacePack?
    private var buildTask: Task<Void, Never>?
    /// Offline lines already spoken this run, so none repeats.
    private var spoken: Set<String> = []

    var isBuilding: Bool {
        switch phase {
        case .generating, .rendering: return true
        default: return false
        }
    }

    init() {
        pack = Self.load()
    }

    /// The pack if it was built for exactly this plan, run type and persona.
    func usablePack(plan: RunPlan, runType: RunType, personalityId: String) -> RacePack? {
        guard let pack else { return nil }
        guard pack.planKey == RacePack.key(plan: plan, personalityId: personalityId),
              pack.runType == runType.rawValue else { return nil }
        return pack
    }

    /// Start of a pack run: count the pack's audio on disk and, if any is
    /// missing and the network is up, render and pin the gaps in the background.
    func verifyAudio(plan: RunPlan) {
        guard let pack, buildTask == nil else { return }
        Task { @MainActor in
            let r = await self.render(pack: pack, plan: plan)
            RunEventLog.shared.record("race.pack.audio", "\(r.done)/\(r.total) lines on the phone")
            self.phase = .idle
        }
    }

    func resetPlayback() { spoken = [] }

    /// Home Base's pack line for this kilometre, once, in Actual race mode.
    func homeLine(km: Int) -> String? {
        guard RunOrchestrator.shared.raceMode == .actual,
              let line = pack?.homeLines?.first(where: { $0.km == km }),
              !spoken.contains(line.text) else { return nil }
        spoken.insert(line.text)
        return line.text
    }

    /// Jessica's next pack line: the one for this kilometre or the one
    /// before, so a line whose km went by while she was waiting still plays.
    func jessicaLine(km: Int) -> String? {
        guard RunOrchestrator.shared.raceMode == .actual,
              let line = pack?.jessicaLines?
                .filter({ $0.km <= km && $0.km >= km - 1 && !spoken.contains($0.text) })
                .max(by: { $0.km < $1.km }) else { return nil }
        spoken.insert(line.text)
        return line.text
    }

    /// True when the pack on disk no longer matches the current plan.
    func isStale(plan: RunPlan, runType: RunType, personalityId: String) -> Bool {
        pack != nil && usablePack(plan: plan, runType: runType, personalityId: personalityId) == nil
    }

    func build(plan: RunPlan, runType: RunType, personalityId: String) {
        guard !isBuilding else { return }
        buildTask?.cancel()
        voicesError = nil
        phase = .generating
        buildTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let script = try await RunOrchestrator.shared.generateRaceScript(
                    plan: plan, runType: runType, personalityId: personalityId)
                guard !Task.isCancelled else { return }
                var built = RacePack(
                    planKey: RacePack.key(plan: plan, personalityId: personalityId),
                    runType: runType.rawValue,
                    personalityId: personalityId,
                    courseId: Self.courseId,
                    builtAt: Date(),
                    script: script,
                    warmedLines: 0,
                    totalLines: 0)
                // A pack without the other two voices is still a pack: Ricky
                // covers the dark kilometres alone, and the screen says so.
                do {
                    let voices = try await AIClient.shared.racePackVoices(
                        courseId: Self.courseId, personalNotes: PersonalContextStore.shared.bullets)
                    built.jessicaLines = voices.jessica
                    built.homeLines = voices.home
                    RunEventLog.shared.record("race.pack.voices", "jessica \(voices.jessica.count), home \(voices.home.count)")
                } catch {
                    self.log.error("race pack voices failed: \(error.localizedDescription, privacy: .public)")
                    self.voicesError = error.localizedDescription
                }
                guard !Task.isCancelled else { return }
                self.pack = built
                try Self.save(built)
                RunEventLog.shared.record("race.pack.built", "\(built.lineCount) lines",
                                          data: ["scriptId": script.scriptId, "model": script.model])
                let warmed = await self.render(pack: built, plan: plan)
                guard !Task.isCancelled else { return }
                built.warmedLines = warmed.done
                built.totalLines = warmed.total
                self.pack = built
                try Self.save(built)
                self.phase = .idle
            } catch {
                self.log.error("race pack build failed: \(error.localizedDescription, privacy: .public)")
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Render every line the pack can speak into the audio cache: the script
    /// in Ricky's voice, the factual kilometre announcements, and Home Base's
    /// local lines. Best effort per line; the count says how complete it is.
    private func render(pack: RacePack, plan: RunPlan) async -> (done: Int, total: Int) {
        var jobs: [(text: String, voiceId: String)] = []
        for message in pack.script.messages {
            for variant in message.rotationPool { jobs.append((variant, RemoteTTS.voiceId)) }
        }
        for text in MilestoneAnnouncement.prefetchTexts(for: plan) { jobs.append((text, RemoteTTS.voiceId)) }
        for text in RacePackLocalLines.all { jobs.append((text, RemoteTTS.homeVoiceId)) }
        for text in RaceCameraDirector.packLines { jobs.append((text, RemoteTTS.homeVoiceId)) }
        for line in pack.jessicaLines ?? [] { jobs.append((line.text, RemoteTTS.jessicaVoiceId)) }
        for line in pack.homeLines ?? [] { jobs.append((line.text, RemoteTTS.homeVoiceId)) }
        var done = 0
        phase = .rendering(done: 0, total: jobs.count)
        for job in jobs {
            if Task.isCancelled { break }
            await RemoteTTS.shared.prefetch(job.text, voiceId: job.voiceId)
            let key = AudioCache.key(voiceId: job.voiceId, text: job.text)
            if await AudioCache.shared.url(forKey: key) != nil, await AudioCache.shared.pin(key: key) { done += 1 }
            phase = .rendering(done: done, total: jobs.count)
        }
        return (done, jobs.count)
    }

    func cancelBuild() {
        buildTask?.cancel()
        buildTask = nil
        phase = .idle
    }

    func delete() {
        cancelBuild()
        pack = nil
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    // MARK: - Disk

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("race-pack.json")
    }

    private static func load() -> RacePack? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RacePack.self, from: data)
    }

    private static func save(_ pack: RacePack) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(pack).write(to: fileURL, options: .atomic)
    }
}
