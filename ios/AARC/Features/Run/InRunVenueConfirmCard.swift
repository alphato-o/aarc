import SwiftUI

/// In-run venue confirmation, shown in the dynamic-chart slot.
///
/// v2 (founder feedback): cohort layout — up to 3 venues as BIG full-width
/// tap targets, so wrong answers got ruled out three at a time.
///
/// v3 (founder feedback 2026-08-04): "do not attempt to hammer me — ask one
/// question, pause a little, then the next." Back to ONE venue per card, which
/// is now the fast path rather than the slow one: the datum fix in
/// VenueLocator puts the true venue FIRST (verified against Park Hyatt
/// Beijing: position 1 of 17), so the first question is usually the last.
/// The copy follows the count so a single card never reads "one of these",
/// and the layout still assumes a sweating hand mid-stride: tall rows, whole
/// row tappable, no small targets.
struct InRunVenueConfirmCard: View {
    let venues: [String]
    var onPick: (String) -> Void
    var onNone: () -> Void

    private var prompt: String {
        venues.count == 1 ? "ARE YOU HERE?" : "ARE YOU AT ONE OF THESE?"
    }
    /// A single question deserves a plain "No", not "None of these".
    private var dismissTitle: String {
        venues.count == 1 ? "No" : "None of these"
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(prompt)
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)

            ForEach(venues, id: \.self) { v in
                bigRow(title: v, tint: .teal) { onPick(v) }
            }

            bigRow(title: dismissTitle, tint: .secondary, action: onNone)
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
