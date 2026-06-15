import SwiftUI
import WatchKit

/// Slide-to-start track — a deliberate horizontal drag to begin a run, so a
/// stray tap (the phantom-run problem) can't kick one off. Snaps back if not
/// dragged far enough; haptic + completion when it reaches the end.
struct WatchSlideToStart: View {
    var label: String
    var tint: Color
    var systemImage: String
    var onComplete: () -> Void

    @State private var dragX: CGFloat = 0
    @State private var done = false
    private let knob: CGFloat = 46

    var body: some View {
        GeometryReader { geo in
            let maxX = max(1, geo.size.width - knob)
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.22))
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55 + 0.45 * (1 - dragX / maxX)))
                    .frame(maxWidth: .infinity)
                    .padding(.leading, knob * 0.4)

                Circle()
                    .fill(tint)
                    .frame(width: knob, height: knob)
                    .overlay(
                        Image(systemName: done ? "checkmark" : systemImage)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .offset(x: dragX)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                guard !done else { return }
                                dragX = min(max(0, v.translation.width), maxX)
                            }
                            .onEnded { _ in
                                guard !done else { return }
                                if dragX > maxX * 0.82 {
                                    dragX = maxX; done = true
                                    WKInterfaceDevice.current().play(.start)
                                    onComplete()
                                } else {
                                    withAnimation(.spring(response: 0.3)) { dragX = 0 }
                                }
                            }
                    )
            }
        }
        .frame(height: knob)
    }
}

#Preview {
    VStack(spacing: 8) {
        WatchSlideToStart(label: "slide to start", tint: .green,
                          systemImage: "figure.run.treadmill") {}
        WatchSlideToStart(label: "outdoor", tint: .blue, systemImage: "figure.run") {}
    }
    .padding()
}
