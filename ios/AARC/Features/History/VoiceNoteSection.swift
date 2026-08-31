import AVFoundation
import SwiftData
import SwiftUI

/// Record + review the post-run voice notes for one run.
///
/// Shown on the post-run summary (where the memory is fresh, which is the whole
/// point) and again on the run detail page (where he goes back to read them).
/// Both the original audio and the cleaned-up text are offered, because he
/// asked for both and they serve different jobs: the text is skimmable, the
/// audio is what he actually said.
@MainActor
struct VoiceNoteSection: View {
    let runId: UUID
    /// The summary screen wants a prompt; history just lists what exists.
    var invite: Bool = false

    @Environment(\.modelContext) private var modelContext
    @Query private var allNotes: [VoiceNoteRecord]
    @State private var recorder = VoiceNoteRecorder.shared
    @State private var player: AVAudioPlayer?
    @State private var playingId: UUID?

    init(runId: UUID, invite: Bool = false) {
        self.runId = runId
        self.invite = invite
        _allNotes = Query(filter: #Predicate<VoiceNoteRecord> { $0.runId == runId },
                          sort: \VoiceNoteRecord.recordedAt)
    }

    private var notes: [VoiceNoteRecord] { allNotes }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if recorder.isRecording {
                recordingRow
            } else {
                recordButton
            }
            if let err = recorder.lastError {
                Text(err).font(.caption2).foregroundStyle(.orange)
            }
            ForEach(notes) { note in
                noteRow(note)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
    }

    private var header: some View {
        HStack {
            Label("Voice notes", systemImage: "mic.fill").font(.subheadline.bold())
            Spacer()
            if !notes.isEmpty {
                Text("\(notes.count)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var recordButton: some View {
        Button {
            Task { await recorder.start(runId: runId) }
        } label: {
            Label(notes.isEmpty && invite ? "Record a note while it's fresh" : "Record a note",
                  systemImage: "mic.circle.fill")
                .font(.callout.bold())
                .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(.borderedProminent)
        .tint(.pink)
    }

    private var recordingRow: some View {
        HStack(spacing: 12) {
            Circle().fill(.red).frame(width: 10, height: 10)
                .opacity(recorder.elapsed.truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : 0.25)
            Text(timeString(recorder.elapsed)).font(.title3.monospacedDigit().bold())
            Spacer()
            Button("Cancel", role: .destructive) { recorder.cancel() }
                .font(.caption)
            Button {
                recorder.stop(context: modelContext)
            } label: {
                Label("Stop", systemImage: "stop.fill").font(.callout.bold())
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func noteRow(_ note: VoiceNoteRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    toggle(note)
                } label: {
                    Image(systemName: playingId == note.id ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                Text(note.recordedAt, format: .dateTime.hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if recorder.transcribing.contains(note.id) {
                    ProgressView().controlSize(.mini)
                    Text("transcribing…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let t = note.transcript, !t.isEmpty {
                Text(t).font(.callout).textSelection(.enabled)
            } else if !recorder.transcribing.contains(note.id) {
                // Be explicit that the AUDIO is fine — a missing transcript
                // must never read as a lost recording.
                Text("Audio saved. Transcript will appear once it's processed.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 4)
    }

    private func toggle(_ note: VoiceNoteRecord) {
        if playingId == note.id {
            player?.stop(); player = nil; playingId = nil
            return
        }
        let url = VoiceNoteRecorder.notesDirectory.appendingPathComponent(note.audioFilePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
        playingId = note.id
    }

    private func timeString(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}
