import SwiftUI
import UIKit

/// Slide-to-start track for the phone — a deliberate drag to begin a run so a
/// stray tap can't kick one off (the accidental-run problem). Snaps back if
/// released early; haptic + completion on reaching the end.
struct SlideToStart: View {
    var label: String
    var icon: String
    var tint: Color
    var onComplete: () -> Void

    @State private var dragX: CGFloat = 0
    @State private var done = false
    private let knob: CGFloat = 62
    private let inset: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let maxX = max(1, geo.size.width - knob - inset * 2)
            let progress = dragX / maxX
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: (knob + inset * 2) / 2)
                    .fill(tint.opacity(0.18))

                // Label + hint, fading as the knob advances.
                HStack(spacing: 8) {
                    Text(label)
                        .font(.system(.title3, design: .rounded, weight: .heavy))
                    Image(systemName: "chevron.forward.2")
                        .font(.system(size: 16, weight: .bold))
                        .symbolEffect(.pulse, options: .repeating)
                }
                .foregroundStyle(.white.opacity(0.55 + 0.4 * (1 - progress)))
                .frame(maxWidth: .infinity)
                .padding(.leading, knob)

                // Knob
                ZStack {
                    Circle().fill(tint.gradient)
                    Image(systemName: done ? "checkmark" : icon)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: knob, height: knob)
                .padding(inset)
                .offset(x: dragX)
                .shadow(color: tint.opacity(0.4), radius: 6, y: 2)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard !done else { return }
                            dragX = min(max(0, v.translation.width), maxX)
                        }
                        .onEnded { _ in
                            guard !done else { return }
                            if dragX > maxX * 0.85 {
                                dragX = maxX; done = true
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                onComplete()
                            } else {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                withAnimation(.spring(response: 0.3)) { dragX = 0 }
                            }
                        }
                )
            }
        }
        .frame(height: knob + inset * 2)
    }
}

#Preview {
    VStack(spacing: 14) {
        SlideToStart(label: "Treadmill", icon: "figure.run.treadmill", tint: .green) {}
        SlideToStart(label: "Outdoor", icon: "figure.run", tint: .accentColor) {}
    }
    .padding()
    .preferredColorScheme(.dark)
}
