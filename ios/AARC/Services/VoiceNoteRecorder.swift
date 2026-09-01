import AVFoundation
import Foundation
import Observation
import SwiftData

/// Post-run voice notes. Record, keep the audio locally, ship it to the proxy
/// for transcription, and hold both the audio and the tidied text.
///
/// Founder, 2026-08-31: "You should add a voice note after every run just
/// because my memory is so fresh and then I can note down what went wrong...
/// I'd expect my notes to display in both original voice audio and cleaned up
/// text."
///
/// Deliberately plain — he said "it's just an audio recorder in the frontend,
/// nothing fancy about it". No waveform, no editing, no trimming. Tap, talk,
/// stop. The only non-obvious choices are about not losing the recording:
/// the file is written to Documents and the RunRecord row is saved BEFORE any
/// upload is attempted, and upload failures are retried on next launch rather
/// than surfaced as a modal he has to deal with while sweating.
@MainActor
@Observable
final class VoiceNoteRecorder: NSObject {
    static let shared = VoiceNoteRecorder()

    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var lastError: String?
    /// Notes still waiting on a transcript, so the UI can show "transcribing…".
    private(set) var transcribing: Set<UUID> = []

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var currentNoteId: UUID?
    private var currentRunId: UUID?

    /// A note longer than this is almost certainly a pocket recording.
    private let maxSeconds: TimeInterval = 10 * 60

    /// Same device token the live channel uses (Info.plist, not bundled in
    /// source). Absent in dev builds — then the note simply stays local.
    private static var deviceToken: String? {
        (Bundle.main.object(forInfoDictionaryKey: "AARCLiveDeviceToken") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    static var notesDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("voicenotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileURL(for noteId: UUID) -> URL {
        notesDirectory.appendingPathComponent("\(noteId.uuidString).m4a")
    }

    // MARK: - Recording

    func requestPermission() async -> Bool {
        await withCheckedContinuation { c in
            AVAudioApplication.requestRecordPermission { ok in c.resume(returning: ok) }
        }
    }

    func start(runId: UUID) async {
        guard !isRecording else { return }
        lastError = nil
        guard await requestPermission() else {
            lastError = "Microphone access is off. Settings → AARC → Microphone."
            return
        }
        let noteId = UUID()
        let url = Self.fileURL(for: noteId)
        do {
            // .playAndRecord (not .record) so the coach voices aren't torn down
            // if a line is still finishing when he starts talking.
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true)
            // SPEECH settings, not music settings. The default 44.1kHz/high
            // profile recorded his 2m50s note as 9.7MB (~456kbps) — which then
            // failed to transcribe at all, because base64-ing it blew the
            // worker's limits. The same audio at 16kHz mono 32kbps is 708KB,
            // 93% smaller, and transcribes perfectly: 16kHz is the sample rate
            // every ASR model downsamples to anyway, so the extra bits were
            // never buying accuracy, just upload time and failure modes.
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.delegate = self
            guard r.record() else { throw RecorderError.couldNotStart }
            recorder = r
            currentNoteId = noteId
            currentRunId = runId
            isRecording = true
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            lastError = "Couldn't start recording: \(error.localizedDescription)"
            try? AVAudioSession.sharedInstance().setActive(false)
        }
    }

    private func tick() {
        guard let r = recorder, r.isRecording else { return }
        elapsed = r.currentTime
        if elapsed >= maxSeconds { stop(context: nil) }
    }

    /// Stop and persist. Returns the note id, or nil if there was nothing worth
    /// keeping.
    ///
    /// `autoUpload: false` keeps the recording local. The Voice Lab uses it so
    /// it can time the upload itself rather than racing a fire-and-forget one.
    @discardableResult
    func stop(context: ModelContext?, autoUpload: Bool = true) -> UUID? {
        guard let r = recorder, let noteId = currentNoteId, let runId = currentRunId else { return nil }
        let duration = r.currentTime
        r.stop()
        recorder = nil
        timer?.invalidate(); timer = nil
        isRecording = false
        elapsed = 0
        currentNoteId = nil
        currentRunId = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let url = Self.fileURL(for: noteId)
        // A stray tap isn't a note. Bin it rather than litter history.
        guard duration >= 1.0, FileManager.default.fileExists(atPath: url.path) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        // Save the row BEFORE uploading: the recording exists whether or not
        // the network does.
        if let context {
            let rec = VoiceNoteRecord(id: noteId, runId: runId, audioFilePath: url.lastPathComponent)
            context.insert(rec)
            try? context.save()
        }
        RunEventLog.shared.record("voicenote.recorded", String(format: "%.0fs", duration))
        if autoUpload {
            Task { await upload(noteId: noteId, runId: runId, duration: duration, context: context) }
        }
        return noteId
    }

    func cancel() {
        guard let r = recorder, let noteId = currentNoteId else { return }
        r.stop()
        try? FileManager.default.removeItem(at: Self.fileURL(for: noteId))
        recorder = nil
        timer?.invalidate(); timer = nil
        isRecording = false
        elapsed = 0
        currentNoteId = nil
        currentRunId = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Upload + transcription

    /// Ships the audio and stores whatever text comes back. Failures are
    /// deliberately quiet: the audio is already safe on disk and in R2, and
    /// `retryPending` picks the transcript up later.
    private func upload(noteId: UUID, runId: UUID, duration: TimeInterval, context: ModelContext?) async {
        transcribing.insert(noteId)
        defer { transcribing.remove(noteId) }
        guard let token = Self.deviceToken else { return }
        let url = Self.fileURL(for: noteId)
        guard let data = try? Data(contentsOf: url) else { return }

        var comps = URLComponents(url: Config.apiBaseURL.appendingPathComponent("voice-note"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            .init(name: "runId", value: runId.uuidString),
            .init(name: "noteId", value: noteId.uuidString),
            .init(name: "duration", value: String(Int(duration))),
        ]
        guard let reqURL = comps?.url else { return }
        var req = URLRequest(url: reqURL)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-AARC-Device")
        req.setValue("audio/mp4", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 120        // transcription of a long note isn't quick
        req.httpBody = data

        guard let (respData, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any]
        else {
            RunEventLog.shared.record("voicenote.uploadFailed", noteId.uuidString.prefix(8).description)
            return
        }
        let clean = (obj["cleanText"] as? String) ?? (obj["rawText"] as? String)
        if let clean, !clean.isEmpty, let context {
            let target = noteId
            if let rec = try? context.fetch(
                FetchDescriptor<VoiceNoteRecord>(predicate: #Predicate { $0.id == target })).first {
                rec.transcript = clean
                try? context.save()
            }
        }
        RunEventLog.shared.record("voicenote.transcribed", (obj["status"] as? String) ?? "?")
    }

    /// Called at launch: any note whose transcript never arrived gets another
    /// go. The audio is the irreplaceable part and it is already stored, so
    /// this is pure catch-up.
    func retryPending(context: ModelContext) async {
        guard let token = Self.deviceToken else { return }
        let pending = (try? context.fetch(FetchDescriptor<VoiceNoteRecord>()))?
            .filter { ($0.transcript ?? "").isEmpty } ?? []
        for note in pending.prefix(10) {
            var comps = URLComponents(url: Config.apiBaseURL.appendingPathComponent("voice-note"),
                                      resolvingAgainstBaseURL: false)
            comps?.queryItems = [.init(name: "noteId", value: note.id.uuidString)]
            guard let url = comps?.url else { continue }
            var req = URLRequest(url: url)
            req.setValue(token, forHTTPHeaderField: "X-AARC-Device")
            req.timeoutInterval = 15
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let n = obj["note"] as? [String: Any] else { continue }
            if let text = (n["clean_text"] as? String) ?? (n["raw_text"] as? String), !text.isEmpty {
                note.transcript = text
            } else if (n["status"] as? String) == "failed" {
                // Server has the audio but couldn't transcribe. Re-post so a
                // fixed provider/key gets another attempt.
                let runId = note.runId
                let noteId = note.id
                await upload(noteId: noteId, runId: runId, duration: 0, context: context)
            }
        }
        try? context.save()
    }

    enum RecorderError: Error { case couldNotStart }

    // MARK: - Bench

    struct BenchResult { let raw: String; let clean: String; let provider: String }

    enum BenchError: LocalizedError {
        case noDeviceToken, noAudio, http(Int, String), server(String)
        var errorDescription: String? {
            switch self {
            case .noDeviceToken: return "AARCLiveDeviceToken missing from Info.plist — this build cannot reach the proxy."
            case .noAudio: return "Recording file not found on disk."
            case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
            case .server(let msg): return msg
            }
        }
    }

    /// The same upload the real note path uses, but it RETURNS the result
    /// instead of quietly filing it, and surfaces the failure instead of
    /// swallowing it. That difference is the whole point of a bench: the
    /// production path is designed to fail silently so a bad night never costs
    /// him the audio, which also means it never tells you what broke.
    ///
    /// Targets the Cloudflare Worker directly, not `apiBaseURL` — voice notes
    /// need D1 and R2, and the gateway stubs both.
    func transcribeForBench(noteId: UUID, runId: UUID) async -> Result<BenchResult, Error> {
        guard let token = Self.deviceToken else { return .failure(BenchError.noDeviceToken) }
        let url = Self.fileURL(for: noteId)
        guard let data = try? Data(contentsOf: url) else { return .failure(BenchError.noAudio) }

        var comps = URLComponents(url: Config.cloudBaseURL.appendingPathComponent("voice-note"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            .init(name: "runId", value: runId.uuidString),
            .init(name: "noteId", value: noteId.uuidString),
        ]
        guard let reqURL = comps?.url else { return .failure(BenchError.noAudio) }
        var req = URLRequest(url: reqURL)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-AARC-Device")
        req.setValue("audio/mp4", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 120
        req.httpBody = data

        do {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: respData, encoding: .utf8) ?? ""
            guard code == 200,
                  let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any]
            else { return .failure(BenchError.http(code, body)) }

            // A 200 with status:"failed" is the normal shape when the audio
            // stored fine but the provider refused it.
            if (obj["status"] as? String) == "failed" {
                return .failure(BenchError.server((obj["error"] as? String) ?? "transcription failed"))
            }
            return .success(BenchResult(
                raw: (obj["rawText"] as? String) ?? "",
                clean: (obj["cleanText"] as? String) ?? "",
                provider: (obj["provider"] as? String) ?? "unknown"))
        } catch {
            return .failure(error)
        }
    }
}

extension VoiceNoteRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.lastError = error?.localizedDescription ?? "Recording error" }
    }
}
