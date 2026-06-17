import Foundation

/// Injectable "current time" for run-PACING logic. Production reads the real
/// wall clock; the headless feedback simulator (SimRunDriver) installs an
/// `override` that returns VIRTUAL time, so ContextualCoach / ScriptEngine /
/// RunDirector — whose cooldowns, sustain timers and quiet-stretch detection
/// are time-based — run faithfully when a whole run is fast-forwarded in
/// minutes. `override == nil` ⇒ `Date()`, so prod behaviour is unchanged.
///
/// Only run-pacing reads switch to this. Logging / persistence timestamps stay
/// on `Date()` (they should reflect real wall-clock even during a sim).
@MainActor
enum AppClock {
    /// Set by the sim to virtual time; nil in production.
    static var override: (() -> Date)?
    static var now: Date { override?() ?? Date() }
}
