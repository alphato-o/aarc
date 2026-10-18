import Foundation
import AARCKit

/// Openers generated while the network was up, kept for a start on a dead one.
/// Each is used once; the newest five per plan and run type are kept.
enum OpenerStash {
    private struct Entry: Codable { let key: String; let runType: String; let text: String }
    private static let defaultsKey = "aarc.opener.stash"

    static func put(_ text: String, key: String, runType: RunType) {
        var all = load()
        all.removeAll { $0.text == text }
        all.append(Entry(key: key, runType: runType.rawValue, text: text))
        let same = all.filter { $0.key == key && $0.runType == runType.rawValue }
        if same.count > 5, let oldest = same.first { all.removeAll { $0.text == oldest.text } }
        save(Array(all.suffix(30)))
    }

    static func take(key: String, runType: RunType) -> String? {
        var all = load()
        guard let i = all.lastIndex(where: { $0.key == key && $0.runType == runType.rawValue }) else { return nil }
        let text = all.remove(at: i).text
        save(all)
        return text
    }

    static func discard(_ text: String) {
        var all = load()
        all.removeAll { $0.text == text }
        save(all)
    }

    /// Fixed opener audio rendered and pinned ahead, so even a dark start with
    /// an empty stash opens in Ricky's voice.
    static func warmFixedLine(plan: RunPlan) {
        let text = fixedLine(plan: plan)
        Task {
            if await RemoteTTS.shared.prefetch(text, within: 60) {
                await AudioCache.shared.pin(key: AudioCache.key(voiceId: RemoteTTS.voiceId, text: text))
            }
        }
    }

    static func fixedLine(plan: RunPlan) -> String {
        switch plan.kind {
        case .distance:
            let km = plan.distanceKm.map { $0 == $0.rounded() ? String(Int($0)) : String(format: "%.1f", $0) } ?? "some"
            return "Right, Alpha. \(km) kilometres. Off you go. I'll catch you up."
        case .time:
            let m = plan.timeMinutes.map { String(Int($0)) } ?? "some"
            return "Right, Alpha. \(m) minutes. Off you go. I'll catch you up."
        case .open:
            return "Right, Alpha. Off you go. I'll catch you up."
        }
    }

    private static func load() -> [Entry] {
        guard let d = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: d)) ?? []
    }

    private static func save(_ all: [Entry]) {
        if let d = try? JSONEncoder().encode(all) { UserDefaults.standard.set(d, forKey: defaultsKey) }
    }
}
