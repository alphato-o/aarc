import SwiftUI

/// Small "TEST" pill shown on history rows for runs recorded while
/// either safety mode was engaged.
struct TestBadge: View {
    var body: some View {
        Text("TEST")
            .font(.caption2.weight(.heavy))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.orange, in: Capsule())
            .foregroundStyle(.white)
            .accessibilityLabel("Test run")
    }
}

#Preview {
    HStack {
        Text("Sample run")
        TestBadge()
    }
    .padding()
}
