import SwiftUI

/// Full-screen Send while the phone records a line for Control Room. Plan B
/// for when the phone misses "over and out" (founder, 2026-10-17): the watch
/// is on his wrist for the whole race and one tap is something he can do.
struct TalkbackSendOverlay: View {
    let since: Date
    @Environment(WatchSession.self) private var session

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "mic.fill").foregroundStyle(.red)
                Text("Control Room").font(.caption2.bold())
                Spacer()
                Text(since, style: .timer).font(.caption2.monospacedDigit())
            }
            Button {
                session.sendTalkback(cancel: false)
            } label: {
                Text("SEND")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            Button("Scrap") { session.sendTalkback(cancel: true) }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }
}
