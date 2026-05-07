import Foundation

public struct Personality: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let tagline: String

    public init(id: String, displayName: String, tagline: String) {
        self.id = id
        self.displayName = displayName
        self.tagline = tagline
    }

    public static let roastCoach = Personality(
        id: "roast_coach",
        displayName: "Roast Coach",
        tagline: "Affectionate verbal abuse, calibrated to your splits."
    )

    public static let allDefaults: [Personality] = [.roastCoach]
}
