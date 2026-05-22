import SwiftUI
import UIKit

/// Single-line text that statically truncates if it fits in the
/// container, or scrolls horizontally on a continuous loop if the
/// content is wider. Used for in-run subtitles so long roasts can
/// keep moving instead of getting truncated.
///
/// Measurement is done via `NSString.size(withAttributes:)` against
/// a matching `UIFont` — no SwiftUI layout-pollution tricks. An
/// earlier version used a hidden `Text` with `.fixedSize()` inside a
/// `ZStack` to measure width; that hidden view kept claiming layout
/// space at runtime even under `.clipped()`, which let long subtitles
/// escape the subtitle bar. The NSString route bypasses SwiftUI's
/// layout entirely so the marquee column can never grow past its
/// allotted width.
struct MarqueeText: View {
    let text: String
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let fontDesign: Font.Design
    let textColor: Color
    /// Pixels per second the text crawls left while scrolling.
    let speed: CGFloat
    /// Empty space between the end of one copy and the start of the next.
    let gap: CGFloat

    init(
        _ text: String,
        size: CGFloat = 15,
        weight: Font.Weight = .semibold,
        design: Font.Design = .rounded,
        color: Color = .white,
        speed: CGFloat = 35,
        gap: CGFloat = 60
    ) {
        self.text = text
        self.fontSize = size
        self.fontWeight = weight
        self.fontDesign = design
        self.textColor = color
        self.speed = speed
        self.gap = gap
    }

    private var swiftUIFont: Font {
        .system(size: fontSize, weight: fontWeight, design: fontDesign)
    }

    private var uiFont: UIFont {
        let uiWeight: UIFont.Weight = {
            switch fontWeight {
            case .ultraLight: return .ultraLight
            case .thin: return .thin
            case .light: return .light
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            case .heavy: return .heavy
            case .black: return .black
            default: return .regular
            }
        }()
        let base = UIFont.systemFont(ofSize: fontSize, weight: uiWeight)
        if fontDesign == .rounded,
           let desc = base.fontDescriptor.withDesign(.rounded) {
            return UIFont(descriptor: desc, size: fontSize)
        }
        return base
    }

    private var contentWidth: CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: uiFont]
        return ceil((text as NSString).size(withAttributes: attrs).width)
    }

    var body: some View {
        GeometryReader { geo in
            // 4pt safety margin so borderline cases don't toggle
            // between static and scrolling on a single-pixel rounding.
            let scrolls = contentWidth > geo.size.width + 4
            Group {
                if scrolls {
                    scrolling
                } else {
                    Text(text)
                        .font(swiftUIFont)
                        .foregroundStyle(textColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
        }
    }

    @ViewBuilder
    private var scrolling: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
            let cycle = max(1, contentWidth + gap)
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let raw = CGFloat(elapsed) * speed
            let offset = -raw.truncatingRemainder(dividingBy: cycle)
            HStack(spacing: gap) {
                Text(text)
                    .font(swiftUIFont)
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .fixedSize()
                Text(text)
                    .font(swiftUIFont)
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .fixedSize()
            }
            .offset(x: offset)
        }
    }
}

#Preview("Short — static") {
    MarqueeText("Short line, fits easily.")
        .frame(width: 320, height: 24)
        .background(Color.black)
        .preferredColorScheme(.dark)
}

#Preview("Long — scrolls") {
    MarqueeText(
        "Three fucking kilometres and you're still going, you marvellous wretched bastard — keep going."
    )
    .frame(width: 320, height: 24)
    .background(Color.black)
    .preferredColorScheme(.dark)
}
