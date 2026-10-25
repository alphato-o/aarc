import SwiftUI

/// Export every line the runner heard, on the run clock, as subtitles (SRT)
/// or plain text, for cutting over the camera footage. Reads the run's
/// event log; nothing is fetched. Share sheet includes AirDrop.
struct VoiceLineExportSection: View {
    let run: RunRecord
    @State private var srtURL: URL?
    @State private var txtURL: URL?
    @State private var lineCount: Int?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Voice lines").font(.subheadline.bold())
                if run.raceModeRaw != "off" {
                    Text(run.raceModeRaw == "actual" ? "RACE" : "RACE · TRAINING").font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.purple.opacity(0.22), in: Capsule())
                        .foregroundStyle(.purple)
                }
                Spacer()
                if let lineCount { Text("\(lineCount) lines").font(.caption).foregroundStyle(.secondary) }
            }
            if let error {
                Text(error).font(.caption2).foregroundStyle(.orange)
            } else if let srtURL, let txtURL {
                HStack(spacing: 10) {
                    ShareLink(item: srtURL, preview: SharePreview("Voice lines (SRT)")) {
                        Label("Subtitles (.srt)", systemImage: "captions.bubble")
                    }
                    .buttonStyle(.bordered)
                    ShareLink(item: txtURL, preview: SharePreview("Voice lines (text)")) {
                        Label("Transcript (.txt)", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                }
                Text("Timed from the run start. AirDrop to a Mac from the share sheet.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Preparing…").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task { build() }
    }

    private func build() {
        let url = RunEventLog.logFileURL(for: run.id)
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            error = "No event log on this phone for this run."
            return
        }
        let lines = VoiceLineTimeline.parse(text)
        guard !lines.isEmpty else {
            error = "No spoken lines were logged for this run."
            return
        }
        lineCount = lines.count
        let stem = "AARC-lines-\(run.startedAt.formatted(.iso8601.year().month().day()))-\(run.id.uuidString.prefix(8))"
        let dir = FileManager.default.temporaryDirectory
        let srt = dir.appendingPathComponent("\(stem).srt")
        let txt = dir.appendingPathComponent("\(stem).txt")
        do {
            try VoiceLineTimeline.srt(lines).write(to: srt, atomically: true, encoding: .utf8)
            try VoiceLineTimeline.transcript(lines, startedAt: run.startedAt).write(to: txt, atomically: true, encoding: .utf8)
            srtURL = srt
            txtURL = txt
        } catch {
            self.error = "Could not write the export: \(error.localizedDescription)"
        }
    }
}

/// Pure functions over the JSONL event log, so the harness can test them.
enum VoiceLineTimeline {
    struct Line: Equatable {
        let t: Double          // seconds from run start
        let speaker: String
        let text: String
        var voiceId: String? = nil
    }

    static func speakerName(voiceId: String?) -> String {
        switch voiceId {
        case RemoteTTS.jessicaVoiceId: return "Jessica"
        case RemoteTTS.homeVoiceId: return "Home Base"
        case "local": return "Coach (local voice)"
        default: return "Ricky"
        }
    }

    static func parse(_ jsonl: String) -> [Line] {
        var out: [Line] = []
        for raw in jsonl.split(separator: "\n") {
            guard let d = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  obj["type"] as? String == "speech",
                  let t = obj["t"] as? Double, t >= 0,
                  let text = obj["detail"] as? String, !text.isEmpty else { continue }
            let data = obj["data"] as? [String: String]
            out.append(Line(t: t, speaker: speakerName(voiceId: data?["voiceId"]), text: text, voiceId: data?["voiceId"]))
        }
        return out.sorted { $0.t < $1.t }
    }

    /// Each cue lasts about as long as the line takes to say, clipped to the
    /// next cue so subtitles never overlap.
    static func srt(_ lines: [Line]) -> String {
        var s = ""
        for (i, l) in lines.enumerated() {
            let spoken = max(2.0, min(25.0, Double(l.text.count) / 14.0))
            var end = l.t + spoken
            if i + 1 < lines.count { end = min(end, lines[i + 1].t - 0.2) }
            if end <= l.t { end = l.t + 1 }
            s += "\(i + 1)\n\(stamp(l.t)) --> \(stamp(end))\n\(l.speaker): \(l.text)\n\n"
        }
        return s
    }

    static func transcript(_ lines: [Line], startedAt: Date) -> String {
        var s = "AARC voice lines. Run started \(startedAt.formatted(date: .abbreviated, time: .shortened)). Times are from the run start.\n\n"
        for l in lines {
            s += "[\(clock(l.t))] \(l.speaker): \(l.text)\n"
        }
        return s
    }

    static func stamp(_ t: Double) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    static func clock(_ t: Double) -> String {
        let s = Int(t.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
