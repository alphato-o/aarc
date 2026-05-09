import Foundation
import Observation
import AARCKit

/// Persists the most-recently generated script + the chosen plan inputs
/// across navigation transitions and app launches. Without this,
/// ScriptPreviewView's `@State` was destroyed when the user popped the
/// nav stack, so any generated script vanished.
///
/// Stored in UserDefaults — small (a few KB of JSON), survives launch.
/// Replaced atomically each time the user taps Generate.
@Observable
@MainActor
final class ScriptPreviewStore {
    static let shared = ScriptPreviewStore()

    private static let kLatest = "aarc.script_preview.latest"
    private static let kDistance = "aarc.script_preview.distanceKm"
    private static let kPace = "aarc.script_preview.paceMinPerKm"

    var latest: GeneratedScript? {
        didSet { persistLatest() }
    }

    var distanceKm: Double {
        didSet { UserDefaults.standard.set(distanceKm, forKey: Self.kDistance) }
    }

    var paceMinPerKm: Double {
        didSet { UserDefaults.standard.set(paceMinPerKm, forKey: Self.kPace) }
    }

    init() {
        let store = UserDefaults.standard
        self.distanceKm = store.object(forKey: Self.kDistance) as? Double ?? 5
        self.paceMinPerKm = store.object(forKey: Self.kPace) as? Double ?? 5.5
        if let data = store.data(forKey: Self.kLatest),
           let decoded = try? JSONDecoder().decode(GeneratedScript.self, from: data) {
            self.latest = decoded
        }
    }

    func clear() {
        latest = nil
    }

    private func persistLatest() {
        let store = UserDefaults.standard
        if let latest, let data = try? JSONEncoder().encode(latest) {
            store.set(data, forKey: Self.kLatest)
        } else {
            store.removeObject(forKey: Self.kLatest)
        }
    }
}
