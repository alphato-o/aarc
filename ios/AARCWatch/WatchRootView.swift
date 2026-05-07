import SwiftUI

struct WatchRootView: View {
    @Environment(WatchSession.self) private var session

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "figure.run")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)

                Text("AARC")
                    .font(.title3.bold())

                Text("Phase 0")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                LabeledContent("Phone reachable", value: session.isReachable ? "Yes" : "No")
                    .font(.footnote)
                if let last = session.lastInboundText {
                    Text("Last: \(last)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
        }
    }
}

#Preview {
    WatchRootView()
        .environment(WatchSession())
}
