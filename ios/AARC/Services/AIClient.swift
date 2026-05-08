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
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = e
        let d = JSONDecoder()
        d.keyDecodingStrategy = .useDefaultKeys
        self.decoder = d
    }

    /// Inputs the proxy's `/generate-script` route accepts.
    struct ScriptPlan: Codable, Sendable {
        var goal: String = "free"        // "free" | "training" | "race"
        var distanceKm: Double
        var targetPaceSecPerKm: Double?
        var personalityId: String = "roast_coach"
        var runType: String = "outdoor"  // "outdoor" | "treadmill"
        var recentRunSummary: String?
        var userMemory: [String]?
    }

    func generateScript(plan: ScriptPlan) async throws -> GeneratedScript {
        let url = Config.apiBaseURL.appendingPathComponent("generate-script")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 30
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
