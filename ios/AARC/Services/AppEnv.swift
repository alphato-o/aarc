import Foundation

/// Launch-environment switches for headless/automated runs. Production never
/// sets these, so all guards are inert in a real build.
enum AppEnv {
    /// XCUITest journey mode: skip permission prompts + MUTE all network
    /// (ElevenLabs TTS + the opener/script LLM calls) so a UI journey is
    /// deterministic, offline, and cost-free.
    static var uiTest: Bool {
        ProcessInfo.processInfo.environment["AARC_UITEST"] == "1"
    }
    /// Within a UI test, also put the app in desk-simulate mode so tapping a
    /// Start control drives a synthetic run (no watch, no GPS).
    static var uiTestSimulate: Bool {
        ProcessInfo.processInfo.environment["AARC_UITEST_SIMULATE"] == "1"
    }
}
