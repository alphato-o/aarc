import SwiftUI
import AARCKit

struct RunHomeView: View {
    @State private var selectedPersonality: Personality = .roastCoach

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "figure.run.circle.fill")
                    .font(.system(size: 96))
                    .foregroundStyle(Theme.accent)

                Text("Tap Start on your Apple Watch")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Text("AARC tracks runs from the watch. The phone is the AI brain and audio device.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal)

                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Companion")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Personality", selection: $selectedPersonality) {
                        ForEach(Personality.allDefaults) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(selectedPersonality.tagline)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding()
            .navigationTitle("AARC")
        }
    }
}

#Preview {
    RunHomeView()
        .preferredColorScheme(.dark)
}
