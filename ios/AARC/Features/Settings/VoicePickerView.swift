import SwiftUI

/// Lets the user pick which ElevenLabs voice the companion speaks in,
/// with a Test button per row that fetches a sample line and plays it.
/// First sample request for any voice pays the cloud round-trip; the
/// audio is then on-disk for re-tests.
struct VoicePickerView: View {
    @State private var selectedId: String = RemoteTTS.shared.voice.id
    @State private var testingId: String?

    var body: some View {
        Form {
            Section {
                ForEach(ElevenLabsVoice.all) { voice in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(voice.name).font(.body.weight(.semibold))
                            Text("\(voice.accent) · \(voice.descriptor)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selectedId == voice.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                        Button {
                            test(voice)
                        } label: {
                            if testingId == voice.id {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "speaker.wave.2.fill")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(testingId != nil)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        select(voice)
                    }
                }
            } footer: {
                Text("Tap a voice to select. Tap the speaker to hear a sample. Each unique line is downloaded once and cached locally.")
            }
        }
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func select(_ voice: ElevenLabsVoice) {
        selectedId = voice.id
        RemoteTTS.shared.voice = voice
        Speaker.shared.saveVoiceSelection()
    }

    private func test(_ voice: ElevenLabsVoice) {
        testingId = voice.id
        let originalVoice = RemoteTTS.shared.voice
        RemoteTTS.shared.voice = voice
        Task {
            await RemoteTTS.shared.speak(
                "Right then. Roast Coach reporting for duty. Try to keep up, you marvellous wastrel."
            )
            RemoteTTS.shared.voice = originalVoice
            testingId = nil
        }
    }
}
