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
        /// Tell the model to skip the t=0 START ROAST — we've already
        /// generated and played one via /dynamic-line as a fast-start
        /// opener so the runner could begin moving.
        var skipOpener: Bool = false
        /// Lines the runner has explicitly heart-liked from past runs.
        /// Sent as VIBE-ONLY calibration; the prompt is strict about
        /// never copying them verbatim. Capped at ~12 most-recent.
        var likedLineExamples: [String]?

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
        let url = await MainActor.run { Config.apiBaseURL }.appendingPathComponent("generate-script")
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

    // MARK: - Transient-failure retry

    /// Run `operation`, retrying exactly ONCE after 2s on the transient
    /// transport failures we see on the cellular path mid-run: timed out,
    /// connection lost, can't connect to host. NEVER retries HTTP status
    /// errors (those are thrown by our own code AFTER a successful
    /// transport round-trip, as AIError, so they don't match URLError) or
    /// any other URLError (notably `.cancelled` — a stopped run must not
    /// re-fire the request). `Task.sleep` throws on cancellation, so a
    /// cancelled caller exits during the backoff instead of retrying.
    private func withOneRetry<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch let error as URLError where Self.isTransient(error) {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return try await operation()
        }
    }

    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost:
            return true
        default:
            return false
        }
    }

    // MARK: - Dynamic line (/dynamic-line)

    /// Triggers that the in-run ContextualCoach can fire. Keep aligned
    /// with the proxy zod enum in `DynamicLineRequestSchema`.
    enum DynamicLineTrigger: String, Codable, Sendable {
        case hrSpike = "hr_spike"
        case paceDrop = "pace_drop"
        case paceSurge = "pace_surge"
        case quietStretch = "quiet_stretch"
        /// Pace effectively zero — distance hasn't budged in a while.
        /// Don't auto-pause; just mock them for stopping.
        case stationary
        /// First line of the run. Generated separately from the main
        /// script so the runner can start moving in ~2-5s instead of
        /// waiting 30-50s for the full Sonnet generation.
        case opener
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
        /// Seconds since distance last changed. Populated when the
        /// coach fires the .stationary trigger — gives the model the
        /// "you've been still for X seconds" hook.
        var stationarySeconds: Double?
    }

    struct DynamicLineRequest: Codable, Sendable {
        var personalityId: String = "roast_coach"
        var trigger: DynamicLineTrigger
        var runContext: DynamicLineContext
        var recentDispatched: [String]?
        var customNote: String?
        /// Optional personal-context bullets the model can weave into
        /// roasts. Things like "FydeOS has 10 active users", "his
        /// browser side project has zero traction", "he is not going
        /// to be Sam Altman". Free-form short bullets.
        var personalNotes: [String]?
        /// Heart-liked lines from past runs — sent as vibe-only
        /// calibration. Prompt is strict about never copying verbatim.
        var likedLineExamples: [String]?
    }

    struct DynamicLineResult: Sendable {
        let text: String
        let model: String
    }

    /// Generate the fast-start opener line so the runner can start
    /// moving immediately. Uses /dynamic-line with the `opener` trigger
    /// — same proxy path as ContextualCoach, but framed for "first line
    /// of the run". Typically returns in ~2-5s via Haiku.
    func generateOpener(
        plan: RunPlan,
        runType: RunType,
        personalityId: String = "roast_coach",
        personalNotes: [String]? = nil,
        likedLineExamples: [String]? = nil
    ) async throws -> DynamicLineResult {
        let context = DynamicLineContext(
            elapsedSeconds: 0,
            distanceMeters: 0,
            currentHR: nil,
            avgHR: nil,
            currentPaceSecPerKm: nil,
            avgPaceSecPerKm: nil,
            planKind: plan.kind.rawValue,
            planDistanceKm: plan.distanceKm,
            planTimeMinutes: plan.timeMinutes,
            runType: runType.rawValue,
            stationarySeconds: nil
        )
        let request = DynamicLineRequest(
            personalityId: personalityId,
            trigger: .opener,
            runContext: context,
            recentDispatched: nil,
            customNote: nil,
            personalNotes: personalNotes,
            likedLineExamples: likedLineExamples
        )
        return try await generateDynamicLine(request)
    }

    func generateDynamicLine(_ request: DynamicLineRequest) async throws -> DynamicLineResult {
        let url = await MainActor.run { Config.apiBaseURL }.appendingPathComponent("dynamic-line")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        // Reactive coaching must feel immediate. Haiku via OpenRouter
        // typically returns in 2-5s, so 15s is generous without
        // letting a stuck request silence the coach for too long.
        urlRequest.timeoutInterval = 15
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await withOneRetry { [session, urlRequest] in
            try await session.data(for: urlRequest)
        }
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

    // MARK: - React line (/react-line) — Jessica reacting to a Ricky line

    struct ReactLineContext: Codable, Sendable {
        var elapsedSeconds: Double
        var distanceMeters: Double
        var currentHR: Double?
        var currentPaceSecPerKm: Double?
        var planKind: String        // "distance" | "time" | "open"
        var runType: String         // "outdoor" | "treadmill"
    }

    struct ReactLineRequest: Codable, Sendable {
        var personalityId: String = "jessica"
        /// The line Ricky just spoke — what she reacts to.
        var partnerLine: String
        /// Where his line came from ("script:every_km", "coach:stationary"…).
        var partnerSource: String?
        var runContext: ReactLineContext
        var recentDispatched: [String]?
        var personalNotes: [String]?
        var likedLineExamples: [String]?
        /// How long a reply to ask the proxy for. "quip" = one short
        /// sweet/cutting sentence (~6-10s audio), "medium" = 2-3 sentences,
        /// "indulgent" = the long immersive passage used RARELY. nil ⇒ the
        /// proxy defaults to "medium". Encodes to JSON key "lengthMode".
        /// Defaulted so the field is additive — existing call sites that
        /// don't set it keep compiling.
        var lengthMode: String? = nil
    }

    /// Generate Jessica's reaction to a line Ricky just spoke. Same envelope
    /// shape as /dynamic-line; reuses DynamicLineResult.
    func reactLine(_ request: ReactLineRequest) async throws -> DynamicLineResult {
        let url = await MainActor.run { Config.apiBaseURL }.appendingPathComponent("react-line")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.timeoutInterval = 15
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await withOneRetry { [session, urlRequest] in
            try await session.data(for: urlRequest)
        }
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
        /// The single lyric line being sung right now. When present this
        /// is the primary subject for the DJ — track metadata becomes
        /// supporting context.
        var currentLyric: String?
        var lyricContext: [String]?
        /// "en" | "zh" — gated on iOS side; we only ship these two.
        var lyricLanguage: String?
        var runContext: MusicCommentContext
        var recentDispatched: [String]?
        /// Same personal-context bullets we send to /dynamic-line.
        var personalNotes: [String]?
        /// Same liked-line vibe references we send to /dynamic-line.
        var likedLineExamples: [String]?
    }

    struct MusicCommentResult: Sendable {
        let text: String
        let model: String
    }

    func generateMusicComment(_ request: MusicCommentRequest) async throws -> MusicCommentResult {
        let url = await MainActor.run { Config.apiBaseURL }.appendingPathComponent("music-comment")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.timeoutInterval = 15
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await withOneRetry { [session, urlRequest] in
            try await session.data(for: urlRequest)
        }
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
