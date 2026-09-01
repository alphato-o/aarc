import AVFoundation
import SwiftUI

/// Settings → Developer → Voice Lab.
///
/// A bench for the voice pipeline, built because the founder asked for "a test
/// playground for the voice recording the transcribing" — and because the
/// alternative to a bench is discovering problems on a real run, which is how
/// we found out his notes were recording at 456kbps.
///
/// Two rigs:
///   FILE      record → upload → VOLC file ASR → tidy. The post-run note path.
///   STREAMING record → gateway websocket → VOLC streaming ASR → live text.
///             The realtime path, for talking back to Home Base mid-run.
///
/// Everything is TIMED. Latency is the whole point of the streaming work, so a
/// bench that only proved correctness would be missing the interesting half.
@MainActor
struct VoicePlayground: View {
    @State private var recorder = VoiceNoteRecorder.shared
    @State private var stream = LiveTranscriber.shared

    // File rig
    @State private var fileState = "idle"
    @State private var rawText = ""
    @State private var cleanText = ""
    @State private var provider = ""
    @State private var uploadMs = 0
    @State private var sizeKB = 0
    @State private var busy = false
    @State private var localURL: URL?
    @State private var player: AVAudioPlayer?

    /// A fixed id so bench runs don't litter real history.
    private let benchRunId = UUID(uuidString: "BE0C0000-0000-4000-8000-000000000001")!

    var body: some View {
        Form {
            fileSection
            streamingSection
            notesSection
        }
        .navigationTitle("Voice Lab")
    }

    // MARK: - File rig

    private var fileSection: some View {
        Section {
            if recorder.isRecording {
                HStack {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    Text(fmt(recorder.elapsed)).monospacedDigit().font(.title3.bold())
                    Spacer()
                    Button("Stop") { stopFile() }.buttonStyle(.borderedProminent)
                    Button("Cancel", role: .destructive) { recorder.cancel() }
                }
            } else {
                Button {
                    Task { await recorder.start(runId: benchRunId) }
                } label: {
                    Label("Record a test note", systemImage: "mic.circle.fill")
                }
                .disabled(busy)
            }

            if let localURL {
                HStack {
                    Button {
                        player = try? AVAudioPlayer(contentsOf: localURL); player?.play()
                    } label: { Label("Play back", systemImage: "play.circle") }
                    Spacer()
                    Text("\(sizeKB) KB").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }

            LabeledContent("State", value: fileState)
            if busy { ProgressView() }
            if uploadMs > 0 {
                LabeledContent("Round trip", value: "\(uploadMs) ms").monospacedDigit()
                if !provider.isEmpty { LabeledContent("Provider", value: provider) }
            }
            if !rawText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RAW").font(.caption2.bold()).foregroundStyle(.secondary)
                    Text(rawText).font(.callout).textSelection(.enabled)
                }
            }
            if !cleanText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CLEANED").font(.caption2.bold()).foregroundStyle(.secondary)
                    Text(cleanText).font(.callout).textSelection(.enabled)
                }
            }
        } header: {
            Text("File transcription")
        } footer: {
            Text("The post-run note path: record, upload, VOLC file ASR, then tidy. Shows both the verbatim text and the cleaned version so you can see what the tidy pass changed.")
        }
    }

    // MARK: - Streaming rig

    private var streamingSection: some View {
        Section {
            if stream.isStreaming {
                HStack {
                    Circle().fill(.green).frame(width: 9, height: 9)
                    Text(fmt(stream.elapsed)).monospacedDigit().font(.title3.bold())
                    Spacer()
                    Button("Stop") { Task { await stream.stop() } }.buttonStyle(.borderedProminent)
                }
            } else {
                Button {
                    Task { await stream.start() }
                } label: {
                    Label("Start live transcription", systemImage: "waveform.badge.mic")
                }
                Button {
                    Task { await stream.start(testTone: true) }
                } label: {
                    Label("Transport test (no mic)", systemImage: "antenna.radiowaves.left.and.right")
                }
            }

            LabeledContent("Connection", value: stream.status)
            if stream.firstTextMs > 0 {
                LabeledContent("First text after", value: "\(stream.firstTextMs) ms").monospacedDigit()
            }

            // Every stage, always visible. A zero here names the broken stage
            // instantly instead of costing a run to narrow down.
            LabeledContent("Mic format", value: stream.inputFormatDescription)
            LabeledContent("Engine running", value: stream.engineRunning ? "Yes" : "No")
            LabeledContent("Mic callbacks", value: "\(stream.micCallbacks)").monospacedDigit()
            if stream.rebuilds > 0 {
                LabeledContent("Engine rebuilds", value: "\(stream.rebuilds)").monospacedDigit()
            }
            LabeledContent("Frames captured", value: "\(stream.framesCaptured)").monospacedDigit()
            LabeledContent("Packets sent", value: "\(stream.packetsSent)").monospacedDigit()
            LabeledContent("Bytes sent", value: "\(stream.bytesSent / 1024) KB").monospacedDigit()
            if !stream.partial.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LIVE").font(.caption2.bold()).foregroundStyle(.green)
                    Text(stream.partial).font(.callout)
                }
            }
            if !stream.finalText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FINAL").font(.caption2.bold()).foregroundStyle(.secondary)
                    Text(stream.finalText).font(.callout).textSelection(.enabled)
                }
            }
            if let e = stream.lastError {
                Text(e).font(.caption2).foregroundStyle(.orange)
            }
        } header: {
            Text("Live streaming")
        } footer: {
            Text("Speak and watch the text arrive. Audio goes over a websocket to the gateway, which relays to VOLC and streams text back. \"First text after\" is the number that matters. If the mic counters stay at zero, run the transport test: it streams a synthetic tone with the mic untouched, so packets moving there means the socket is fine and the fault is capture.")
        }
    }

    private var notesSection: some View {
        Section("Bench notes") {
            LabeledContent("Recording format", value: "16 kHz mono AAC, 32 kbps")
            LabeledContent("Streaming format", value: "16 kHz mono PCM, 200 ms packets")
            Text("Bench recordings use a fixed run id and never appear in your history.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - actions

    private func stopFile() {
        guard let noteId = recorder.stop(context: nil, autoUpload: false) else {
            fileState = "too short — discarded"; return
        }
        let url = VoiceNoteRecorder.fileURL(for: noteId)
        localURL = url
        sizeKB = ((try? Data(contentsOf: url))?.count ?? 0) / 1024
        rawText = ""; cleanText = ""; provider = ""; uploadMs = 0
        fileState = "uploading…"
        busy = true
        Task {
            let t0 = Date()
            let r = await VoiceNoteRecorder.shared.transcribeForBench(noteId: noteId, runId: benchRunId)
            uploadMs = Int(Date().timeIntervalSince(t0) * 1000)
            busy = false
            switch r {
            case .success(let out):
                rawText = out.raw; cleanText = out.clean; provider = out.provider
                fileState = "done"
            case .failure(let e):
                fileState = "failed"
                rawText = e.localizedDescription
            }
        }
    }

    private func fmt(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}
