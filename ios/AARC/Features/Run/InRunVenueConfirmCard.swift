import SwiftUI

/// In-run venue confirmation, shown in the dynamic-chart slot. One yes/no
/// question, two big tap targets (running hands fat-finger small buttons —
/// these fill half the card each). A "yes" makes the venue fact for the
/// coaches; a "no" advances to the next candidate. Kept deliberately tiny in
/// copy so it reads at a glance mid-stride.
struct InRunVenueConfirmCard: View {
    let venue: String
    let onYes: () -> Void
    let onNo: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("QUICK — WHERE ARE YOU?")
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Text("Are you at \(venue)?")
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 12) {
                bigButton(title: "No", tint: .secondary, action: onNo)
                bigButton(title: "Yes", tint: .teal, action: onYes)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.teal.opacity(0.35), lineWidth: 1)
        )
    }

    private func bigButton(title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.title2.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 72)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(tint.opacity(0.22))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(tint.opacity(0.5), lineWidth: 1)
                )
                .foregroundStyle(tint == .secondary ? Color.primary : tint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
