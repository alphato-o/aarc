import SwiftUI

enum Theme {
    static let accent = Color.accentColor

    /// Brighter green used for interactive text (NavigationLinks, Buttons in
    /// list rows). The brand accent #38503A is intentionally dark for
    /// badge-like surfaces (the giant START button, chart strokes) but reads
    /// as disabled when it's the only colour on a tappable label against a
    /// systemGroupedBackground row. This sits halfway between the brand
    /// green and system green — clearly actionable, still on-brand.
    static let link = Color(red: 0.30, green: 0.58, blue: 0.36)
}
