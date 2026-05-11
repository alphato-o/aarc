import Foundation
import AARCKit

/// Single entry point for any LLM call. Phase 1 only wires
/// `generateScript`; Phase 2 will add `chatReply` and Phase 2.7
/// `postRunSummary`. Keeps cache + retry policy in one place.
actor AIClient {
    static let shared = AIClient()

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        // The proxy schema is camelCase (distanceKm, runType, …), so we
        // pass keys through untouched on both sides. Don't switch to
        // snake_case — that produced "distance_km" in requests and
        // tripped the zod validator on the proxy.
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    /// Inputs the proxy's `/generate-script` route accepts. Pace was
    /// dropped — runners run how they feel, the AI doesn't need it.
    /// `planKind` selects the plan structure; provide whichever of
    /// distanceKm / timeMinutes matches.
    struct ScriptPlan: Codable, Sendable {
        var goal: String = "free"        // "free" | "training" | "race"
        var planKind: String             // "distance" | "time" | "open"
        var distanceKm: Double?
        var timeMinutes: Double?
        var personalityId: String = "roast_coach"
        var runType: String = "outdoor"  // "outdoor" | "treadmill"
        var recentRunSummary: String?
        var userMemory: [String]?

        /// Convenience — derive a ScriptPlan from a RunPlan + run type.
        static func from(_ plan: RunPlan, runType: RunType, personalityId: String) -> ScriptPlan {
            ScriptPlan(
                goal: "free",
                planKind: plan.kind.rawValue,
                distanceKm: plan.distanceKm,
                timeMinutes: plan.timeMinutes,
                personalityId: personalityId,
                runType: runType.rawValue
            )
        }
    }

    func generateScript(plan: ScriptPlan) async throws -> GeneratedScript {
        let url = Config.apiBaseURL.appendingPathComponent("generate-script")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Sonnet 4.5 via OpenRouter routinely takes 40-50s for the
        // current output shape (10+ messages with variant pools and
        // expressive tags). 30s was triggering false timeouts.
        request.timeoutInterval = 90
        request.httpBody = try encoder.encode(plan)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIError.transport("non-HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw AIError.httpStatus(http.statusCode, body: body.prefix(500).description)
        }
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.ok else {
            throw AIError.proxy(envelope.error ?? "unknown")
        }
        guard
            let scriptId = envelope.scriptId,
            let model = envelope.model,
            let messages = envelope.messages
        else {
            throw AIError.proxy("missing fields in proxy response")
        }
        return GeneratedScript(scriptId: scriptId, model: model, messages: messages)
    }

    /// Loose decode of the proxy's response. The proxy returns
    /// either { ok:true, scriptId, model, messages } or
    /// { ok:false, error, ... } — we accept both.
    private struct Envelope: Decodable {
        let ok: Bool
        let scriptId: String?
        let model: String?
        let messages: [ScriptMessage]?
        let error: String?
    }

    // MARK: - Dynamic line (/dynamic-line)

    /// Triggers that the in-run ContextualCoach can fire. Keep aligned
    /// with the proxy zod enum in `DynamicLineRequestSchema`.
    enum DynamicLineTrigger: String, Codable, Sendable {
        case hrSpike = "hr_spike"
        case paceDrop = "pace_drop"
        case paceSurge = "pace_surge"
        case quietStretch = "quiet_stretch"
        case custom
    }

    struct DynamicLineContext: Codable, Sendable {
        var elapsedSeconds: Double
        var distanceMeters: Double
        var currentHR: Double?
        var avgHR: Double?
        var currentPaceSecPerKm: Double?
        var avgPaceSecPerKm: Double?
        var planKind: String          // "distance" | "time" | "open"
        var planDistanceKm: Double?
        var planTimeMinutes: Double?
        var runType: String           // "outdoor" | "treadmill"
    }

    struct DynamicLineRequest: Codable, Sendable {
        var personalityId: String = "roast_coach"
        var trigger: DynamicLineTrigger
        var runContext: DynamicLineContext
        var recentDispatched: [String]?
        var customNote: String?
    }

    struct DynamicLineResult: Sendable {
        let text: String
        let model: String
    }

    func generateDynamicLine(_ request: DynamicLineRequest) async throws -> DynamicLineResult {
        let url = Config.apiBaseURL.appendingPathComponent("dynamic-line")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        // Reactive coaching must feel immediate. Haiku via OpenRouter
        // typically returns in 2-5s, so 15s is generous without
        // letting a stuck request silence the coach for too long.
        urlRequest.timeoutInterval = 15
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw AIError.transport("non-HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw AIError.httpStatus(http.statusCode, body: body.prefix(500).description)
        }
        let envelope = try decoder.decode(DynamicEnvelope.self, from: data)
        guard envelope.ok else {
            throw AIError.proxy(envelope.error ?? "unknown")
        }
        guard let text = envelope.text, let model = envelope.model else {
            throw AIError.proxy("missing fields in proxy response")
        }
        return DynamicLineResult(text: text, model: model)
    }

    private struct DynamicEnvelope: Decodable {
        let ok: Bool
        let text: String?
        let model: String?
        let error: String?
    }

    // MARK: - Music comment (/music-comment)

    struct MusicTrack: Codable, Sendable {
        var title: String?
        var artist: String?
        var album: String?
        var isPlaying: Bool?
    }

    struct MusicCommentContext: Codable, Sendable {
        var elapsedSeconds: Double
        var distanceMeters: Double
        var currentHR: Double?
        var currentPaceSecPerKm: Double?
        var planKind: String          // "distance" | "time" | "open"
        var runType: String           // "outdoor" | "treadmill"
    }

    struct MusicCommentRequest: Codable, Sendable {
        var personalityId: String = "roast_coach"
        var track: MusicTrack?
        var unknownAudio: Bool = false
        var runContext: MusicCommentContext
        var recentDispatched: [String]?
    }

    struct MusicCommentResult: Sendable {
        let text: String
        let model: String
    }

    func generateMusicComment(_ request: MusicCommentRequest) async throws -> MusicCommentResult {
        let url = Config.apiBaseURL.appendingPathComponent("music-comment")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.timeoutInterval = 15
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw AIError.transport("non-HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw AIError.httpStatus(http.statusCode, body: body.prefix(500).description)
        }
        let envelope = try decoder.decode(DynamicEnvelope.self, from: data)
        guard envelope.ok else {
            throw AIError.proxy(envelope.error ?? "unknown")
        }
        guard let text = envelope.text, let model = envelope.model else {
            throw AIError.proxy("missing fields in proxy response")
        }
        return MusicCommentResult(text: text, model: model)
    }
}

enum AIError: Error, LocalizedError {
    case transport(String)
    case httpStatus(Int, body: String)
    case proxy(String)

    var errorDescription: String? {
        switch self {
        case .transport(let m): return "Network error: \(m)"
        case .httpStatus(let code, let body): return "HTTP \(code): \(body)"
        case .proxy(let m): return "Proxy error: \(m)"
        }
    }
}
