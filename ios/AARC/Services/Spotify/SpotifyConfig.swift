import Foundation

/// Spotify Application Client ID. **Public** per Spotify's OAuth/PKCE
/// design — it identifies the app to Spotify's auth servers and is
/// expected to be embedded in client binaries. No client secret is used
/// in this codebase (PKCE doesn't need one), and the Client ID does not
/// gate any quota or billing. Safe to commit to a public repo.
///
/// To use a different Spotify app registration (e.g. for testing a
/// staging redirect URI), edit this value and rebuild — no UserDefaults
/// override, no Settings UI.
enum SpotifyConfig {
    static let clientID: String = "5c05af0532894aeb90d3318a667829ab"
}
