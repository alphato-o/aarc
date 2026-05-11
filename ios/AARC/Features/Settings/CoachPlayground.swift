import SwiftUI
import AARCKit

/// Off-the-couch testing for the dynamic-line + music-comment paths.
///
/// Each button:
///   1. Builds a synthetic `runContext` representing a runner ~10 minutes
///      into a 5km treadmill run.
///   2. Calls the relevant `AIClient` method.
///   3. Speaks the returned line through `Speaker.shared.speak()`.
///
/// Bypasses `ContextualCoach` and `ScriptEngine.tryInject` so you can
/// test in your kitchen without first triggering a fake run. The
/// global Speaker pipeline (ducking, ElevenLabs/Apple fallback, cache)
/// is exercised end-to-end.
struct CoachPlayground: View {
    @State private var spotifyAuth = SpotifyAuth.shared
    @State private var busy: String?
    @State private var lastFired: String?
    @State private var lastError: String?
    @State private var customNote: String = ""
    @State private var probedTrack: String?
    @State private var probedLyric: String?
    @State private var probedLanguage: String?

    var body: some View {
        Form {
            Section {
                triggerButton(.hrSpike, label: "HR spike", icon: "heart.text.square")
                triggerButton(.paceDrop, label: "Pace drop (slower)", icon: "tortoise")
                triggerButton(.paceSurge, label: "Pace surge (faster)", icon: "hare")
                triggerButton(.quietStretch, label: "Quiet stretch", icon: "speaker.slash")
            } header: {
                Text("/dynamic-line triggers")
            } footer: {
                Text("Fires a fresh line via the /dynamic-line proxy with a synthetic 10-minutes-in-5km run state. Line gets spoken through Speaker.")
            }

            Section {
                TextField("Custom note (optional)", text: $customNote, axis: .vertical)
                    .lineLimit(2...4)
                customTriggerButton
            } header: {
                Text("Custom trigger")
            } footer: {
                Text("Free-form context for the coach to respond to. Useful for sanity-checking specific weird situations.")
            }

            Section {
                if spotifyAuth.isConnected {
                    Label("Spotify connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Label("Spotify NOT connected — will probe AVAudioSession only", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                if let probedTrack {
                    Text(probedTrack)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let probedLyric {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Lyric line").font(.caption2).foregroundStyle(.secondary)
                            if let probedLanguage {
                                Text("· \(probedLanguage)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Text("\u{201C}\(probedLyric)\u{201D}")
                            .font(.caption)
                            .italic()
                    }
                }
                probeButton
                musicCommentButton
            } header: {
                Text("Music DJ commentary")
            } footer: {
                Text("Probes current Spotify track + fetches synced lyrics from lrclib.net, then asks /music-comment to roast the SPECIFIC LINE being sung. Skips if the song is instrumental, in an unsupported language, or has no lyrics on file.")
            }

            Section {
                if let lastFired {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last line spoken").font(.caption).foregroundStyle(.secondary)
                        Text(lastFired).font(.callout)
                    }
                }
                if let lastError {
                    Text("Error: \(lastError)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Result")
            }
        }
        .navigationTitle("Coach Playground")
    }

    // MARK: - Trigger buttons

    @ViewBuilder
    private func triggerButton(
        _ trigger: AIClient.DynamicLineTrigger,
        label: String,
        icon: String
    ) -> some View {
        Button {
            fireDynamic(trigger: trigger, note: nil)
        } label: {
            HStack {
                Label(label, systemImage: icon)
                Spacer()
                if busy == trigger.rawValue { ProgressView() }
            }
        }
        .disabled(busy != nil)
    }

    private var customTriggerButton: some View {
        Button {
            fireDynamic(trigger: .custom, note: customNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "the runner just sneezed and nearly fell off the treadmill" : customNote)
        } label: {
            HStack {
                Label("Fire custom trigger", systemImage: "sparkles")
                Spacer()
                if busy == "custom" { ProgressView() }
            }
        }
        .disabled(busy != nil)
    }

    private var probeButton: some View {
        Button {
            Task { @MainActor in
                probedLyric = nil
                probedLanguage = nil
                let resolved = await MusicLyricResolver.resolveCurrent()
                switch resolved {
                case .lyric(let t, let sel):
                    probedTrack = "Now playing: \(t.title) — \(t.artist)"
                    probedLyric = sel.line
                    probedLanguage = sel.language
                case .songWithoutUsableLyric(let t):
                    probedTrack = "Now playing: \(t.title) — \(t.artist) (no usable lyric — instrumental, language unsupported, or not on LRCLib)"
                case .unknownAudio:
                    probedTrack = "Other audio is playing (no metadata available)"
                case .silent:
                    probedTrack = "Nothing currently playing"
                }
            }
        } label: {
            Label("Probe current track", systemImage: "magnifyingglass")
        }
        .disabled(busy != nil)
    }

    private var musicCommentButton: some View {
        Button {
            fireMusic()
        } label: {
            HStack {
                Label("Fire DJ commentary", systemImage: "music.note.list")
                Spacer()
                if busy == "music" { ProgressView() }
            }
        }
        .disabled(busy != nil)
    }

    // MARK: - Helpers

    private func syntheticDynamicContext() -> AIClient.DynamicLineContext {
        AIClient.DynamicLineContext(
            elapsedSeconds: 600,           // 10 min in
            distanceMeters: 1500,          // 1.5 km
            currentHR: 175,
            avgHR: 152,
            currentPaceSecPerKm: 360,      // 6:00/km
            avgPaceSecPerKm: 330,          // 5:30/km
            planKind: "distance",
            planDistanceKm: 5,
            planTimeMinutes: nil,
            runType: "treadmill"
        )
    }

    private func syntheticMusicContext() -> AIClient.MusicCommentContext {
        AIClient.MusicCommentContext(
            elapsedSeconds: 600,
            distanceMeters: 1500,
            currentHR: 152,
            currentPaceSecPerKm: 330,
            planKind: "distance",
            runType: "treadmill"
        )
    }

    private func fireDynamic(trigger: AIClient.DynamicLineTrigger, note: String?) {
        busy = trigger.rawValue
        lastError = nil
        let request = AIClient.DynamicLineRequest(
            personalityId: "roast_coach",
            trigger: trigger,
            runContext: syntheticDynamicContext(),
            recentDispatched: nil,
            customNote: note
        )
        Task { @MainActor in
            defer { busy = nil }
            do {
                let result = try await AIClient.shared.generateDynamicLine(request)
                Speaker.shared.speak(result.text)
                lastFired = result.text
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func fireMusic() {
        busy = "music"
        lastError = nil
        probedLyric = nil
        probedLanguage = nil
        Task { @MainActor in
            defer { busy = nil }
            let resolved = await MusicLyricResolver.resolveCurrent()
            let request: AIClient.MusicCommentRequest
            switch resolved {
            case .silent:
                lastError = "Nothing playing — start Spotify and try again."
                return
            case .lyric(let t, let sel):
                probedTrack = "Now playing: \(t.title) — \(t.artist)"
                probedLyric = sel.line
                probedLanguage = sel.language
                request = AIClient.MusicCommentRequest(
                    personalityId: "roast_coach",
                    track: AIClient.MusicTrack(title: t.title, artist: t.artist, album: t.album, isPlaying: t.isPlaying),
                    unknownAudio: false,
                    currentLyric: sel.line,
                    lyricContext: sel.context.isEmpty ? nil : sel.context,
                    lyricLanguage: sel.language,
                    runContext: syntheticMusicContext(),
                    recentDispatched: nil
                )
            case .songWithoutUsableLyric(let t):
                probedTrack = "Now playing: \(t.title) — \(t.artist) (no usable lyric)"
                lastError = "No usable lyric for this track (instrumental, unsupported language, or not on LRCLib). Production coach skips this case; the playground still fires a generic riff so you can hear something."
                request = AIClient.MusicCommentRequest(
                    personalityId: "roast_coach",
                    track: AIClient.MusicTrack(title: t.title, artist: t.artist, album: t.album, isPlaying: t.isPlaying),
                    unknownAudio: false,
                    currentLyric: nil,
                    lyricContext: nil,
                    lyricLanguage: nil,
                    runContext: syntheticMusicContext(),
                    recentDispatched: nil
                )
            case .unknownAudio:
                probedTrack = "Other audio is playing (no metadata available)"
                request = AIClient.MusicCommentRequest(
                    personalityId: "roast_coach",
                    track: nil,
                    unknownAudio: true,
                    currentLyric: nil,
                    lyricContext: nil,
                    lyricLanguage: nil,
                    runContext: syntheticMusicContext(),
                    recentDispatched: nil
                )
            }
            do {
                let result = try await AIClient.shared.generateMusicComment(request)
                Speaker.shared.speak(result.text)
                lastFired = result.text
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
}

#Preview {
    NavigationStack {
        CoachPlayground()
    }
}
