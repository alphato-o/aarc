import Foundation

/// Mirror of the proxy's TriggerSpec schema. Flat-with-optionals
/// because Swift's Codable handling of discriminated unions is awkward
/// and the trigger DSL has only a handful of fields.
public struct TriggerSpec: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case time
        case distance
        case halfway
        case nearFinish = "near_finish"
        case finish
    }

    public let type: Kind
    public let atSeconds: Int?
    public let atMeters: Double?
    public let everyMeters: Double?
    public let remainingMeters: Double?

    public init(
        type: Kind,
        atSeconds: Int? = nil,
        atMeters: Double? = nil,
        everyMeters: Double? = nil,
        remainingMeters: Double? = nil
    ) {
        self.type = type
        self.atSeconds = atSeconds
        self.atMeters = atMeters
        self.everyMeters = everyMeters
        self.remainingMeters = remainingMeters
    }

    /// Render as a tiny human-readable hint for diagnostics UIs.
    public var humanDescription: String {
        switch type {
        case .time:
            return "at t=\(atSeconds ?? 0)s"
        case .distance:
            if let every = everyMeters { return "every \(Int(every))m" }
            if let at = atMeters { return "at \(Int(at))m" }
            return "distance"
        case .halfway:
            return "halfway"
        case .nearFinish:
            return "\(Int(remainingMeters ?? 0))m to go"
        case .finish:
            return "at finish"
        }
    }
}

/// One line in a generated script. Mirrors the proxy's ScriptMessageSchema.
public struct ScriptMessage: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let triggerSpec: TriggerSpec
    public let text: String
    public let priority: Int
    public let playOnce: Bool

    public init(
        id: String,
        triggerSpec: TriggerSpec,
        text: String,
        priority: Int = 50,
        playOnce: Bool = true
    ) {
        self.id = id
        self.triggerSpec = triggerSpec
        self.text = text
        self.priority = priority
        self.playOnce = playOnce
    }
}

/// Returned by `POST /generate-script`.
public struct GeneratedScript: Codable, Sendable, Hashable {
    public let scriptId: String
    public let model: String
    public let messages: [ScriptMessage]

    public init(scriptId: String, model: String, messages: [ScriptMessage]) {
        self.scriptId = scriptId
        self.model = model
        self.messages = messages
    }
}
