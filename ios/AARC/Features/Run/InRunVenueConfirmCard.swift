import SwiftUI

/// In-run venue confirmation, shown in the dynamic-chart slot.
///
/// v2 (founder feedback): cohort layout — up to 3 venues as BIG full-width
/// tap targets ("Are you at one of these?") plus a "None of these" row, so
/// wrong answers get ruled out three at a time instead of one yes/no per
/// beat. Everything is sized for a sweating hand mid-stride: tall rows, the
/// whole row tappable, no small targets anywhere.
struct InRunVenueConfirmCard: View {
    let venues: [String]
    var onPick: (String) -> Void
    var onNone: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("ARE YOU AT ONE OF THESE?")
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)

            ForEach(venues, id: \.self) { v in
                bigRow(title: v, tint: .teal) { onPick(v) }
            }

            bigRow(title: "None of these", tint: .secondary, action: onNone)
        }
        .padding(14)
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

    private func bigRow(title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.65)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 58, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tint.opacity(tint == .secondary ? 0.14 : 0.20))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(tint.opacity(0.5), lineWidth: 1)
                )
                .foregroundStyle(tint == .secondary ? Color.primary : tint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
