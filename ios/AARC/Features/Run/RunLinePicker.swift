import SwiftUI

/// Every line spoken in a run, from its event log, to pick one for the share
/// card (founder, Tianjin 25 Oct: "any line from the entire race").
struct RunLinePicker: View {
    let runId: UUID?
    let onPick: (VoiceLineTimeline.Line) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var lines: [VoiceLineTimeline.Line] = []
    @State private var query = ""
    @State private var speaker = "All"
    @State private var loaded = false

    private var speakers: [String] { ["All"] + Array(Set(lines.map(\.speaker))).sorted() }

    private var shown: [VoiceLineTimeline.Line] {
        lines.filter { l in
            (speaker == "All" || l.speaker == speaker)
                && (query.isEmpty || l.text.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if loaded && lines.isEmpty {
                    Text("No spoken lines are logged on this phone for this run.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(shown.enumerated()), id: \.offset) { _, l in
                    Button { onPick(l) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(VoiceLineTimeline.clock(l.t)) · \(l.speaker)")
                                .font(.caption.bold()).foregroundStyle(.secondary)
                            Text(l.text.strippingAudioTags).font(.subheadline).foregroundStyle(.primary)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search the lines")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Picker("Voice", selection: $speaker) {
                        ForEach(speakers, id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.menu)
                }
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .navigationTitle("\(shown.count) lines")
            .navigationBarTitleDisplayMode(.inline)
            .task { load() }
        }
    }

    private func load() {
        defer { loaded = true }
        guard let runId,
              let data = try? Data(contentsOf: RunEventLog.logFileURL(for: runId)),
              let text = String(data: data, encoding: .utf8) else { return }
        lines = VoiceLineTimeline.parse(text)
    }
}
