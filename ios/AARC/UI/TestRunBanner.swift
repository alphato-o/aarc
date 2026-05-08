import SwiftUI

/// Persistent banner shown on the active-run screen and post-run summary
/// while either safety mode (tag mode or skip-HK mode) is engaged. Designed
/// to be hard to ignore so the founder can never accidentally treat a test
/// run as a real one.
struct TestRunBanner: View {
    let skipHealthKit: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "flask.fill")
                .font(.callout)
            VStack(alignment: .leading, spacing: 2) {
                Text("Test mode")
                    .font(.caption.bold())
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.9))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.orange, Color.pink],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        skipHealthKit
            ? "Runs won't be written to Apple Health at all."
            : "Runs are tagged for easy cleanup later."
    }
}

#Preview("tag mode") {
    TestRunBanner(skipHealthKit: false)
}

#Preview("skip mode") {
    TestRunBanner(skipHealthKit: true)
}
