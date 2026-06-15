import SwiftUI
import WatchKit

/// In-run "Coach" page: the current spoken line + a big heart to like it.
/// Designed for a bouncing, sweaty wrist — the line never scrolls (it
/// shrinks-to-fit then fade-clamps), and the heart is pinned to the bottom so
/// it's a muscle-memory tap whatever the line length. Like is append-only:
/// one heart per line, with a success haptic so you feel it without looking.
struct WatchCoachPage: View {
    let line: String?
    let who: String?          // "ricky" | "jessica" | nil
    let stampSecondsAgo: Int? // when the line was heard, for a subtle echo
    let hearted: Bool
    let onHeart: () -> Void

    private var speaker: (name: String, color: Color)? {
        switch who?.lowercased() {
        case "jessica": return ("JESSICA", Color(red: 1.0, green: 0.42, blue: 0.72))
        case "ricky", "roast_coach": return ("RICKY", .orange)
        default: return nil
        }
    }

    var body: some View {
        if let line, !line.isEmpty {
            activeBody(line)
        } else {
            emptyBody
        }
    }

    private func activeBody(_ line: String) -> some View {
        VStack(spacing: 6) {
            // Speaker + echo
            HStack(spacing: 5) {
                if let speaker {
                    Circle().fill(speaker.color).frame(width: 7, height: 7)
                    Text(speaker.name)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(speaker.color)
                }
                Spacer(minLength: 0)
                if let s = stampSecondsAgo {
                    Text(s < 60 ? "\(s)s" : "\(s / 60)m")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            // The line — shrink-to-fit, never scroll; fade the bottom if it
            // still overflows so it reads as "there's more" not "cut off".
            Text("\u{201C}\(line)\u{201D}")
                .font(.system(size: 19, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
                .lineLimit(7)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .mask(
                    LinearGradient(stops: [
                        .init(color: .white, location: 0.0),
                        .init(color: .white, location: 0.86),
                        .init(color: .white.opacity(0), location: 1.0),
                    ], startPoint: .top, endPoint: .bottom)
                )

            heartButton
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    private var heartButton: some View {
        Button(action: tapHeart) {
            VStack(spacing: 1) {
                Image(systemName: hearted ? "heart.fill" : "heart")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(hearted ? .red : .white)
                    .symbolEffect(.bounce, value: hearted)
                Text(hearted ? "liked" : "tap")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hearted ? .red.opacity(0.9) : .secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background((hearted ? Color.red : Color.white).opacity(hearted ? 0.16 : 0.10),
                       in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(hearted)
    }

    private func tapHeart() {
        guard !hearted else { return }
        WKInterfaceDevice.current().play(.success)
        onHeart()
    }

    private var emptyBody: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text("Coach is warming up")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Lines you hear will\nshow here to heart.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Image(systemName: "heart")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary.opacity(0.5))
                .frame(height: 40)
        }
        .padding()
    }
}

#Preview("short") {
    WatchCoachPage(line: "Call that a hill? My nan jogs faster.",
                   who: "ricky", stampSecondsAgo: 8, hearted: false) {}
}
#Preview("long hearted") {
    WatchCoachPage(line: "Right, listen. Your pace just fell off a cliff and your form's gone with it. Shoulders back, drive the arms, and stop checking your watch every four seconds, you twitchy little metronome.",
                   who: "jessica", stampSecondsAgo: 64, hearted: true) {}
}
#Preview("empty") {
    WatchCoachPage(line: nil, who: nil, stampSecondsAgo: nil, hearted: false) {}
}
