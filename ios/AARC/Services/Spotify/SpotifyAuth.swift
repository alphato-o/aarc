import Foundation
import AuthenticationServices
import CryptoKit
import OSLog
import Observation

/// Spotify OAuth2 (PKCE) flow — entirely client-side, no client secret.
/// Tokens are persisted in the Keychain so the runner only authorises
/// once. Auto-refresh happens transparently when a 401 is returned by
/// the Web API.
///
/// User-side setup:
///   1. Register an app at https://developer.spotify.com/dashboard
///   2. Add redirect URI: `aarc://spotify-callback`
///   3. Paste the Client ID into Settings → Spotify
///   4. Tap Connect — Spotify's login WebAuthSession opens, user grants
///      `user-read-currently-playing` + `user-read-playback-state`.
@Observable
@MainActor
final class SpotifyAuth: NSObject {
    static let shared = SpotifyAuth()

    /// True iff a usable access token (refreshable if needed) is on file.
    private(set) var isConnected: Bool = false

    /// User-facing diagnostic — last refresh/connect error string.
    private(set) var lastError: String?

    /// User-facing display, e.g. "Connected as <display name>". We don't
    /// fetch the profile yet; keep this field for a later commit.
    private(set) var statusDetail: String = "Not connected"

    private let redirectURI = "aarc://spotify-callback"
    private let scope = "user-read-currently-playing user-read-playback-state"
    private let tokenEndpoint = URL(string: "https://accounts.spotify.com/api/token")!
    private let authEndpoint = URL(string: "https://accounts.spotify.com/authorize")!

    /// Strong reference kept alive for the duration of the auth session.
    /// ASWebAuthenticationSession.start() returns immediately, so we
    /// can't let this go out of scope.
    private var activeSession: ASWebAuthenticationSession?
    private var activePKCEVerifier: String?

    private let log = Logger(subsystem: "club.aarun.AARC", category: "SpotifyAuth")

    private override init() {
        super.init()
        // Surface "connected" status if a token already lives in the keychain.
        self.isConnected = (try? SpotifyTokenStore.shared.load()) != nil
        self.statusDetail = self.isConnected ? "Connected" : "Not connected"
        // Clean up the legacy per-device override now that the Client ID
        // lives in source. Harmless no-op once removed.
        UserDefaults.standard.removeObject(forKey: "spotify.clientID")
    }

    // MARK: - Public

    /// Spotify Web API Client ID. Sourced from `SpotifyConfig.clientID`
    /// (public per PKCE, baked into the binary).
    var clientID: String { SpotifyConfig.clientID }

    /// Begin OAuth. Surfaces success/failure via @Observable properties.
    func connect() async {
        let clientID = self.clientID
        lastError = nil
        do {
            let verifier = Self.makePKCEVerifier()
            let challenge = Self.codeChallenge(for: verifier)
            activePKCEVerifier = verifier

            var components = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "scope", value: scope),
            ]
            guard let authURL = components.url else {
                lastError = "Could not build auth URL"
                return
            }

            let callbackURL = try await runWebAuthSession(authURL: authURL)
            guard let code = extractCode(from: callbackURL) else {
                lastError = "No authorization code in callback"
                return
            }

            try await exchangeCodeForTokens(code: code, verifier: verifier, clientID: clientID)
            isConnected = true
            statusDetail = "Connected"
            log.info("SpotifyAuth connect succeeded")
        } catch {
            lastError = error.localizedDescription
            log.error("SpotifyAuth connect failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func disconnect() {
        try? SpotifyTokenStore.shared.clear()
        isConnected = false
        statusDetail = "Not connected"
        lastError = nil
        log.info("SpotifyAuth disconnected")
    }

    /// Return a valid access token, refreshing if needed. Used by SpotifyClient.
    /// Returns nil if no tokens are on file at all (user hasn't connected).
    func validAccessToken() async -> String? {
        guard var tokens = try? SpotifyTokenStore.shared.load() else {
            isConnected = false
            return nil
        }
        if tokens.expiresAt > Date().addingTimeInterval(30) {
            return tokens.accessToken
        }
        // Refresh.
        do {
            tokens = try await refreshTokens(refreshToken: tokens.refreshToken, clientID: clientID)
            try? SpotifyTokenStore.shared.save(tokens)
            isConnected = true
            return tokens.accessToken
        } catch {
            lastError = "Token refresh failed: \(error.localizedDescription)"
            log.error("SpotifyAuth refresh failed: \(error.localizedDescription, privacy: .public)")
            // Don't clear isConnected unless the error is auth-related;
            // the user may just be offline.
            return nil
        }
    }

    // MARK: - Private — web auth session

    private func runWebAuthSession(authURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: "aarc"
            ) { callbackURL, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                guard let callbackURL else {
                    cont.resume(throwing: SpotifyAuthError.noCallback)
                    return
                }
                cont.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            activeSession = session
            _ = session.start()
        }
    }

    private func extractCode(from callbackURL: URL) -> String? {
        guard let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else { return nil }
        return comps.queryItems?.first(where: { $0.name == "code" })?.value
    }

    // MARK: - Private — token endpoints

    private func exchangeCodeForTokens(code: String, verifier: String, clientID: String) async throws {
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        let response = try await postForm(body: body)
        let tokens = try decodeTokenResponse(response.data, refreshFallback: nil)
        try SpotifyTokenStore.shared.save(tokens)
    }

    private func refreshTokens(refreshToken: String, clientID: String) async throws -> SpotifyTokens {
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID),
        ]
        let response = try await postForm(body: body)
        return try decodeTokenResponse(response.data, refreshFallback: refreshToken)
    }

    private func postForm(body: URLComponents) async throws -> (data: Data, response: HTTPURLResponse) {
        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw SpotifyAuthError.nonHTTP }
        if !(200...299).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "<binary>"
            throw SpotifyAuthError.tokenEndpoint(status: http.statusCode, body: bodyText.prefix(300).description)
        }
        return (data, http)
    }

    private func decodeTokenResponse(_ data: Data, refreshFallback: String?) throws -> SpotifyTokens {
        struct Wire: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int
            let token_type: String
        }
        let decoded = try JSONDecoder().decode(Wire.self, from: data)
        // Refresh-token endpoint may omit refresh_token; reuse the old one.
        let refresh = decoded.refresh_token ?? refreshFallback ?? ""
        guard !refresh.isEmpty else { throw SpotifyAuthError.malformedTokens }
        return SpotifyTokens(
            accessToken: decoded.access_token,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in))
        )
    }

    // MARK: - PKCE helpers

    private static func makePKCEVerifier() -> String {
        // 64 bytes of entropy, base64url-encoded -> ~86 chars, well within 43-128.
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncode(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum SpotifyAuthError: Error, LocalizedError {
    case noCallback
    case nonHTTP
    case tokenEndpoint(status: Int, body: String)
    case malformedTokens

    var errorDescription: String? {
        switch self {
        case .noCallback: return "Spotify did not call back"
        case .nonHTTP: return "Non-HTTP response from Spotify"
        case .tokenEndpoint(let s, let b): return "Spotify token endpoint HTTP \(s): \(b)"
        case .malformedTokens: return "Spotify returned tokens missing required fields"
        }
    }
}

// MARK: - ASWebAuthenticationSession presentation

extension SpotifyAuth: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Best-effort key window lookup. SwiftUI scenes provide an anchor
        // implicitly when we use ASWebAuthenticationSession from a view
        // hierarchy, but giving it one explicitly avoids the
        // "missing anchor" path entirely.
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow })
            ?? scenes.flatMap { $0.windows }.first
        return window ?? ASPresentationAnchor()
    }
}

